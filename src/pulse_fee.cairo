//! Dynamic Volatility "Pulse" Fee Engine for StarkPulse.
//! Dynamically adjusts pool swap fees based on real-time price tick velocity,
//! penalizing toxic arbitrage flows and rewarding active liquidity providers.

use super::math::abs_i32;
use super::types::PulseState;

/// Default baseline swap fee: 30 bps (0.30%).
pub const DEFAULT_BASE_FEE_BPS: u32 = 30;

/// Maximum surge fee cap: 500 bps (5.00%).
pub const MAX_PULSE_FEE_BPS: u32 = 500;

/// Half-life decay period in seconds (600s = 10 minutes).
pub const DECAY_PERIOD_SECONDS: u64 = 600;

/// Scaling factor for tick displacement impulse.
pub const VOLATILITY_SCALE: u64 = 10;

/// Quadratic surge fee sensitivity factor.
pub const SURGE_COEFFICIENT: u64 = 5;

/// Computes the updated pulse fee state and current fee bps.
pub fn update_pulse_fee(
    current_state: PulseState, current_tick: i32, current_timestamp: u64, base_fee_bps: u32,
) -> (PulseState, u32) {
    let dt: u64 = if current_timestamp > current_state.last_update_timestamp {
        current_timestamp - current_state.last_update_timestamp
    } else {
        0
    };

    // 1. Exponential decay of accumulated volatility
    let decayed_vol: u64 = if dt >= DECAY_PERIOD_SECONDS {
        0
    } else {
        let remaining_time = DECAY_PERIOD_SECONDS - dt;
        (current_state.volatility_accumulator * remaining_time) / DECAY_PERIOD_SECONDS
    };

    // 2. Measure instantaneous price displacement
    let tick_delta = abs_i32(current_tick - current_state.last_tick);
    let impulse: u64 = tick_delta.into() * VOLATILITY_SCALE;
    let new_vol: u64 = decayed_vol + impulse;

    // 3. Compute quadratic surge fee
    // surge_bps = (V^2 * coefficient) / 100_000
    let surge_fee_bps: u64 = (new_vol * new_vol * SURGE_COEFFICIENT) / 100_000;
    let total_fee_u64: u64 = base_fee_bps.into() + surge_fee_bps;

    let clamped_fee_bps: u32 = if total_fee_u64 > MAX_PULSE_FEE_BPS.into() {
        MAX_PULSE_FEE_BPS
    } else {
        total_fee_u64.try_into().unwrap()
    };

    let new_state = PulseState {
        volatility_accumulator: new_vol,
        last_update_timestamp: current_timestamp,
        last_tick: current_tick,
        current_pulse_fee_bps: clamped_fee_bps,
    };

    (new_state, clamped_fee_bps)
}
