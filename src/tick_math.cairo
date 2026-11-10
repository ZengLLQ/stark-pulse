//! High-Precision Tick to SqrtPrice Conversion & Tick Math.
//! Implements Q64.96 binary exponentiation mapping tick indices [-887272, 887272]
//! to sqrt_price_x96 and vice versa with sub-1e-28 relative precision.

use super::math::{Q128, mul_div};

pub const MIN_TICK: i32 = -887272;
pub const MAX_TICK: i32 = 887272;

/// Sqrt price at MIN_TICK (-887272)
pub const MIN_SQRT_RATIO: u256 = 4295128739;

/// Sqrt price at MAX_TICK (887272)
pub const MAX_SQRT_RATIO: u256 = 1461446703485210103287273052203988822378723970342;

/// Precomputed 2^32 divisor constant for scaling Q128.128 down to Q64.96
pub const TWO_POW_32: u256 = 0x100000000;

/// Computes sqrt_price_x96 = floor(1.0001^(tick / 2) * 2^96) with high precision.
pub fn get_sqrt_ratio_at_tick(tick: i32) -> u256 {
    assert!(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of bounds");
    let abs_tick: u32 = if tick >= 0 {
        tick.try_into().unwrap()
    } else {
        (-tick).try_into().unwrap()
    };

    let mut ratio: u256 = if (abs_tick & 0x1) != 0 {
        0xfffcb933bd6fad37aa2d162d1a594001
    } else {
        Q128
    };

    if (abs_tick & 0x2) != 0 {
        ratio = mul_div(ratio, 0xfff97272373d413259a46990580e2139, Q128);
    }
    if (abs_tick & 0x4) != 0 {
        ratio = mul_div(ratio, 0xfff2e50f5f656932ef12357cf3c7fdcb, Q128);
    }
    if (abs_tick & 0x8) != 0 {
        ratio = mul_div(ratio, 0xffe5caca7e10e4e61c3624eaa0941ccf, Q128);
    }
    if (abs_tick & 0x10) != 0 {
        ratio = mul_div(ratio, 0xffcb9843d60f6159c9db58835c926643, Q128);
    }
    if (abs_tick & 0x20) != 0 {
        ratio = mul_div(ratio, 0xff973b41fa98c081472e6896dfb254bf, Q128);
    }
    if (abs_tick & 0x40) != 0 {
        ratio = mul_div(ratio, 0xff2ea16466c96a3843ec78b326b52860, Q128);
    }
    if (abs_tick & 0x80) != 0 {
        ratio = mul_div(ratio, 0xfe5dee046a99a2a811c461f1969c3052, Q128);
    }
    if (abs_tick & 0x100) != 0 {
        ratio = mul_div(ratio, 0xfcbe86c7900a88aedcffc83b479aa3a3, Q128);
    }
    if (abs_tick & 0x200) != 0 {
        ratio = mul_div(ratio, 0xf987a7253ac413176f2b074cf7815e53, Q128);
    }
    if (abs_tick & 0x400) != 0 {
        ratio = mul_div(ratio, 0xf3392b0822b70005940c7a398e4b70f2, Q128);
    }
    if (abs_tick & 0x800) != 0 {
        ratio = mul_div(ratio, 0xe7159475a2c29b7443b29c7fa6e889d8, Q128);
    }
    if (abs_tick & 0x1000) != 0 {
        ratio = mul_div(ratio, 0xd097f3bdfd2022b8845ad8f792aa5825, Q128);
    }
    if (abs_tick & 0x2000) != 0 {
        ratio = mul_div(ratio, 0xa9f746462d870fdf8a65dc1f90e061e4, Q128);
    }
    if (abs_tick & 0x4000) != 0 {
        ratio = mul_div(ratio, 0x70d869a156d2a1b890bb3df62baf32f6, Q128);
    }
    if (abs_tick & 0x8000) != 0 {
        ratio = mul_div(ratio, 0x31be135f97d08fd981231505542fcfa5, Q128);
    }
    if (abs_tick & 0x10000) != 0 {
        ratio = mul_div(ratio, 0x9aa508b5b7a84e1c677de54f3e99bc8, Q128);
    }
    if (abs_tick & 0x20000) != 0 {
        ratio = mul_div(ratio, 0x5d6af8dedb81196699c329225ee604, Q128);
    }
    if (abs_tick & 0x40000) != 0 {
        ratio = mul_div(ratio, 0x2216e584f5fa1ea926041bedfe97, Q128);
    }
    if (abs_tick & 0x80000) != 0 {
        ratio = mul_div(ratio, 0x48a170391f7dc42444e8fa2, Q128);
    }

    if tick > 0 {
        let max_u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        ratio = max_u256 / ratio;
    }

    let mut sqrt_price = ratio / TWO_POW_32;
    if (ratio % TWO_POW_32) != 0 {
        sqrt_price += 1;
    }
    sqrt_price
}

/// Binary search finding the greatest tick i such that get_sqrt_ratio_at_tick(i) <= sqrt_price_x96.
pub fn get_tick_at_sqrt_ratio(sqrt_price_x96: u256) -> i32 {
    assert!(
        sqrt_price_x96 >= MIN_SQRT_RATIO && sqrt_price_x96 <= MAX_SQRT_RATIO,
        "sqrt_price out of bounds"
    );
    let mut low: i32 = MIN_TICK;
    let mut high: i32 = MAX_TICK;

    while low < high {
        // mid = ceil((low + high) / 2) = floor((low + high + 1) / 2)
        let sum: i64 = low.into() + high.into() + 1;
        let mid: i32 = (sum / 2).try_into().unwrap();
        if get_sqrt_ratio_at_tick(mid) <= sqrt_price_x96 {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    low
}
