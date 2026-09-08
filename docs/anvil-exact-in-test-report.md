# Anvil Fork Test Report — Exact-Input 50 (RingFallbackHook)

## Scenario

Swap executed against a live anvil mainnet fork (default `http://127.0.0.1:8545`, override with
`ANVIL_RPC_URL`) using the real mainnet v4 `PoolManager`. All auxiliary contracts (origin tokens,
`MockFewFactory`, FewToken wrappers, hook, test routers) are deployed fresh on the fork by the test.

Test: `test/anvil/RingFallbackHookAnvilTest.sol::test_anvil_exactIn_50_routesToFb()`

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

Swap request on the cur key: `zeroForOne = true`, `amountSpecified = -50` (exact input 50 of `token0`),
`sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1`, empty `hookData`.

Because `zeroForOne (true) != orderAligned (false)`, the hook computes `fbZeroForOne = false`:
inside `_executeFbSwap` the fb pool swap **sells `few0` (fb `currency1`) and buys `few1` (fb `currency0`)**.

## Requested values

Values are captured from the run via `vm.recordLogs()` (the PoolManager `Swap` event of the fb pool,
emitted with `sender = hook`, and the hook's `FallbackSwap` event).

| Item | Value | Where |
|---|---|---|
| `fbLiquidity` read in `_deriveFbRoute` | **100000** | `poolManager.getLiquidity(fbPoolId)` at `src/RingFallbackHook.sol` line 205 (line 210 after `forge fmt`) |
| `_executeFbSwap` `inputDelta` | **-50** | `delta.amount1()` (fb `currency1` = `few0`, input side) |
| `_executeFbSwap` `outputDelta` | **+48** | `delta.amount0()` (fb `currency0` = `few1`, output side) |
| `amountIn` / `amountOut` derived in hook | **50 / 48** | `inputDelta = -amountIn`, `outputDelta = amountOut`; direction check `inputDelta < 0 < outputDelta` passes |
| `specifiedDelta` returned by `beforeSwap` | **+50** | `-amountSpecified` — zeroes the cur-pool swap amount (`amountToSwap = -50 + 50 = 0`) |
| `unspecifiedDelta` returned by `beforeSwap` | **-48** | exact-input branch: `-amountOut` |

Consistency check on the amount math at `L = 100000`, fee 500 (0.05%): fee on 50 rounds up to 1, so 49
is swapped; with the price impact at that depth the output rounds down to **48**. The complete-fill check
(`actualSpecified == expected`, input side for exact-input) passes: 50 == 50.

## Swap flow (observed in the trace)

1. Router (`PoolSwapTest`) calls `manager.unlock` → `manager.swap(curKey, ...)`.
2. `beforeSwap` derives the fb route: `fbLiquidity (100000) > curLiquidity (100)` → fb route.
3. `_executeFbSwap` calls `manager.swap(fbKey, oneForZero, -50, limit)`; the PoolManager emits
   `Swap(fbPoolId, sender=hook, amount0=+48, amount1=-50, liquidity=100000, tick=9, fee=500)`.
   So `inputDelta = -50`, `outputDelta = +48`.
4. Inventory check passes, then `_convertAndSettle`: take 50 `token0` from PoolManager → wrap to 50
   `few0` → settle into PoolManager; take 48 `few1` from PoolManager → unwrap to 48 `token1` → settle
   into PoolManager. All balance checks pass; the hook keeps no residual balances.
5. Hook returns `BeforeSwapDelta(specifiedDelta=+50, unspecifiedDelta=-48)`. v4 zeroes the cur-pool swap
   (its `Swap` event carries zero deltas and the cur price stays at 1:1) and applies the hook delta, so
   the caller's final `BalanceDelta` is `(-50, +48)`.
6. Router settles: USER pays exactly 50 `token0` and receives 48 `token1`.

## Post-state assertions (all passed)

- USER `token0` balance: `-50`; `token1` balance: `+48`.
- User `BalanceDelta` from the router: `(-50, +48)`.
- `FallbackSwap` event: `usedFb = true`, `amountIn = 50`, `amountOut = 48`.
- cur pool: swap delta `(0, 0)`, price unchanged at 1:1.
- fb pool: price moved (tick 0 → 9), active liquidity 100000.
- Hook balances: `token0`, `token1`, `few0`, `few1` all zero after the swap.
- PoolManager inventory shift: `few0 +50`, `few1 -48`; origin balances net unchanged.

## Reproduce

```bash
# with anvil mainnet fork running on 8545
forge test --match-contract RingFallbackHookAnvilTest --match-test test_anvil_exactIn_50_routesToFb -vv
```

Note: the deployed mock addresses shown above are deterministic for the current anvil head state but
will change if the fork head moves. The address-order relationships (`token0 < token1`, `few1 < few0`)
are asserted by `test_anvil_liquidityDepthInputs()` and always hold by construction.
