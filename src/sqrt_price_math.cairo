//! Concentrated Liquidity SqrtPrice Math.
//! Implements exact token delta conversions:
//! Delta X = L * (1/sqrt(Pa) - 1/sqrt(Pb)) = L * (sqrt(Pb) - sqrt(Pa)) / (sqrt(Pa) * sqrt(Pb))
//! Delta Y = L * (sqrt(Pb) - sqrt(Pa))
//! and next sqrt price derivation functions with invariant rounding safety.

use super::math::{Q96, mul_div, mul_div_rounding_up};

/// Calculates delta token0 between two sqrt price ratios for a given liquidity amount.
pub fn get_amount0_delta(
    mut sqrt_ratio_a_x96: u256, mut sqrt_ratio_b_x96: u256, liquidity: u128, round_up: bool,
) -> u256 {
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96 {
        let temp = sqrt_ratio_a_x96;
        sqrt_ratio_a_x96 = sqrt_ratio_b_x96;
        sqrt_ratio_b_x96 = temp;
    }
    assert!(sqrt_ratio_a_x96 > 0, "sqrt_ratio_a must be > 0");

    let diff = sqrt_ratio_b_x96 - sqrt_ratio_a_x96;
    if diff == 0 || liquidity == 0 {
        return 0;
    }

    let liq_u256: u256 = liquidity.into();

    if round_up {
        // Delta X = ceil(ceil(L * diff * Q96 / Pb) / Pa)
        let num1 = mul_div_rounding_up(liq_u256, diff, sqrt_ratio_b_x96);
        mul_div_rounding_up(num1, Q96, sqrt_ratio_a_x96)
    } else {
        // Delta X = floor(floor(L * diff * Q96 / Pb) / Pa)
        let num1 = mul_div(liq_u256, diff, sqrt_ratio_b_x96);
        mul_div(num1, Q96, sqrt_ratio_a_x96)
    }
}

/// Calculates delta token1 between two sqrt price ratios for a given liquidity amount.
pub fn get_amount1_delta(
    mut sqrt_ratio_a_x96: u256, mut sqrt_ratio_b_x96: u256, liquidity: u128, round_up: bool,
) -> u256 {
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96 {
        let temp = sqrt_ratio_a_x96;
        sqrt_ratio_a_x96 = sqrt_ratio_b_x96;
        sqrt_ratio_b_x96 = temp;
    }

    let diff = sqrt_ratio_b_x96 - sqrt_ratio_a_x96;
    if diff == 0 || liquidity == 0 {
        return 0;
    }

    let liq_u256: u256 = liquidity.into();

    if round_up {
        mul_div_rounding_up(liq_u256, diff, Q96)
    } else {
        mul_div(liq_u256, diff, Q96)
    }
}

/// Computes the next sqrt price after adding or removing amount0.
pub fn get_next_sqrt_price_from_amount0_rounding_up(
    sqrt_price_x96: u256, liquidity: u128, amount: u256, add: bool,
) -> u256 {
    if amount == 0 {
        return sqrt_price_x96;
    }
    let liq_u256: u256 = liquidity.into();
    let numerator1 = liq_u256 * Q96;

    if add {
        // P_next = (L * Q96 * P) / (L * Q96 + amount * P)
        let product = amount * sqrt_price_x96;
        if product / amount == sqrt_price_x96 {
            let denominator = numerator1 + product;
            if denominator >= numerator1 {
                return mul_div_rounding_up(numerator1, sqrt_price_x96, denominator);
            }
        }
        // If product overflowed, divide both numerator and denominator by P:
        // P_next = (L * Q96) / ( (L * Q96 / P) + amount )
        let denom_part = mul_div(numerator1, 1, sqrt_price_x96);
        mul_div_rounding_up(numerator1, 1, denom_part + amount)
    } else {
        // P_next = (L * Q96 * P) / (L * Q96 - amount * P)
        let product = amount * sqrt_price_x96;
        assert!(product / amount == sqrt_price_x96, "product overflow in amount0 removal");
        assert!(numerator1 > product, "insufficient liquidity for amount0 removal");
        let denominator = numerator1 - product;
        mul_div_rounding_up(numerator1, sqrt_price_x96, denominator)
    }
}

/// Computes the next sqrt price after adding or removing amount1.
pub fn get_next_sqrt_price_from_amount1_rounding_down(
    sqrt_price_x96: u256, liquidity: u128, amount: u256, add: bool,
) -> u256 {
    let liq_u256: u256 = liquidity.into();
    if add {
        // P_next = P + (amount * Q96 / L)
        let quotient = mul_div(amount, Q96, liq_u256);
        sqrt_price_x96 + quotient
    } else {
        // P_next = P - (amount * Q96 / L)
        let quotient = mul_div_rounding_up(amount, Q96, liq_u256);
        assert!(sqrt_price_x96 > quotient, "price drops below zero in amount1 removal");
        sqrt_price_x96 - quotient
    }
}
