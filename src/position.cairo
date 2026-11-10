//! Concentrated Liquidity Position Management & Fee Accounting.
//! Computes fee growth inside positions in O(1) time and updates position shares and accrued
//! tokens.

use super::math::{Q128, mul_div};
use super::types::PositionInfo;

/// Computes the fee growth inside [tick_lower, tick_upper] for token0 or token1.
pub fn get_fee_growth_inside(
    tick_lower: i32,
    tick_upper: i32,
    tick_current: i32,
    fee_growth_global_x128: u256,
    fee_growth_outside_lower_x128: u256,
    fee_growth_outside_upper_x128: u256,
) -> u256 {
    // 1. Fee growth below tick_lower
    let fee_growth_below: u256 = if tick_current >= tick_lower {
        fee_growth_outside_lower_x128
    } else {
        fee_growth_global_x128 - fee_growth_outside_lower_x128
    };

    // 2. Fee growth above tick_upper
    let fee_growth_above: u256 = if tick_current < tick_upper {
        fee_growth_outside_upper_x128
    } else {
        fee_growth_global_x128 - fee_growth_outside_upper_x128
    };

    // 3. Fee growth inside = global - below - above
    fee_growth_global_x128 - fee_growth_below - fee_growth_above
}

/// Updates an LP position with a liquidity delta and calculates uncollected fees.
pub fn update_position_fees(
    ref position: PositionInfo,
    liquidity_delta: i128,
    fee_growth_inside_0_x128: u256,
    fee_growth_inside_1_x128: u256,
) -> (u128, u128) {
    let mut fees_uncollected_0: u128 = 0;
    let mut fees_uncollected_1: u128 = 0;

    if position.liquidity > 0 {
        let delta_growth_0 = fee_growth_inside_0_x128 - position.fee_growth_inside_0_last_x128;
        let delta_growth_1 = fee_growth_inside_1_x128 - position.fee_growth_inside_1_last_x128;

        let fees_0 = mul_div(position.liquidity.into(), delta_growth_0, Q128);
        let fees_1 = mul_div(position.liquidity.into(), delta_growth_1, Q128);

        fees_uncollected_0 = fees_0.try_into().unwrap_or(0);
        fees_uncollected_1 = fees_1.try_into().unwrap_or(0);
    }

    position.tokens_owed_0 += fees_uncollected_0;
    position.tokens_owed_1 += fees_uncollected_1;
    position.fee_growth_inside_0_last_x128 = fee_growth_inside_0_x128;
    position.fee_growth_inside_1_last_x128 = fee_growth_inside_1_x128;

    if liquidity_delta > 0 {
        position.liquidity += liquidity_delta.try_into().unwrap();
    } else if liquidity_delta < 0 {
        let neg_delta: u128 = (-liquidity_delta).try_into().unwrap();
        assert!(position.liquidity >= neg_delta, "position: insufficient liquidity to burn");
        position.liquidity -= neg_delta;
    }

    (fees_uncollected_0, fees_uncollected_1)
}
