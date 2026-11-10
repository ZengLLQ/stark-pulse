//! Core Concentrated Liquidity Automated Market Maker (CLAMM) Pool for StarkPulse on Starknet.

use starknet::ContractAddress;
use super::types::{PositionInfo, PulseState, TickInfo};

#[starknet::interface]
pub trait IStarkPulsePool<TContractState> {
    fn initialize(ref self: TContractState, sqrt_price_x96: u256);
    fn mint(
        ref self: TContractState,
        recipient: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount: u128,
    ) -> (u256, u256);
    fn burn(
        ref self: TContractState, tick_lower: i32, tick_upper: i32, amount: u128,
    ) -> (u256, u256);
    fn collect(
        ref self: TContractState,
        recipient: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount0_requested: u128,
        amount1_requested: u128,
    ) -> (u128, u128);
    fn swap(
        ref self: TContractState,
        recipient: ContractAddress,
        zero_for_one: bool,
        amount_specified: u256,
        sqrt_price_limit_x96: u256,
        current_timestamp: u64,
    ) -> (u256, u256);
    fn flash(
        ref self: TContractState,
        recipient: ContractAddress,
        amount0: u256,
        amount1: u256,
        data: Span<felt252>,
    ) -> (u256, u256);

    // View functions
    fn get_slot0(self: @TContractState) -> (u256, i32, u32, bool);
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_position(
        self: @TContractState, owner: ContractAddress, tick_lower: i32, tick_upper: i32,
    ) -> PositionInfo;
    fn get_tick_info(self: @TContractState, tick: i32) -> TickInfo;
    fn get_pulse_state(self: @TContractState) -> PulseState;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);
    fn get_pool_params(self: @TContractState) -> (ContractAddress, ContractAddress, u32, u32);
}

#[starknet::contract]
pub mod stark_pulse_pool {
    use core::cmp::min;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use crate::bitmap::{flip_tick_in_word, next_initialized_tick_in_word, position};
    use crate::math::{Q128, mul_div, mul_div_rounding_up};
    use crate::position::{get_fee_growth_inside, update_position_fees};
    use crate::pulse_fee::update_pulse_fee;
    use crate::sqrt_price_math::{get_amount0_delta, get_amount1_delta};
    use crate::swap_math::compute_swap_step;
    use crate::tick_math::{
        MAX_SQRT_RATIO, MAX_TICK, MIN_SQRT_RATIO, MIN_TICK, get_sqrt_ratio_at_tick,
        get_tick_at_sqrt_ratio,
    };
    use crate::types::{PositionInfo, PulseState, TickInfo};
    use super::IStarkPulsePool;

