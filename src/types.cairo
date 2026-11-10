use starknet::ContractAddress;

/// Swap direction: token0 for token1, or token1 for token0.
#[derive(Copy, Drop, Serde, PartialEq)]
pub enum SwapDirection {
    ZeroForOne,
    OneForZero,
}

/// Identifies an immutable pool by its token pair, base fee, and tick spacing.
#[derive(Copy, Drop, Serde, PartialEq, Hash)]
pub struct PoolKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee_bps: u32,
    pub tick_spacing: u32,
}

/// Core global pool state packed into single slot.
#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub struct Slot0 {
    pub sqrt_price_x96: u256,
    pub tick: i32,
    pub fee_protocol: u32,
    pub unlocked: bool,
}

/// State of an individual LP concentrated liquidity position.
#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub struct PositionInfo {
    pub liquidity: u128,
    pub fee_growth_inside_0_last_x128: u256,
    pub fee_growth_inside_1_last_x128: u256,
    pub tokens_owed_0: u128,
    pub tokens_owed_1: u128,
}

/// Information stored at an initialized tick.
#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub struct TickInfo {
    pub liquidity_gross: u128,
    pub liquidity_net: i128,
    pub fee_growth_outside_0_x128: u256,
    pub fee_growth_outside_1_x128: u256,
    pub initialized: bool,
}

/// Intermediate and final result of one swap step within a single tick range.
#[derive(Copy, Drop, Serde, PartialEq)]
pub struct SwapStepResult {
    pub sqrt_price_next_x96: u256,
    pub amount_in: u256,
    pub amount_out: u256,
    pub fee_amount: u256,
}

/// Dynamic Volatility "Pulse" fee state.
#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub struct PulseState {
    pub volatility_accumulator: u64,
    pub last_update_timestamp: u64,
    pub last_tick: i32,
    pub current_pulse_fee_bps: u32,
}

/// Return data from liquidity minting.
#[derive(Copy, Drop, Serde, PartialEq)]
pub struct MintResult {
    pub amount0: u256,
    pub amount1: u256,
}

/// Return data from liquidity burning.
#[derive(Copy, Drop, Serde, PartialEq)]
pub struct BurnResult {
    pub amount0: u256,
    pub amount1: u256,
}

/// Return data from pool swap execution.
#[derive(Copy, Drop, Serde, PartialEq)]
pub struct SwapResult {
    pub amount_in: u256,
    pub amount_out: u256,
    pub final_sqrt_price_x96: u256,
    pub final_tick: i32,
    pub active_fee_bps: u32,
}
