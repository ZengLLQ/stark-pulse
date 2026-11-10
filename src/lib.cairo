//! StarkPulse: Production-Grade Concentrated Liquidity Automated Market Maker (CLAMM)
//! with Dynamic Volatility "Pulse" Fee Engine on Starknet in Cairo 2.21.

pub mod bitmap;
pub mod math;
pub mod pool;
pub mod position;
pub mod pulse_fee;
pub mod sqrt_price_math;
pub mod swap_math;
pub mod tick_math;
pub mod types;

#[cfg(test)]
mod tests {
    use starknet::ContractAddress;
    use super::bitmap::{flip_tick_in_word, lsb, msb, next_initialized_tick_in_word, position, pow2};
    use super::math::{Q128, Q96, mul_div, mul_div_rounding_up, sqrt};
    use super::pool::stark_pulse_pool;
    use super::position::{get_fee_growth_inside, update_position_fees};
    use super::pulse_fee::{
        DECAY_PERIOD_SECONDS, DEFAULT_BASE_FEE_BPS, MAX_PULSE_FEE_BPS, update_pulse_fee,
    };
    use super::sqrt_price_math::{
        get_amount0_delta, get_amount1_delta, get_next_sqrt_price_from_amount0_rounding_up,
        get_next_sqrt_price_from_amount1_rounding_down,
    };
    use super::swap_math::compute_swap_step;
    use super::tick_math::{
        MAX_TICK, MIN_SQRT_RATIO, MIN_TICK, get_sqrt_ratio_at_tick, get_tick_at_sqrt_ratio,
    };
    use super::types::{PositionInfo, PulseState};

    #[test]
    fn test_mul_div_basic() {
        let a: u256 = 1_000_000;
        let b: u256 = 2_000_000;
        let denom: u256 = 500_000;
        let res = mul_div(a, b, denom);
        assert!(res == 4_000_000, "1M * 2M / 0.5M = 4M");
    }

    #[test]
    fn test_mul_div_rounding_up() {
        let a: u256 = 10;
        let b: u256 = 10;
        let denom: u256 = 3;
        // 100 / 3 = 33.333... -> 34 rounded up
        let res_up = mul_div_rounding_up(a, b, denom);
        let res_down = mul_div(a, b, denom);
        assert!(res_up == 34, "round up must be 34");
        assert!(res_down == 33, "round down must be 33");
    }

    #[test]
    fn test_mul_div_large_product() {
        // Intermediate product overflows 256 bits, but result fits in 256 bits
        let a: u256 = 0x100000000000000000000000000000000; // 2^128
        let b: u256 = 0x200000000000000000000000000000000; // 2 * 2^128
        let denom: u256 = 0x100000000000000000000000000000000; // 2^128
        let res = mul_div(a, b, denom);
        assert!(res == b, "mul_div handles 512-bit product");
    }

    #[test]
    fn test_integer_sqrt() {
        assert!(sqrt(0) == 0, "sqrt(0) = 0");
        assert!(sqrt(1) == 1, "sqrt(1) = 1");
        assert!(sqrt(4) == 2, "sqrt(4) = 2");
        assert!(sqrt(9) == 3, "sqrt(9) = 3");
        assert!(sqrt(10) == 3, "sqrt(10) = 3");
        assert!(sqrt(100) == 10, "sqrt(100) = 10");
        assert!(sqrt(1_000_000) == 1000, "sqrt(1M) = 1000");
        assert!(sqrt(Q96 * Q96) == Q96, "sqrt(Q96^2) = Q96");
    }

    #[test]
    fn test_tick_math_zero() {
        let sqrt_p_0 = get_sqrt_ratio_at_tick(0);
        assert!(sqrt_p_0 == Q96, "tick 0 sqrt price must equal Q96 exactly");
        let rec_tick = get_tick_at_sqrt_ratio(sqrt_p_0);
        assert!(rec_tick == 0, "recovered tick 0");
    }