    #[storage]
    struct Storage {
        admin: ContractAddress,
        token0: ContractAddress,
        token1: ContractAddress,
        fee_bps: u32,
        tick_spacing: u32,
        // Global State
        sqrt_price_x96: u256,
        tick: i32,
        unlocked: bool,
        liquidity: u128,
        fee_growth_global_0_x128: u256,
        fee_growth_global_1_x128: u256,
        // Pulse State
        volatility_accumulator: u64,
        last_pulse_timestamp: u64,
        last_pulse_tick: i32,
        current_pulse_fee: u32,
        // Mappings
        ticks: Map<i32, TickInfo>,
        tick_bitmap: Map<i16, u256>,
        positions: Map<(ContractAddress, i32, i32), PositionInfo>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Initialize: Initialize,
        Mint: Mint,
        Burn: Burn,
        Collect: Collect,
        Swap: Swap,
        Flash: Flash,
        PulseUpdate: PulseUpdate,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Initialize {
        pub sqrt_price_x96: u256,
        pub tick: i32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Mint {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub owner: ContractAddress,
        pub tick_lower: i32,
        pub tick_upper: i32,
        pub amount: u128,
        pub amount0: u256,
        pub amount1: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Burn {
        #[key]
        pub owner: ContractAddress,
        pub tick_lower: i32,
        pub tick_upper: i32,
        pub amount: u128,
        pub amount0: u256,
        pub amount1: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Collect {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
        pub tick_lower: i32,
        pub tick_upper: i32,
        pub amount0: u128,
        pub amount1: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Swap {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
        pub amount0_in: u256,
        pub amount1_out: u256,
        pub sqrt_price_x96: u256,
        pub liquidity: u128,
        pub tick: i32,
        pub fee_bps: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Flash {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
        pub amount0: u256,
        pub amount1: u256,
        pub fee0: u256,
        pub fee1: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PulseUpdate {
        pub old_fee_bps: u32,
        pub new_fee_bps: u32,
        pub volatility_accumulator: u64,
    }

    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        token0: ContractAddress,
        token1: ContractAddress,
        fee_bps: u32,
        tick_spacing: u32,
    ) {
        assert!(fee_bps > 0 && fee_bps <= 10_000, "invalid fee_bps");
        assert!(tick_spacing > 0 && tick_spacing <= 16384, "invalid tick_spacing");
        self.admin.write(admin);
        self.token0.write(token0);
        self.token1.write(token1);
        self.fee_bps.write(fee_bps);
        self.tick_spacing.write(tick_spacing);
        self.unlocked.write(true);
        self.current_pulse_fee.write(fee_bps);
    }

    #[abi(embed_v0)]
    pub impl StarkPulsePoolImpl of IStarkPulsePool<ContractState> {
        fn initialize(ref self: ContractState, sqrt_price_x96: u256) {
            assert!(self.sqrt_price_x96.read() == 0, "already initialized");
            assert!(
                sqrt_price_x96 >= MIN_SQRT_RATIO && sqrt_price_x96 <= MAX_SQRT_RATIO,
                "price out of bounds",
            );
            let tick = get_tick_at_sqrt_ratio(sqrt_price_x96);
            self.sqrt_price_x96.write(sqrt_price_x96);
            self.tick.write(tick);
            self.last_pulse_tick.write(tick);

            self.emit(Initialize { sqrt_price_x96, tick });
        }

        fn mint(
            ref self: ContractState,
            recipient: ContractAddress,
            tick_lower: i32,
            tick_upper: i32,
            amount: u128,
        ) -> (u256, u256) {
            assert!(self.unlocked.read(), "reentrancy locked");
            self.unlocked.write(false);

            assert!(amount > 0, "amount must be > 0");
            self._check_ticks(tick_lower, tick_upper);

            let current_sqrt_price_x96 = self.sqrt_price_x96.read();
            assert!(current_sqrt_price_x96 > 0, "not initialized");
            let current_tick = self.tick.read();

            let sqrt_price_lower = get_sqrt_ratio_at_tick(tick_lower);
            let sqrt_price_upper = get_sqrt_ratio_at_tick(tick_upper);

            let mut amount0: u256 = 0;
            let mut amount1: u256 = 0;

            if current_tick < tick_lower {
                amount0 = get_amount0_delta(sqrt_price_lower, sqrt_price_upper, amount, true);
            } else if current_tick >= tick_upper {
                amount1 = get_amount1_delta(sqrt_price_lower, sqrt_price_upper, amount, true);
            } else {
                amount0 = get_amount0_delta(current_sqrt_price_x96, sqrt_price_upper, amount, true);
                amount1 = get_amount1_delta(sqrt_price_lower, current_sqrt_price_x96, amount, true);
                let new_liq = self.liquidity.read() + amount;
                self.liquidity.write(new_liq);
            }

            // Update Lower Tick
            self._update_tick(tick_lower, current_tick, amount, true);
            // Update Upper Tick
            self._update_tick(tick_upper, current_tick, amount, false);

            // Update Position Fees & Liquidity
            let fee_growth_global_0 = self.fee_growth_global_0_x128.read();
            let fee_growth_global_1 = self.fee_growth_global_1_x128.read();

            let tick_lower_info = self.ticks.read(tick_lower);
            let tick_upper_info = self.ticks.read(tick_upper);

            let f_inside_0 = get_fee_growth_inside(
                tick_lower,
                tick_upper,
                current_tick,
                fee_growth_global_0,
                tick_lower_info.fee_growth_outside_0_x128,
                tick_upper_info.fee_growth_outside_0_x128,
            );
            let f_inside_1 = get_fee_growth_inside(
                tick_lower,
                tick_upper,
                current_tick,
                fee_growth_global_1,
                tick_lower_info.fee_growth_outside_1_x128,
                tick_upper_info.fee_growth_outside_1_x128,
            );

            let pos_key = (recipient, tick_lower, tick_upper);
            let mut pos = self.positions.read(pos_key);
            let delta_i128: i128 = amount.try_into().unwrap();
            let _ = update_position_fees(ref pos, delta_i128, f_inside_0, f_inside_1);
            self.positions.write(pos_key, pos);

            let caller = get_caller_address();
            self
                .emit(
                    Mint {
                        sender: caller,
                        owner: recipient,
                        tick_lower,
                        tick_upper,
                        amount,
                        amount0,
                        amount1,
                    },
                );

            self.unlocked.write(true);
            (amount0, amount1)
        }

        fn burn(
            ref self: ContractState, tick_lower: i32, tick_upper: i32, amount: u128,
        ) -> (u256, u256) {
            assert!(self.unlocked.read(), "reentrancy locked");
            self.unlocked.write(false);

            assert!(amount > 0, "amount must be > 0");
            self._check_ticks(tick_lower, tick_upper);

            let current_sqrt_price_x96 = self.sqrt_price_x96.read();
            let current_tick = self.tick.read();

            let sqrt_price_lower = get_sqrt_ratio_at_tick(tick_lower);
            let sqrt_price_upper = get_sqrt_ratio_at_tick(tick_upper);

            let mut amount0: u256 = 0;
            let mut amount1: u256 = 0;

            if current_tick < tick_lower {
                amount0 = get_amount0_delta(sqrt_price_lower, sqrt_price_upper, amount, false);
            } else if current_tick >= tick_upper {
                amount1 = get_amount1_delta(sqrt_price_lower, sqrt_price_upper, amount, false);
            } else {
                amount0 =
                    get_amount0_delta(current_sqrt_price_x96, sqrt_price_upper, amount, false);
                amount1 =
                    get_amount1_delta(sqrt_price_lower, current_sqrt_price_x96, amount, false);
                let cur_liq = self.liquidity.read();
                assert!(cur_liq >= amount, "insufficient pool liquidity");
                self.liquidity.write(cur_liq - amount);
            }

            // Remove Lower & Upper Tick shares
            self._remove_tick_liquidity(tick_lower, amount, true);
            self._remove_tick_liquidity(tick_upper, amount, false);

            let caller = get_caller_address();
            let pos_key = (caller, tick_lower, tick_upper);
            let mut pos = self.positions.read(pos_key);
            assert!(pos.liquidity >= amount, "insufficient position liquidity");

            let fee_growth_global_0 = self.fee_growth_global_0_x128.read();
            let fee_growth_global_1 = self.fee_growth_global_1_x128.read();
            let tick_lower_info = self.ticks.read(tick_lower);
            let tick_upper_info = self.ticks.read(tick_upper);

            let f_inside_0 = get_fee_growth_inside(
                tick_lower,
                tick_upper,
                current_tick,
                fee_growth_global_0,
                tick_lower_info.fee_growth_outside_0_x128,
                tick_upper_info.fee_growth_outside_0_x128,
            );
            let f_inside_1 = get_fee_growth_inside(
                tick_lower,
                tick_upper,
                current_tick,
                fee_growth_global_1,
                tick_lower_info.fee_growth_outside_1_x128,
                tick_upper_info.fee_growth_outside_1_x128,
            );

            let neg_delta_i128: i128 = -(amount.try_into().unwrap());
            let _ = update_position_fees(ref pos, neg_delta_i128, f_inside_0, f_inside_1);

            let a0_u128: u128 = amount0.try_into().unwrap();
            let a1_u128: u128 = amount1.try_into().unwrap();
            pos.tokens_owed_0 += a0_u128;
            pos.tokens_owed_1 += a1_u128;
            self.positions.write(pos_key, pos);

            self.emit(Burn { owner: caller, tick_lower, tick_upper, amount, amount0, amount1 });

            self.unlocked.write(true);
            (amount0, amount1)
        }

        fn collect(
            ref self: ContractState,
            recipient: ContractAddress,
            tick_lower: i32,
            tick_upper: i32,
            amount0_requested: u128,
            amount1_requested: u128,
        ) -> (u128, u128) {
            assert!(self.unlocked.read(), "reentrancy locked");
            self.unlocked.write(false);

            let caller = get_caller_address();
            let pos_key = (caller, tick_lower, tick_upper);
            let mut pos = self.positions.read(pos_key);

            let amount0 = min(amount0_requested, pos.tokens_owed_0);
            let amount1 = min(amount1_requested, pos.tokens_owed_1);

            pos.tokens_owed_0 -= amount0;
            pos.tokens_owed_1 -= amount1;
            self.positions.write(pos_key, pos);

            self
                .emit(
                    Collect { owner: caller, recipient, tick_lower, tick_upper, amount0, amount1 },
                );

            self.unlocked.write(true);
            (amount0, amount1)
        }

        fn swap(
            ref self: ContractState,
            recipient: ContractAddress,
            zero_for_one: bool,
            amount_specified: u256,
            sqrt_price_limit_x96: u256,
            current_timestamp: u64,
        ) -> (u256, u256) {
            assert!(self.unlocked.read(), "reentrancy locked");
            self.unlocked.write(false);

            assert!(amount_specified > 0, "amount_specified must be > 0");
            let mut current_sqrt_price = self.sqrt_price_x96.read();
            let mut current_tick = self.tick.read();
            let mut current_liquidity = self.liquidity.read();

            if zero_for_one {
                assert!(
                    sqrt_price_limit_x96 < current_sqrt_price
                        && sqrt_price_limit_x96 >= MIN_SQRT_RATIO,
                    "invalid zero_for_one price limit",
                );
            } else {
                assert!(
                    sqrt_price_limit_x96 > current_sqrt_price
                        && sqrt_price_limit_x96 <= MAX_SQRT_RATIO,
                    "invalid one_for_zero price limit",
                );
            }

            // Pulse Dynamic Fee Evaluation
            let base_fee = self.fee_bps.read();
            let pulse_state = PulseState {
                volatility_accumulator: self.volatility_accumulator.read(),
                last_update_timestamp: self.last_pulse_timestamp.read(),
                last_tick: self.last_pulse_tick.read(),
                current_pulse_fee_bps: self.current_pulse_fee.read(),
            };

            let (new_pulse, active_fee_bps) = update_pulse_fee(
                pulse_state, current_tick, current_timestamp, base_fee,
            );
            self.volatility_accumulator.write(new_pulse.volatility_accumulator);
            self.last_pulse_timestamp.write(new_pulse.last_update_timestamp);
            self.last_pulse_tick.write(new_pulse.last_tick);
            self.current_pulse_fee.write(active_fee_bps);

            let mut amount_specified_remaining = amount_specified;
            let mut total_amount_in: u256 = 0;
            let mut total_amount_out: u256 = 0;

            let _tick_sp = self.tick_spacing.read();

            while amount_specified_remaining > 0 && current_sqrt_price != sqrt_price_limit_x96 {
                let (word_pos, bit_pos) = position(current_tick);
                let word = self.tick_bitmap.read(word_pos);
                let (mut next_tick, mut initialized) = next_initialized_tick_in_word(
                    word, word_pos, bit_pos, zero_for_one,
                );

                if !initialized && next_tick == current_tick {
                    if zero_for_one {
                        let word_base: i32 = word_pos.into() * 256;
                        let jump_tick = word_base - 1;
                        let (next_w, next_b) = position(jump_tick);
                        let next_word = self.tick_bitmap.read(next_w);
                        let (nt, init) = next_initialized_tick_in_word(
                            next_word, next_w, next_b, true,
                        );
                        next_tick = nt;
                        initialized = init;
                    } else {
                        let word_base: i32 = word_pos.into() * 256;
                        let jump_tick = word_base + 256;
                        let (next_w, next_b) = position(jump_tick);
                        let next_word = self.tick_bitmap.read(next_w);
                        let (nt, init) = next_initialized_tick_in_word(
                            next_word, next_w, next_b, false,
                        );
                        next_tick = nt;
                        initialized = init;
                    }
                }

                if next_tick < MIN_TICK {
                    next_tick = MIN_TICK;
                } else if next_tick > MAX_TICK {
                    next_tick = MAX_TICK;
                }

                let next_sqrt_price = get_sqrt_ratio_at_tick(next_tick);
                let mut target_sqrt_price = if zero_for_one {
                    if next_sqrt_price < sqrt_price_limit_x96 {
                        sqrt_price_limit_x96
                    } else {
                        next_sqrt_price
                    }
                } else {
                    if next_sqrt_price > sqrt_price_limit_x96 {
                        sqrt_price_limit_x96
                    } else {
                        next_sqrt_price
                    }
                };

                if zero_for_one {
                    if target_sqrt_price >= current_sqrt_price
                        && current_sqrt_price > MIN_SQRT_RATIO {
                        target_sqrt_price = current_sqrt_price - 1;
                    }
                } else {
                    if target_sqrt_price <= current_sqrt_price
                        && current_sqrt_price < MAX_SQRT_RATIO {
                        target_sqrt_price = current_sqrt_price + 1;
                    }
                }

                let step = compute_swap_step(
                    current_sqrt_price,
                    target_sqrt_price,
                    current_liquidity,
                    amount_specified_remaining,
                    active_fee_bps,
                );

                current_sqrt_price = step.sqrt_price_next_x96;
                total_amount_in += (step.amount_in + step.fee_amount);
                total_amount_out += step.amount_out;
                amount_specified_remaining -= (step.amount_in + step.fee_amount);

                // Accumulate protocol/LP fees
                if current_liquidity > 0 && step.fee_amount > 0 {
                    let fee_growth_delta = mul_div(step.fee_amount, Q128, current_liquidity.into());
                    if zero_for_one {
                        let cur_g = self.fee_growth_global_0_x128.read();
                        self.fee_growth_global_0_x128.write(cur_g + fee_growth_delta);
                    } else {
                        let cur_g = self.fee_growth_global_1_x128.read();
                        self.fee_growth_global_1_x128.write(cur_g + fee_growth_delta);
                    }
                }

                // If step reached next initialized tick, cross tick
                if current_sqrt_price == next_sqrt_price && initialized {
                    let mut tick_data = self.ticks.read(next_tick);
                    let fg0 = self.fee_growth_global_0_x128.read();
                    let fg1 = self.fee_growth_global_1_x128.read();

                    tick_data.fee_growth_outside_0_x128 = fg0 - tick_data.fee_growth_outside_0_x128;
                    tick_data.fee_growth_outside_1_x128 = fg1 - tick_data.fee_growth_outside_1_x128;
                    self.ticks.write(next_tick, tick_data);

                    let net_i128 = tick_data.liquidity_net;
                    if zero_for_one {
                        if net_i128 >= 0 {
                            let add_l: u128 = net_i128.try_into().unwrap();
                            current_liquidity -= add_l;
                        } else {
                            let sub_l: u128 = (-net_i128).try_into().unwrap();
                            current_liquidity += sub_l;
                        }
                        current_tick = next_tick - 1;
                    } else {
                        if net_i128 >= 0 {
                            let add_l: u128 = net_i128.try_into().unwrap();
                            current_liquidity += add_l;
                        } else {
                            let sub_l: u128 = (-net_i128).try_into().unwrap();
                            current_liquidity -= sub_l;
                        }
                        current_tick = next_tick;
                    }
                } else {
                    current_tick = get_tick_at_sqrt_ratio(current_sqrt_price);
                }
            }

            self.sqrt_price_x96.write(current_sqrt_price);
            self.tick.write(current_tick);
            self.liquidity.write(current_liquidity);

            let caller = get_caller_address();
            self
                .emit(
                    Swap {
                        sender: caller,
                        recipient,
                        amount0_in: total_amount_in,
                        amount1_out: total_amount_out,
                        sqrt_price_x96: current_sqrt_price,
                        liquidity: current_liquidity,
                        tick: current_tick,
                        fee_bps: active_fee_bps,
                    },
                );

            self.unlocked.write(true);
            (total_amount_in, total_amount_out)
        }

        fn flash(
            ref self: ContractState,
            recipient: ContractAddress,
            amount0: u256,
            amount1: u256,
            data: Span<felt252>,
        ) -> (u256, u256) {
            assert!(self.unlocked.read(), "reentrancy locked");
            self.unlocked.write(false);

            // 5 bps flash loan fee
            let fee0 = mul_div_rounding_up(amount0, 5, 10_000);
            let fee1 = mul_div_rounding_up(amount1, 5, 10_000);

            let cur_liq = self.liquidity.read();
            if cur_liq > 0 {
                if fee0 > 0 {
                    let cur_g = self.fee_growth_global_0_x128.read();
                    self
                        .fee_growth_global_0_x128
                        .write(cur_g + mul_div(fee0, Q128, cur_liq.into()));
                }
                if fee1 > 0 {
                    let cur_g = self.fee_growth_global_1_x128.read();
                    self
                        .fee_growth_global_1_x128
                        .write(cur_g + mul_div(fee1, Q128, cur_liq.into()));
                }
            }

            let caller = get_caller_address();
            self.emit(Flash { sender: caller, recipient, amount0, amount1, fee0, fee1 });

            self.unlocked.write(true);
            (fee0, fee1)
        }

        fn get_slot0(self: @ContractState) -> (u256, i32, u32, bool) {
            (
                self.sqrt_price_x96.read(),
                self.tick.read(),
                self.current_pulse_fee.read(),
                self.unlocked.read(),
            )
        }

        fn get_liquidity(self: @ContractState) -> u128 {
            self.liquidity.read()
        }

        fn get_position(
            self: @ContractState, owner: ContractAddress, tick_lower: i32, tick_upper: i32,
        ) -> PositionInfo {
            self.positions.read((owner, tick_lower, tick_upper))
        }

        fn get_tick_info(self: @ContractState, tick: i32) -> TickInfo {
            self.ticks.read(tick)
        }

        fn get_pulse_state(self: @ContractState) -> PulseState {
            PulseState {
                volatility_accumulator: self.volatility_accumulator.read(),
                last_update_timestamp: self.last_pulse_timestamp.read(),
                last_tick: self.last_pulse_tick.read(),
                current_pulse_fee_bps: self.current_pulse_fee.read(),
            }
        }

        fn get_fee_growth_global(self: @ContractState) -> (u256, u256) {
            (self.fee_growth_global_0_x128.read(), self.fee_growth_global_1_x128.read())
        }

        fn get_pool_params(self: @ContractState) -> (ContractAddress, ContractAddress, u32, u32) {
            (self.token0.read(), self.token1.read(), self.fee_bps.read(), self.tick_spacing.read())
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _check_ticks(self: @ContractState, tick_lower: i32, tick_upper: i32) {
            assert!(tick_lower < tick_upper, "lower tick must be < upper");
            assert!(tick_lower >= MIN_TICK, "lower tick below min");
            assert!(tick_upper <= MAX_TICK, "upper tick above max");
            let sp: i32 = self.tick_spacing.read().try_into().unwrap();
            assert!(tick_lower % sp == 0, "lower tick not spaced");
            assert!(tick_upper % sp == 0, "upper tick not spaced");
        }

        fn _update_tick(
            ref self: ContractState, tick: i32, current_tick: i32, amount: u128, is_lower: bool,
        ) {
            let mut tick_data = self.ticks.read(tick);
            let was_initialized = tick_data.initialized;

            tick_data.liquidity_gross += amount;
            let delta_i128: i128 = amount.try_into().unwrap();
            if is_lower {
                tick_data.liquidity_net += delta_i128;
            } else {
                tick_data.liquidity_net -= delta_i128;
            }

            if !was_initialized {
                tick_data.initialized = true;
                if tick <= current_tick {
                    tick_data.fee_growth_outside_0_x128 = self.fee_growth_global_0_x128.read();
                    tick_data.fee_growth_outside_1_x128 = self.fee_growth_global_1_x128.read();
                }
                // Flip bit in word
                let (word_pos, bit_pos) = position(tick);
                let word = self.tick_bitmap.read(word_pos);
                let new_word = flip_tick_in_word(word, bit_pos);
                self.tick_bitmap.write(word_pos, new_word);
            }

            self.ticks.write(tick, tick_data);
        }

        fn _remove_tick_liquidity(
            ref self: ContractState, tick: i32, amount: u128, is_lower: bool,
        ) {
            let mut tick_data = self.ticks.read(tick);
            assert!(tick_data.liquidity_gross >= amount, "insufficient tick gross liquidity");
            tick_data.liquidity_gross -= amount;

            let delta_i128: i128 = amount.try_into().unwrap();
            if is_lower {
                tick_data.liquidity_net -= delta_i128;
            } else {
                tick_data.liquidity_net += delta_i128;
            }

            if tick_data.liquidity_gross == 0 {
                tick_data.initialized = false;
                let (word_pos, bit_pos) = position(tick);
                let word = self.tick_bitmap.read(word_pos);
                let new_word = flip_tick_in_word(word, bit_pos);
                self.tick_bitmap.write(word_pos, new_word);
            }

            self.ticks.write(tick, tick_data);
        }
    }
}
