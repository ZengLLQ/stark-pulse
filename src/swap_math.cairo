//! Swap Step Calculations.
//! Computes token amounts in, amounts out, next sqrt price, and fees for a single tick interval.

use super::math::{mul_div, mul_div_rounding_up};
use super::sqrt_price_math::{
    get_amount0_delta, get_amount1_delta, get_next_sqrt_price_from_amount0_rounding_up,
    get_next_sqrt_price_from_amount1_rounding_down,
};
use super::types::SwapStepResult;

pub const BPS_DENOMINATOR: u32 = 10_000;

/// Computes the result of a single swap step.
pub fn compute_swap_step(
    sqrt_price_current_x96: u256,
    sqrt_price_target_x96: u256,
    liquidity: u128,
    amount_remaining: u256,
    fee_bps: u32,
) -> SwapStepResult {
    let zero_for_one = sqrt_price_current_x96 >= sqrt_price_target_x96;
    let fee_factor: u256 = (BPS_DENOMINATOR - fee_bps).into();
    let bps_denom: u256 = BPS_DENOMINATOR.into();

    if zero_for_one {
        // Price moves downward, input token0, output token1
        let max_amount_in = get_amount0_delta(
            sqrt_price_target_x96, sqrt_price_current_x96, liquidity, true,
        );
        let amount_in_after_fee = mul_div(amount_remaining, fee_factor, bps_denom);

        if amount_in_after_fee >= max_amount_in {
            // Target price reached
            let fee_amount = mul_div_rounding_up(max_amount_in, fee_bps.into(), fee_factor);
            let amount_out = get_amount1_delta(
                sqrt_price_target_x96, sqrt_price_current_x96, liquidity, false,
            );
            SwapStepResult {
                sqrt_price_next_x96: sqrt_price_target_x96,
                amount_in: max_amount_in,
                amount_out,
                fee_amount,
            }
        } else {
            // Partial swap within interval
            let sqrt_price_next_x96 = get_next_sqrt_price_from_amount0_rounding_up(
                sqrt_price_current_x96, liquidity, amount_in_after_fee, true,
            );
            let amount_in = get_amount0_delta(
                sqrt_price_next_x96, sqrt_price_current_x96, liquidity, true,
            );
            let amount_out = get_amount1_delta(
                sqrt_price_next_x96, sqrt_price_current_x96, liquidity, false,
            );
            let fee_amount = amount_remaining - amount_in;
            SwapStepResult { sqrt_price_next_x96, amount_in, amount_out, fee_amount }
        }
    } else {
        // Price moves upward, input token1, output token0
        let max_amount_in = get_amount1_delta(
            sqrt_price_current_x96, sqrt_price_target_x96, liquidity, true,
        );
        let amount_in_after_fee = mul_div(amount_remaining, fee_factor, bps_denom);

        if amount_in_after_fee >= max_amount_in {
            // Target price reached
            let fee_amount = mul_div_rounding_up(max_amount_in, fee_bps.into(), fee_factor);
            let amount_out = get_amount0_delta(
                sqrt_price_current_x96, sqrt_price_target_x96, liquidity, false,
            );
            SwapStepResult {
                sqrt_price_next_x96: sqrt_price_target_x96,
                amount_in: max_amount_in,
                amount_out,
                fee_amount,
            }
        } else {
            // Partial swap within interval
            let sqrt_price_next_x96 = get_next_sqrt_price_from_amount1_rounding_down(
                sqrt_price_current_x96, liquidity, amount_in_after_fee, true,
            );
            let amount_in = get_amount1_delta(
                sqrt_price_current_x96, sqrt_price_next_x96, liquidity, true,
            );
            let amount_out = get_amount0_delta(
                sqrt_price_current_x96, sqrt_price_next_x96, liquidity, false,
            );
            let fee_amount = amount_remaining - amount_in;
            SwapStepResult { sqrt_price_next_x96, amount_in, amount_out, fee_amount }
        }
    }
}