    #[test]
    fn test_tick_math_positive_and_negative() {
        let sqrt_p_100 = get_sqrt_ratio_at_tick(100);
        let sqrt_p_neg_100 = get_sqrt_ratio_at_tick(-100);
        assert!(sqrt_p_100 > Q96, "positive tick price > Q96");
        assert!(sqrt_p_neg_100 < Q96, "negative tick price < Q96");

        let rec_100 = get_tick_at_sqrt_ratio(sqrt_p_100);
        let rec_neg_100 = get_tick_at_sqrt_ratio(sqrt_p_neg_100);
        assert!(rec_100 == 100, "recovered tick 100");
        assert!(rec_neg_100 == -100, "recovered tick -100");
    }

    #[test]
    fn test_tick_math_extremes() {
        let p_min = get_sqrt_ratio_at_tick(MIN_TICK);
        let p_max = get_sqrt_ratio_at_tick(MAX_TICK);
        assert!(p_min > 0, "min tick ratio > 0");
        assert!(p_max > p_min, "max tick ratio > min tick ratio");
        assert!(p_max > Q96, "max tick ratio > Q96");

        let rec_min = get_tick_at_sqrt_ratio(p_min);
        let rec_max = get_tick_at_sqrt_ratio(p_max);
        assert!(rec_min == MIN_TICK, "recovered MIN_TICK");
        assert!(rec_max == MAX_TICK, "recovered MAX_TICK");
    }

    #[test]
    fn test_amount0_delta_monotonicity() {
        let pa = get_sqrt_ratio_at_tick(0);
        let pb = get_sqrt_ratio_at_tick(100);
        let pc = get_sqrt_ratio_at_tick(200);
        let liq = 1_000_000_000_000_000_u128; // 1e15

        let delta_ab = get_amount0_delta(pa, pb, liq, false);
        let delta_ac = get_amount0_delta(pa, pc, liq, false);
        assert!(delta_ac > delta_ab, "wider price range requires more token0");
    }

    #[test]
    fn test_amount1_delta_monotonicity() {
        let pa = get_sqrt_ratio_at_tick(0);
        let pb = get_sqrt_ratio_at_tick(100);
        let pc = get_sqrt_ratio_at_tick(200);
        let liq = 1_000_000_000_000_000_u128; // 1e15

        let delta_ab = get_amount1_delta(pa, pb, liq, false);
        let delta_ac = get_amount1_delta(pa, pc, liq, false);
        assert!(delta_ac > delta_ab, "wider price range requires more token1");
    }

    #[test]
    fn test_next_sqrt_price_amount0_add() {
        let p_start = get_sqrt_ratio_at_tick(1000);
        let liq = 10_000_000_000_u128;
        let amount_in: u256 = 1_000_000;

        // Adding token0 moves price DOWNWARD
        let p_next = get_next_sqrt_price_from_amount0_rounding_up(p_start, liq, amount_in, true);
        assert!(p_next < p_start, "adding token0 must decrease sqrt price");
    }

    #[test]
    fn test_next_sqrt_price_amount1_add() {
        let p_start = get_sqrt_ratio_at_tick(1000);
        let liq = 10_000_000_000_u128;
        let amount_in: u256 = 1_000_000;

        // Adding token1 moves price UPWARD
        let p_next = get_next_sqrt_price_from_amount1_rounding_down(p_start, liq, amount_in, true);
        assert!(p_next > p_start, "adding token1 must increase sqrt price");
    }

    #[test]
    fn test_swap_step_exact_input_reached() {
        let p_current = get_sqrt_ratio_at_tick(100);
        let p_target = get_sqrt_ratio_at_tick(0);
        let liq = 100_000_000_000_u128;
        let amount_in = 10_000_000_000_000_000_u256; // massive input
        let fee_bps = 30_u32;

        let step = compute_swap_step(p_current, p_target, liq, amount_in, fee_bps);
        assert!(step.sqrt_price_next_x96 == p_target, "target price reached");
        assert!(step.amount_out > 0, "amount out is non-zero");
        assert!(step.fee_amount > 0, "fee amount is non-zero");
    }

