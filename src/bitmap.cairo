//! Tick Word-Level Bitmap Traversal for StarkPulse.
//! Indexes initialized ticks in 256-bit words and implements O(1) jump lookups
//! using 8-step binary logarithmic MSB and LSB scanning.

/// Computes the word position and bit position within the word for a given tick.
pub fn position(tick: i32) -> (i16, u8) {
    let mut word_pos: i16 = (tick / 256).try_into().unwrap();
    let mut bit_pos_i32: i32 = tick % 256;

    if bit_pos_i32 < 0 {
        word_pos -= 1;
        bit_pos_i32 += 256;
    }
    let bit_pos: u8 = bit_pos_i32.try_into().unwrap();
    (word_pos, bit_pos)
}

/// Computes 2^n for n in [0, 255] as a u256.
pub fn pow2(n: u8) -> u256 {
    let mut res: u256 = 1;
    let mut base: u256 = 2;
    let mut p = n;
    while p > 0 {
        if (p & 1) != 0 {
            res *= base;
        }
        if p > 1 {
            base *= base;
        }
        p /= 2;
    }
    res
}

/// Finds the most significant bit (0 to 255) of a non-zero u256 in 8 branch steps.
pub fn msb(mut x: u256) -> u8 {
    assert!(x != 0, "msb: zero input");
    let mut r: u8 = 0;
    if x >= 0x100000000000000000000000000000000 {
        x /= 0x100000000000000000000000000000000;
        r += 128;
    }
    if x >= 0x10000000000000000 {
        x /= 0x10000000000000000;
        r += 64;
    }
    if x >= 0x100000000 {
        x /= 0x100000000;
        r += 32;
    }
    if x >= 0x10000 {
        x /= 0x10000;
        r += 16;
    }
    if x >= 0x100 {
        x /= 0x100;
        r += 8;
    }
    if x >= 0x10 {
        x /= 0x10;
        r += 4;
    }
    if x >= 0x4 {
        x /= 0x4;
        r += 2;
    }
    if x >= 0x2 {
        r += 1;
    }
    r
}

/// Finds the least significant bit (0 to 255) of a non-zero u256 using isolated lowest bit.
pub fn lsb(x: u256) -> u8 {
    assert!(x != 0, "lsb: zero input");
    let not_x = ~x;
    let neg_x = if not_x == 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff {
        0
    } else {
        not_x + 1
    };
    let lowest_bit = x & neg_x;
    msb(lowest_bit)
}

/// Flips the bit corresponding to tick in the given 256-bit word.
pub fn flip_tick_in_word(word: u256, bit_pos: u8) -> u256 {
    let mask = pow2(bit_pos);
    word ^ mask
}

/// Searches for the next initialized tick within a single 256-bit word.
/// Returns (next_tick, initialized).
pub fn next_initialized_tick_in_word(
    word: u256, word_pos: i16, bit_pos: u8, lte: bool,
) -> (i32, bool) {
    let word_base_tick: i32 = word_pos.into() * 256;

    if lte {
        // Find greatest initialized tick <= current bit_pos
        // Mask: all bits <= bit_pos set to 1
        let mask = if bit_pos == 255 {
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        } else {
            (pow2(bit_pos) * 2) - 1
        };
        let masked = word & mask;
        if masked != 0 {
            let next_bit = msb(masked);
            let next_tick = word_base_tick + next_bit.into();
            (next_tick, true)
        } else {
            // No initialized tick <= bit_pos in this word; return lower boundary
            (word_base_tick, false)
        }
    } else {
        // Find smallest initialized tick > current bit_pos
        // Mask: all bits > bit_pos set to 1
        let mask = if bit_pos == 255 {
            0
        } else {
            let low_mask = (pow2(bit_pos) * 2) - 1;
            ~low_mask
        };
        let masked = word & mask;
        if masked != 0 {
            let next_bit = lsb(masked);
            let next_tick = word_base_tick + next_bit.into();
            (next_tick, true)
        } else {
            // No initialized tick > bit_pos in this word; return upper boundary
            (word_base_tick + 255, false)
        }
    }
}
