//! High-Precision Fixed-Point & Mathematical Primitives for StarkPulse.
//! Implements Q64.96 / Q128.128 fixed-point arithmetic, full 512-bit product division,
//! Babylonian integer square root, and rounding controls.

use core::integer::{u512, u512_safe_div_rem_by_u256};
use core::num::traits::WideMul;
use core::option::OptionTrait;

/// 2^96: Standard fixed-point scale for SqrtPriceX96.
pub const Q96: u256 = 0x1000000000000000000000000; // 79228162514264337593543950336

/// 2^128: Fixed-point scale for cumulative fee growth accumulators.
pub const Q128: u256 = 0x100000000000000000000000000000000;

/// Multiplies two u256 values with a 512-bit intermediate product, then divides by denominator.
/// Rounds down (towards zero).
pub fn mul_div(a: u256, b: u256, denominator: u256) -> u256 {
    assert!(denominator != 0, "mul_div: division by zero");
    if a == 0 || b == 0 {
        return 0;
    }
    let prod: u512 = WideMul::wide_mul(a, b);
    let nz_denom = denominator.try_into().expect('mul_div: zero denom');
    let (quotient, _) = u512_safe_div_rem_by_u256(prod, nz_denom);
    let res: u256 = quotient.try_into().expect('mul_div: overflow');
    res
}

/// Multiplies two u256 values with a 512-bit intermediate product, then divides by denominator.
/// Rounds up (towards infinity).
pub fn mul_div_rounding_up(a: u256, b: u256, denominator: u256) -> u256 {
    assert!(denominator != 0, "mul_div_up: division by zero");
    if a == 0 || b == 0 {
        return 0;
    }
    let prod: u512 = WideMul::wide_mul(a, b);
    let nz_denom = denominator.try_into().expect('mul_div_up: zero denom');
    let (quotient, remainder) = u512_safe_div_rem_by_u256(prod, nz_denom);
    let mut res: u256 = quotient.try_into().expect('mul_div_up: overflow');
    if remainder != 0 {
        assert!(
            res != 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            "mul_div_up: overflow"
        );
        res += 1;
    }
    res
}

/// Computes the integer square root of a 256-bit integer using the Babylonian algorithm.
/// Returns floor(sqrt(y)).
pub fn sqrt(y: u256) -> u256 {
    if y == 0 {
        return 0;
    }
    if y <= 3 {
        return 1;
    }
    let mut z = y;
    let mut x = y / 2 + 1;
    while x < z {
        z = x;
        x = (y / x + x) / 2;
    }
    z
}

/// Absolute difference between two u256 values.
pub fn abs_diff_u256(a: u256, b: u256) -> u256 {
    if a >= b {
        a - b
    } else {
        b - a
    }
}

/// Absolute value of signed 32-bit integer.
pub fn abs_i32(x: i32) -> u32 {
    if x >= 0 {
        x.try_into().unwrap()
    } else {
        (-x).try_into().unwrap()
    }
}

/// Minimum of two u256 integers.
pub fn min_u256(a: u256, b: u256) -> u256 {
    if a < b {
        a
    } else {
        b
    }
}

/// Maximum of two u256 integers.
pub fn max_u256(a: u256, b: u256) -> u256 {
    if a > b {
        a
    } else {
        b
    }
}