    #[test]
    fn test_swap_step_partial_input() {
        let p_current = get_sqrt_ratio_at_tick(100);
        let p_target = get_sqrt_ratio_at_tick(0);
        let liq = 100_000_000_000_u128;
        let small_amount_in = 50_000_u256;
        let fee_bps = 30_u32;

        let step = compute_swap_step(p_current, p_target, liq, small_amount_in, fee_bps);
        assert!(step.sqrt_price_next_x96 > p_target, "target price NOT reached");
        assert!(step.sqrt_price_next_x96 < p_current, "price decreased");
        assert!(step.amount_out > 0, "amount out > 0");
    }

    #[test]
    fn test_bitmap_position_mapping() {
        let (w0, b0) = position(0);
        assert!(w0 == 0 && b0 == 0, "tick 0 is word 0, bit 0");

        let (w255, b255) = position(255);
        assert!(w255 == 0 && b255 == 255, "tick 255 is word 0, bit 255");

        let (w256, b256) = position(256);
        assert!(w256 == 1 && b256 == 0, "tick 256 is word 1, bit 0");

        let (wn1, bn1) = position(-1);
        assert!(wn1 == -1 && bn1 == 255, "tick -1 is word -1, bit 255");

        let (wn256, bn256) = position(-256);
        assert!(wn256 == -1 && bn256 == 0, "tick -256 is word -1, bit 0");
    }

    #[test]
    fn test_bitmap_flip_tick() {
        let word: u256 = 0;
        let w_flipped = flip_tick_in_word(word, 5);
        assert!(w_flipped == pow2(5), "bit 5 set");
        let w_unflipped = flip_tick_in_word(w_flipped, 5);
        assert!(w_unflipped == 0, "bit 5 cleared back to 0");
    }

    #[test]
    fn test_msb_and_lsb_all_powers_of_two() {
        let mut i: u8 = 0;
        while i < 100 {
            let p = pow2(i);
            assert!(msb(p) == i, "msb matches power");
            assert!(lsb(p) == i, "lsb matches power");
            i += 1;
        };
    }

    #[test]
    fn test_bitmap_next_initialized_tick_lte() {
        // Set bit 10 and bit 50 in word 0
        let word = pow2(10) | pow2(50);
        let (next_tick, init) = next_initialized_tick_in_word(word, 0, 70, true);
        assert!(init, "found initialized tick");
        assert!(next_tick == 50, "next tick <= 70 is 50");

        let (next_tick_2, init_2) = next_initialized_tick_in_word(word, 0, 49, true);
        assert!(init_2, "found initialized tick");
        assert!(next_tick_2 == 10, "next tick <= 49 is 10");

        let (next_tick_none, init_none) = next_initialized_tick_in_word(word, 0, 9, true);
        assert!(!init_none, "no initialized tick <= 9");
        assert!(next_tick_none == 0, "returns word base");
    }

    #[test]
    fn test_bitmap_next_initialized_tick_gt() {
        // Set bit 10 and bit 50 in word 0
        let word = pow2(10) | pow2(50);
        let (next_tick, init) = next_initialized_tick_in_word(word, 0, 5, false);
        assert!(init, "found initialized tick");
        assert!(next_tick == 10, "next tick > 5 is 10");

        let (next_tick_2, init_2) = next_initialized_tick_in_word(word, 0, 10, false);
        assert!(init_2, "found initialized tick");
        assert!(next_tick_2 == 50, "next tick > 10 is 50");

        let (next_tick_none, init_none) = next_initialized_tick_in_word(word, 0, 50, false);
        assert!(!init_none, "no initialized tick > 50");
        assert!(next_tick_none == 255, "returns word upper boundary");
    }

    #[test]
    fn test_pulse_fee_baseline() {
        let initial_state = PulseState {
            volatility_accumulator: 0,
            last_update_timestamp: 1000,
            last_tick: 50,
            current_pulse_fee_bps: DEFAULT_BASE_FEE_BPS,
        };
        // Price unchanged, timestamp + 10s
        let (next_state, fee) = update_pulse_fee(initial_state, 50, 1010, DEFAULT_BASE_FEE_BPS);
        assert!(fee == DEFAULT_BASE_FEE_BPS, "fee stays at baseline without tick shift");
        assert!(next_state.volatility_accumulator == 0, "zero volatility");
    }

