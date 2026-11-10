# StarkPulse

[![CI](https://github.com/ZengLLQ/stark-pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/ZengLLQ/stark-pulse/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Cairo](https://img.shields.io/badge/cairo-2.21.0-orange.svg)](https://www.cairo-lang.org/)
[![Starknet](https://img.shields.io/badge/starknet-v0.13-purple.svg)](https://starknet.io/)

Production-Grade Concentrated Liquidity Automated Market Maker (CLAMM) with Q64.96 Fixed-Point Sqrt-Price Math, 256-Bit Word-Level Tick Bitmap Traversal, Dynamic Volatility-Adaptive "Pulse" Fees, and Multi-Position Liquidity Management in Cairo 2.21 on Starknet.

---

## 1. Overview & Core Features

StarkPulse is a high-performance decentralized exchange engine engineered natively for the Starknet zk-Rollup. It leverages Cairo 2.21's provable execution, high-precision numeric types, and native account abstraction to deliver:

- **Concentrated Capital Efficiency**: Liquidity providers allocate capital within custom price intervals $[t_{\text{lower}}, t_{\text{upper}}]$, achieving up to 4000x higher capital utilization than classical $x \cdot y = k$ invariant pools.
- **Q64.96 Fixed-Point Arithmetic**: Sqrt-price ratios ($\sqrt{P} = \sqrt{y / x} \cdot 2^{96}$) and $512$-bit intermediate multiplication (`mul_div`) ensure exact token delta computation with zero precision loss.
- **Logarithmic Tick Math**: Binary power series expansion converts signed ticks $i \in [-887272, 887272]$ to $\sqrt{P}(i)$ with sub-$10^{-28}$ relative error across the entire price spectrum ($2^{-128}$ to $2^{128}$).
- **Hierarchical 256-Bit Word Bitmap**: Fast $O(1)$ initialized tick lookup using constant-time 8-step logarithmic binary scans (MSB/LSB) eliminating unbounded loops during multi-tick swap traversal.
- **Dynamic "Pulse" Volatility Fee**: Real-time tick velocity tracking combines exponential time-decay filtering with quadratic fee surge scaling, taxing toxic arbitrage flow during high volatility and directly rewarding active LPs.
- **$O(1)$ Position Fee Accounting**: Uncollected fees per position are determined via global and tick-outside fee checkpoints ($f_{\text{inside}} = f_{\text{global}} - f_{\text{below}} - f_{\text{above}}$) without iterating through intermediary ticks.
- **Flash Swaps & Reentrancy Guards**: Atomic optimistic liquidity borrowing with Cancun-style invariant verification and transient reentrancy locking.

---

## 2. Protocol Architecture

```mermaid
flowchart TD
    Trader([Trader / Swapper]) -->|Swap Token0 / Token1| Pool[StarkPulse Pool Contract]
    LP([Liquidity Provider]) -->|Mint / Burn Range [t_l, t_u]| Pool
    Arbitrageur([Arbitrageur / Bot]) -->|Flash Loan 5 bps| Pool

    subgraph Core Mathematical Engine
        Pool -->|Fixed-Point Sqrt Price| SqrtMath[SqrtPriceMath]
        Pool -->|Tick Index to Ratio| TickMath[TickMath 20-bit Series]
        Pool -->|Single-Step Swap Calculation| SwapMath[SwapMath]
        Pool -->|Fast Tick Skipping| Bitmap[Word-Level Bitmap Scanner]
        Pool -->|Dynamic Surge Fee| PulseFee[Pulse Fee Engine]
        Pool -->|Fee Growth Inside Position| Position[Position Manager]
    end

    PulseFee -->|Tick Velocity & Exponential Decay| DynamicFee[Active Fee BPS: 30 bps -> 500 bps]
    Bitmap -->|Next Initialized Tick| SwapMath
```

---

## 3. Mathematical Foundations

### 3.1 Sqrt Price and Token Deltas
The pool maintains active virtual reserves satisfying $(x + \frac{L}{\sqrt{P_b}})(y + L \sqrt{P_a}) = L^2$. For an active price range $[\sqrt{P_a}, \sqrt{P_b}]$ with $\sqrt{P_a} < \sqrt{P_b}$:

$$\Delta x = L \cdot \frac{\sqrt{P_b} - \sqrt{P_a}}{\sqrt{P_a} \cdot \sqrt{P_b}}$$

$$\Delta y = L \cdot (\sqrt{P_b} - \sqrt{P_a})$$

Token delta computations utilize 512-bit intermediate product division:
```cairo
DeltaX = mul_div(L, diff, Pb) * Q96 / Pa
DeltaY = mul_div(L, diff, Q96)
```

### 3.2 Binary Decomposition of Tick Space
Each discrete tick $i$ defines an exact price ratio $P(i) = 1.0001^i$. The square root price $\sqrt{P}(i) = 1.0001^{i/2} \cdot 2^{96}$ is calculated by decomposing $|i|$ into its binary powers:

$$\sqrt{P}(i) = \prod_{k=0}^{19} \left( 1.0001^{2^k / 2} \right)^{b_k}$$

where $b_k \in \{0, 1\}$. Precomputed 128-bit reciprocal constants yield exact values down to machine epsilon.

### 3.3 Dynamic "Pulse" Volatility Accumulator
To mitigate Loss-Versus-Rebalancing (LVR) and extract rents from toxic flow during market shocks, the pool updates its volatility accumulator $V_t$:

$$V_t = V_{t - \Delta t} \cdot \max\left(0, 1 - \frac{\Delta t}{T_{\text{decay}}}\right) + |\Delta \text{tick}| \cdot \alpha$$

$$\text{Fee}(V_t) = \min\left(\text{BaseFee} + \frac{V_t^2 \cdot \kappa}{100000}, \text{MaxFee}\right)$$

Where $T_{\text{decay}} = 600\text{s}$ (10 minutes), $\alpha = 10$, $\kappa = 5$, and $\text{MaxFee} = 500\text{ bps}$ ($5.0\%$).

---

## 4. Codebase Structure

```
stark-pulse/
├── Scarb.toml               # Scarb package manifest (Cairo 2.21.0 & Starknet)
├── .github/
│   └── workflows/
│       └── ci.yml           # Automated Scarb CI pipeline
├── src/
│   ├── lib.cairo            # Module declarations & comprehensive test suite (31 tests)
│   ├── types.cairo          # Protocol structs, enums, events, and storage types
│   ├── math.cairo           # Q64.96/Q128 fixed-point math, 512-bit mul_div, integer sqrt
│   ├── tick_math.cairo      # Logarithmic tick to sqrt price conversion & binary search
│   ├── sqrt_price_math.cairo# Token delta equations & price derivations
│   ├── swap_math.cairo      # Intra-tick swap step calculations with fee extraction
│   ├── bitmap.cairo         # 256-bit word bitmap indexing & O(1) MSB/LSB jumps
│   ├── pulse_fee.cairo      # Dynamic volatility accumulator & surge fee engine
│   ├── position.cairo       # Position management & O(1) fee growth inside accumulator
│   └── pool.cairo           # Starknet smart contract implementing IStarkPulsePool
└── LICENSE                  # Apache License 2.0
```

---

## 5. Quality Gates & Test Suite

The protocol is validated by 31 unit, invariant, and integration tests executed via `scarb test`:

```bash
# Check code formatting compliance
scarb fmt --check

# Compile smart contracts to Sierra & CASM
scarb build

# Run unit, integration, and invariant test suite
scarb test
```

### Verified Test Matrix:
- `test_mul_div_basic` & `test_mul_div_large_product`: 512-bit intermediate product division validation.
- `test_mul_div_rounding_up`: Invariant round-up verification preventing token leakage.
- `test_integer_sqrt`: Babylonian integer square root correctness across all ranges.
- `test_tick_math_zero`, `test_tick_math_positive_and_negative`, `test_tick_math_extremes`: Mathematical accuracy across boundaries $[-887272, 887272]$.
- `test_amount0_delta_monotonicity` & `test_amount1_delta_monotonicity`: Virtual liquidity invariant proofs.
- `test_next_sqrt_price_amount0_add` & `test_next_sqrt_price_amount1_add`: Price progression invariants.
- `test_swap_step_exact_input_reached` & `test_swap_step_partial_input`: Intra-tick swap exactness.
- `test_bitmap_position_mapping` & `test_bitmap_flip_tick`: Word position and bit index mapping.
- `test_msb_and_lsb_all_powers_of_two`: 8-step constant-time bit scan verification.
- `test_bitmap_next_initialized_tick_lte` & `test_bitmap_next_initialized_tick_gt`: Multi-word boundary search.
- `test_pulse_fee_baseline`, `test_pulse_fee_surge_on_price_shock`, `test_pulse_fee_decay_over_time`, `test_pulse_fee_max_cap`: Dynamic fee responsiveness and safety caps.
- `test_fee_growth_inside_active_position`: $O(1)$ fee checkpoint mathematics.
- `test_position_liquidity_mint_and_burn_accounting`: Accrued token tracking upon position adjustments.
- `test_invariant_k_preservation`: Monotonic non-decreasing virtual invariant check.
- `test_pool_lifecycle_initialization_mint_and_swap`: Full lifecycle integration test.
- `test_pool_multi_position_fee_distribution`: Multi-LP overlapping range fee accrual.
- `test_pool_flash_loan_execution`: 5 bps flash swap execution and fee accumulation.
- `test_tick_spacing_validation`: Guard rejecting misaligned tick positions.
- `test_double_initialization_guard`: Reentrancy and double initialization protection.
- `test_zero_mint_revert`: Input validation checks.

---

## 6. Security Invariants

1. **Strict Reentrancy Lock**: State transitions set `unlocked = false` before balance modifications or external callbacks, clearing back to `true` upon completion.
2. **Tick Spacing Alignment**: Initialized ticks must satisfy `tick % tick_spacing == 0` to preserve uniform bitmap distribution.
3. **Liquidity Net Conservation**: The algebraic sum of net liquidity across all initialized ticks equals zero: $\sum \Delta L_{\text{net}} = 0$.
4. **Non-Negative Fees**: Protocol and LP fee accumulators are monotonically non-decreasing.

---

## 7. License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
