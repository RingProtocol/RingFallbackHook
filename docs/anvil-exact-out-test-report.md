# Anvil Fork Test Report — Exact-Output 100 (RingFallbackHook)

## Scenario

Swap executed against a live anvil mainnet fork (default `http://127.0.0.1:8545`, override with
`ANVIL_RPC_URL`) using the real mainnet v4 `PoolManager`. All auxiliary contracts (origin tokens,
`MockFewFactory`, FewToken wrappers, hook, test routers) are deployed fresh on the fork by the test.

Test: `test/anvil/RingFallbackHookAnvilTest.sol::test_anvil_exactOut_100_routesToFb()`

### Pool setup (address order intentionally reversed between cur and fb)

The origin pool (cur) and the FewToken pool (fb) list their tokens in **opposite address order**,
mirroring the walkthrough example (origin `0x000` → wrapped `0xfff`, origin `0xabc` → wrapped `0x1234`):

| Role | Address (this run) | Ordering |
|---|---|---|
| PoolManager (mainnet) | `0x000000000004444c5dc75cB358380D2e3dE08A90` | — |
| `token0` — cur `currency0`, origin | `0x1d1499e622D69689cdf9004d05Ec547d650Ff211` | lowest of the pair |
| `token1` — cur `currency1`, origin | `0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9` | higher |
| `few0` = wrap(`token0`) — fb `currency1` | `0x5Fa39CD9DD20a3A77BA0CaD164bD5CF0d7bb3303` | **higher** than `few1` |
| `few1` = wrap(`token1`) — fb `currency0` | `0x4f81992FCe2E1846dD528eC0102e6eE1f61ed3e2` | lower |
| RingFallbackHook | `0xc29a3eBdD7F47cab4Cc3718E5Fb94a37307f0088` | mask `0x88` |

Since `token0 < token1` but `few0 > few1`, the hook derives `orderAligned = false`: the fb pool key is
`(currency0: few1, currency1: few0, fee: 500, tickSpacing: 10, hooks: 0)`. Both pools are initialized at
1:1 (`sqrtPriceX96 = 2^96`).

- cur pool id: `0x75f960649ac6c60394751f41924367ae3abf4547ed5a6d34c6cfa576e80e5d12`
- fb pool id: `0xf7fb78b6bec1c340f75930d96ae6e585230d942ab4d48853ab53e822bd9ed0e2`

Depths (raw units): **cur liquidity = 100**, **fb liquidity = 100000** → fb is strictly deeper, so
`_isFbDeeper` is true and the hook routes the swap to the fb pool.

Swap request on the cur key: `zeroForOne = true`, `amountSpecified = +100` (exact output: receive
exactly 100 of `token1`), `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1`, empty `hookData`.

Because `zeroForOne (true) != orderAligned (false)`, the hook computes `fbZeroForOne = false`:
inside `_executeFbSwap` the fb pool swap **sells `few0` (fb `currency1`) and buys `few1` (fb `currency0`)**,
requesting exactly 100 of `few1` out.

## Requested values

Values are captured from the run via `vm.recordLogs()` (the PoolManager `Swap` event of the fb pool,
emitted with `sender = hook`, and the hook's `FallbackSwap` event).

| Item | Value | Where |
|---|---|---|
| `fbLiquidity` read in `_deriveFbRoute` | **100000** | `poolManager.getLiquidity(fbPoolId)` at `src/RingFallbackHook.sol` line 205 (line 210 after `forge fmt`) |
| `_executeFbSwap` `inputDelta` | **-102** | `delta.amount1()` (fb `currency1` = `few0`, input side; includes fee) |
| `_executeFbSwap` `outputDelta` | **+100** | `delta.amount0()` (fb `currency0` = `few1`, output side) |
| `amountIn` / `amountOut` derived in hook | **102 / 100** | `inputDelta = -amountIn`, `outputDelta = amountOut`; direction check `inputDelta < 0 < outputDelta` passes |
| `specifiedDelta` returned by `beforeSwap` | **-100** | `-amountSpecified` — zeroes the cur-pool swap amount (`amountToSwap = 100 + (-100) = 0`) |
| `unspecifiedDelta` returned by `beforeSwap` | **+102** | exact-output branch: `+amountIn` |

Consistency check on the amount math at `L = 100000`, fee 500 (0.05%): buying exactly 100 out needs
101 in (100 + 1 rounding up from the price-impact computation at that depth), plus the fee on the input
which rounds up to 1 → **102 total input**. The complete-fill check (`actualSpecified == expected`,
output side for exact-output) passes: 100 == 100.

## Swap flow (observed in the trace)

1. Router (`PoolSwapTest`) calls `manager.unlock` → `manager.swap(curKey, ...)`.
2. `beforeSwap` derives the fb route: `fbLiquidity (100000) > curLiquidity (100)` → fb route.
3. `_executeFbSwap` calls `manager.swap(fbKey, oneForZero, +100, limit)`; the PoolManager emits
   `Swap(fbPoolId, sender=hook, amount0=+100, amount1=-102, liquidity=100000, tick>0, fee=500)`.
   So `outputDelta = +100`, `inputDelta = -102`.
4. Inventory check passes, then `_convertAndSettle`: take 102 `token0` from PoolManager → wrap to 102
   `few0` → settle into PoolManager; take 100 `few1` from PoolManager → unwrap to 100 `token1` → settle
   into PoolManager. All balance checks pass; the hook keeps no residual balances.
5. Hook returns `BeforeSwapDelta(specifiedDelta=-100, unspecifiedDelta=+102)`. v4 zeroes the cur-pool swap
   (its `Swap` event carries zero deltas and the cur price stays at 1:1) and applies the hook delta, so
   the caller's final `BalanceDelta` is `(-102, +100)`.
6. Router settles: USER pays 102 `token0` and receives exactly 100 `token1`.

## Post-state assertions (all passed)

- USER `token1` balance: `+100` exactly; `token0` balance: `-102`.
- User `BalanceDelta` from the router: `(-102, +100)`.
- `FallbackSwap` event: `usedFb = true`, `amountIn = 102`, `amountOut = 100`,
  `amountSpecified = 100`.
- cur pool: swap delta `(0, 0)`, price unchanged at 1:1.
- fb pool: price moved off 1:1, active liquidity 100000.
- Hook balances: `token0`, `token1`, `few0`, `few1` all zero after the swap.
- PoolManager inventory shift: `few0 +102`, `few1 -100`; origin balances net unchanged.

## Reproduce

```bash
# with anvil mainnet fork running on 8545
forge test --match-contract RingFallbackHookAnvilTest --match-test test_anvil_exactOut_100_routesToFb -vv
```

Note: the deployed mock addresses shown above are deterministic for the current anvil head state but
will change if the fork head moves. The address-order relationships (`token0 < token1`, `few1 < few0`)
are asserted by `test_anvil_liquidityDepthInputs()` and always hold by construction.