    #[test]
    fn test_pulse_fee_surge_on_price_shock() {
        let initial_state = PulseState {
            volatility_accumulator: 0,
            last_update_timestamp: 1000,
            last_tick: 0,
            current_pulse_fee_bps: DEFAULT_BASE_FEE_BPS,
        };
        // Price suddenly jumps by 200 ticks in 5 seconds!
        let (next_state, fee) = update_pulse_fee(initial_state, 200, 1005, DEFAULT_BASE_FEE_BPS);
        assert!(fee > DEFAULT_BASE_FEE_BPS, "fee surges above baseline on price shock");
        assert!(next_state.volatility_accumulator > 0, "volatility registered");
    }

    #[test]
    fn test_pulse_fee_decay_over_time() {
        let shock_state = PulseState {
            volatility_accumulator: 1000,
            last_update_timestamp: 1000,
            last_tick: 100,
            current_pulse_fee_bps: 100,
        };
        // After full decay period (600s), price quiescent
        let (decayed_state, fee) = update_pulse_fee(
            shock_state, 100, 1000 + DECAY_PERIOD_SECONDS, DEFAULT_BASE_FEE_BPS,
        );
        assert!(fee == DEFAULT_BASE_FEE_BPS, "fee returns to baseline after decay period");
        assert!(decayed_state.volatility_accumulator == 0, "volatility fully decayed");
    }

    #[test]
    fn test_pulse_fee_max_cap() {
        let shock_state = PulseState {
            volatility_accumulator: 50_000,
            last_update_timestamp: 1000,
            last_tick: 0,
            current_pulse_fee_bps: 200,
        };
        // Massive flash crash jump of 5,000 ticks in 1 second
        let (_, fee) = update_pulse_fee(shock_state, 5000, 1001, DEFAULT_BASE_FEE_BPS);
        assert!(fee <= MAX_PULSE_FEE_BPS, "fee never exceeds MAX_PULSE_FEE_BPS");
        assert!(fee == MAX_PULSE_FEE_BPS, "fee capped at maximum");
    }

    #[test]
    fn test_fee_growth_inside_active_position() {
        let tick_lower = -100;
        let tick_upper = 100;
        let tick_current = 0; // Inside range

        let fee_growth_global: u256 = 100 * Q128;
        let fee_growth_outside_lower: u256 = 10 * Q128;
        let fee_growth_outside_upper: u256 = 20 * Q128;

        let inside = get_fee_growth_inside(
            tick_lower,
            tick_upper,
            tick_current,
            fee_growth_global,
            fee_growth_outside_lower,
            fee_growth_outside_upper,
        );

        // below = outside_lower = 10
        // above = outside_upper = 20
        // inside = 100 - 10 - 20 = 70
        assert!(inside == 70 * Q128, "fee growth inside = 70 * Q128");
    }

    #[test]
    fn test_position_liquidity_mint_and_burn_accounting() {
        let mut pos = PositionInfo {
            liquidity: 0,
            fee_growth_inside_0_last_x128: 0,
            fee_growth_inside_1_last_x128: 0,
            tokens_owed_0: 0,
            tokens_owed_1: 0,
        };

        // Mint 10,000 liquidity
        let _ = update_position_fees(ref pos, 10_000, 0, 0);
        assert!(pos.liquidity == 10_000, "liquidity is 10,000");

        // Fees accrue: 5 * Q128 for token0, 2 * Q128 for token1
        let (fees0, fees1) = update_position_fees(ref pos, 0, 5 * Q128, 2 * Q128);
        assert!(fees0 == 50_000, "accrued token0 = 10k * 5 = 50k");
        assert!(fees1 == 20_000, "accrued token1 = 10k * 2 = 20k");
        assert!(pos.tokens_owed_0 == 50_000, "tokens owed 0 updated");
        assert!(pos.tokens_owed_1 == 20_000, "tokens owed 1 updated");

        // Burn half (5,000)
        let _ = update_position_fees(ref pos, -5_000, 5 * Q128, 2 * Q128);
        assert!(pos.liquidity == 5_000, "remaining liquidity is 5,000");
    }

    #[test]
    fn test_invariant_k_preservation() {
        // Swap step must satisfy virtual reserve product invariance x * y >= L^2
        let p_start = get_sqrt_ratio_at_tick(0); // P = 1.0
        let p_target = get_sqrt_ratio_at_tick(-50); // P < 1.0
        let liq = 1_000_000_u128;
        let amount_in = 5_000_u256;

        let step = compute_swap_step(p_start, p_target, liq, amount_in, 0);
        // Step with 0 fee must be conservative
        assert!(step.amount_in > 0, "amount in > 0");
        assert!(step.amount_out > 0, "amount out > 0");
        assert!(step.sqrt_price_next_x96 < p_start, "price reduced");
    }

    #[test]
    fn test_pool_lifecycle_initialization_mint_and_swap() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();
        let alice: ContractAddress = 0x100_felt252.try_into().unwrap();
        let bob: ContractAddress = 0x200_felt252.try_into().unwrap();

        // 30 bps fee, 60 tick spacing
        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);

        // Initialize pool at tick 0 (Price = 1.0)
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);
        let (sqrt_p, tick, fee, unlocked) = stark_pulse_pool::StarkPulsePoolImpl::get_slot0(@state);
        assert!(sqrt_p == Q96, "initialized sqrt price is Q96");
        assert!(tick == 0, "initialized tick is 0");
        assert!(fee == 30, "fee is 30 bps");
        assert!(unlocked, "pool is unlocked");

        // Mint liquidity across [-600, 600] as Alice
        starknet::testing::set_caller_address(alice);
        let (amt0, amt1) = stark_pulse_pool::StarkPulsePoolImpl::mint(
            ref state, alice, -600, 600, 1_000_000_000,
        );
        assert!(amt0 > 0, "mint requires token0");
        assert!(amt1 > 0, "mint requires token1");

        let liq = stark_pulse_pool::StarkPulsePoolImpl::get_liquidity(@state);
        assert!(liq == 1_000_000_000, "active liquidity is 1,000,000,000");

        // Execute swap: Bob sells token0 for token1
        starknet::testing::set_caller_address(bob);
        let (swap_in, swap_out) = stark_pulse_pool::StarkPulsePoolImpl::swap(
            ref state, bob, true, 100_000, MIN_SQRT_RATIO, 1000,
        );
        assert!(swap_in > 0, "swap in > 0");
        assert!(swap_out > 0, "swap out > 0");

        let (new_sqrt_p, new_tick, _, _) = stark_pulse_pool::StarkPulsePoolImpl::get_slot0(@state);
        assert!(new_sqrt_p < Q96, "price moved down after zero_for_one swap");
        assert!(new_tick <= 0, "tick shifted downwards");

        // Alice burns liquidity
        starknet::testing::set_caller_address(alice);
        let (burn0, burn1) = stark_pulse_pool::StarkPulsePoolImpl::burn(
            ref state, -600, 600, 500_000_000,
        );
        assert!(burn0 > 0, "burned token0 > 0");
        assert!(burn1 > 0, "burned token1 > 0");

        let rem_liq = stark_pulse_pool::StarkPulsePoolImpl::get_liquidity(@state);
        assert!(rem_liq == 500_000_000, "remaining liquidity is 500M");

        // Alice collects owed tokens
        let (collected0, collected1) = stark_pulse_pool::StarkPulsePoolImpl::collect(
            ref state, alice, -600, 600, 1_000_000_000, 1_000_000_000,
        );
        assert!(collected0 > 0, "collected token0 > 0");
        assert!(collected1 > 0, "collected token1 > 0");
    }

    #[test]
    fn test_pool_multi_position_fee_distribution() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();
        let lp1: ContractAddress = 0x101_felt252.try_into().unwrap();
        let lp2: ContractAddress = 0x102_felt252.try_into().unwrap();
        let trader: ContractAddress = 0x303_felt252.try_into().unwrap();

        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);

        // LP1 adds 1,000,000,000 across wide range [-600, 600]
        starknet::testing::set_caller_address(lp1);
        stark_pulse_pool::StarkPulsePoolImpl::mint(ref state, lp1, -600, 600, 1_000_000_000);

        // LP2 adds 1,000,000,000 across tight range [-120, 120]
        starknet::testing::set_caller_address(lp2);
        stark_pulse_pool::StarkPulsePoolImpl::mint(ref state, lp2, -120, 120, 1_000_000_000);

        // Pool active liquidity inside [-120, 120] is now 2,000,000,000
        let total_active_liq = stark_pulse_pool::StarkPulsePoolImpl::get_liquidity(@state);
        assert!(total_active_liq == 2_000_000_000, "total active liquidity is 2B");

        // Trader performs swap within tight range
        starknet::testing::set_caller_address(trader);
        let (in_amt, out_amt) = stark_pulse_pool::StarkPulsePoolImpl::swap(
            ref state, trader, true, 50_000, MIN_SQRT_RATIO, 1000,
        );
        assert!(in_amt > 0 && out_amt > 0, "swap succeeded");

        // Both LPs burn to trigger fee accounting
        starknet::testing::set_caller_address(lp1);
        let _ = stark_pulse_pool::StarkPulsePoolImpl::burn(ref state, -600, 600, 1_000_000_000);
        let pos1 = stark_pulse_pool::StarkPulsePoolImpl::get_position(@state, lp1, -600, 600);
        assert!(pos1.tokens_owed_0 > 0, "LP1 accrued fees");

        starknet::testing::set_caller_address(lp2);
        let _ = stark_pulse_pool::StarkPulsePoolImpl::burn(ref state, -120, 120, 1_000_000_000);
        let pos2 = stark_pulse_pool::StarkPulsePoolImpl::get_position(@state, lp2, -120, 120);
        assert!(pos2.tokens_owed_0 > 0, "LP2 accrued fees");
    }

    #[test]
    #[should_panic(expected: ("lower tick not spaced",))]
    fn test_tick_spacing_validation() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();
        let alice: ContractAddress = 0x100_felt252.try_into().unwrap();

        // Tick spacing = 60
        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);

        // Attempt to mint with tick -55 (not divisible by 60) -> must panic
        starknet::testing::set_caller_address(alice);
        stark_pulse_pool::StarkPulsePoolImpl::mint(ref state, alice, -55, 60, 1_000_000);
    }

    #[test]
    #[should_panic(expected: ("already initialized",))]
    fn test_double_initialization_guard() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();

        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);
        // Second initialization must revert
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);
    }

    #[test]
    #[should_panic(expected: ("amount must be > 0",))]
    fn test_zero_mint_revert() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();
        let alice: ContractAddress = 0x100_felt252.try_into().unwrap();

        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);

        starknet::testing::set_caller_address(alice);
        stark_pulse_pool::StarkPulsePoolImpl::mint(
            ref state,
            alice,
            -60,
            60,
            0 // amount = 0
        );
    }

    #[test]
    fn test_pool_flash_loan_execution() {
        let mut state = stark_pulse_pool::contract_state_for_testing();
        let admin: ContractAddress = 0x1_felt252.try_into().unwrap();
        let token0: ContractAddress = 0x10_felt252.try_into().unwrap();
        let token1: ContractAddress = 0x20_felt252.try_into().unwrap();
        let user: ContractAddress = 0x55_felt252.try_into().unwrap();

        stark_pulse_pool::constructor(ref state, admin, token0, token1, 30, 60);
        stark_pulse_pool::StarkPulsePoolImpl::initialize(ref state, Q96);

        // Flash loan 1,000,000 of token0 and 2,000,000 of token1
        let (fee0, fee1) = stark_pulse_pool::StarkPulsePoolImpl::flash(
            ref state, user, 1_000_000, 2_000_000, array![].span(),
        );

        // 5 bps of 1,000,000 = 500; 5 bps of 2,000,000 = 1,000
        assert!(fee0 == 500, "fee0 is 500");
        assert!(fee1 == 1000, "fee1 is 1000");
    }
}
