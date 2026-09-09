# RingFallbackHook Guide

## What is RingFallbackHook?

RingFallbackHook is a Uniswap v4 hook that routes swaps to whichever pool has more active liquidity: the origin-token cur pool or the hookless FewToken fallback pool (fb pool). It compares the two pools' in-range liquidity (`getLiquidity`) and routes to fb when it is strictly deeper. `hookData` is ignored — routing is always depth-based.

```
beforeSwap receives swap request
  |
  +-- derive fb route from cur pool key + FewFactory
  |
  +-- fb available and strictly deeper than cur?
  |     YES -> execute fb (flash wrap -> fb swap -> unwrap -> settle)
  |           -> sqrtPriceLimitX96 mapped into fb's price space
  |           -> swap must fill completely or the whole tx reverts
  |     NO  -> cur pool executes normally
```

## Key Concepts

### Cur Pool

The "cur pool" is the Uniswap v4 pool that has RingFallbackHook attached. It trades origin tokens (for example, USDC/USDT) directly. Anyone can add liquidity to this pool; the hook does not restrict liquidity operations. The cur pool is used when fb is unavailable or not strictly deeper.

### Fb Pool

The "fb pool" is a hookless Uniswap v4 pool that trades the FewToken-wrapped versions of the same tokens (for example, fwUSDC/fwUSDT). The hook derives this pool's key at runtime from the cur pool's tokens and the FewFactory registry. Its fee and tick spacing match the cur pool. The hook routes to fb automatically when its active liquidity is strictly greater than cur's.

### Depth-Based Routing

The hook compares the two pools' active (in-range) liquidity via `poolManager.getLiquidity` and routes to fb when `fbLiquidity > curLiquidity`. Equal liquidity routes to cur. Since FewTokens are 1:1 wrappers and the fb pool shares the cur pool's fee and tick spacing, arbitrage keeps the two prices close; the deeper pool absorbs a given trade with less price impact. Note that liquidity depth is the routing signal, not marginal spot price — a deeper fb pool is chosen even if its marginal price is momentarily worse.

### FewToken Wrapping

FewTokens (fwA, fwB) are 1:1 wrapped representations of origin tokens. The `FewFactory` contract maps each origin token to its wrapper. Wrapping and unwrapping are strictly 1:1; the hook verifies both the return value and the balance change on every wrap/unwrap operation.

### Flash Conversion

For an fb-routed swap, the hook uses Uniswap v4's flash mechanism:

1. **Take** the origin input token from the PoolManager's global balance.
2. **Wrap** it to the corresponding FewToken.
3. **Swap** through the fb pool (fwA -> fwB).
4. **Unwrap** the output FewToken back to the origin token.
5. **Settle** the origin output back to the PoolManager.

The PoolManager must already hold enough physical origin input for the conversion. Insufficient inventory reverts the swap; it does not redirect the request to cur.

## Routing and Slippage Protection

`hookData` is ignored entirely. Slippage protection relies on v4's native mechanisms:

- **`sqrtPriceLimitX96`** — the caller-supplied limit is mapped into the fb pool's price space before the fb swap. When the fb pool's token order is inverted relative to cur (`few0 > few1`), the limit is inverted accordingly (`2^192 / limit`) and clamped to the valid sqrt-price range.
- **Router safeguards** — the caller's router (e.g., a position manager or external router) enforces deadline, minimum output, and maximum input, exactly as it would for a direct v4 swap.
- **Complete fill** — exact-input and exact-output fb swaps must fill completely; a partial fill reverts the whole transaction (`FbSwapPartialFill`).

### Failure Semantics

A swap reverts if any of the following occurs on the fb route:

- either currency is native ETH (use WETH-wrapped tokens);
- the cur pool has a dynamic fee;
- a wrapper is missing, not a contract, does not map back to its origin token, or duplicates the other wrapper;
- the fb pool has zero active liquidity;
- PoolManager origin-token inventory is insufficient;
- the fb swap cannot fill completely;
- the fb swap returns a direction-inconsistent delta;
- strict wrapping, unwrapping, balance, or settlement checks fail.

There is no route override and no partial-fill fallback. If fb is unavailable or not deeper, the cur pool executes normally with the caller's original parameters (including `sqrtPriceLimitX96`).

## BeforeSwapDelta

When fb is chosen, the hook uses `beforeSwapReturnDelta` to replace the cur pool swap:

- `specifiedDelta = -amountSpecified` sets `amountToSwap = 0` in the cur pool.
- `unspecifiedDelta` is based on the actual fb output for exact-input or actual fb input for exact-output.

When fb is not chosen, the hook returns a zero delta and the cur pool executes normally.

## Depth-Routing Safety Model

Routing on active liquidity is simple and manipulation-resistant in the intended deployment:

- **Liquidity is the signal.** In-range liquidity is a scalar independent of token ordering and cannot be inflated without committing real capital to the pool.
- **Arbitrage alignment.** Because wrapping is 1:1, any price gap between cur and fb is arbitraged back toward parity; the deeper pool is then the one that fills a given trade with less impact.
- **No best-execution guarantee.** Depth routing does not compare realized prices. A trade can still be routed to fb when cur's marginal price is momentarily better. Callers who need execution guarantees should use `sqrtPriceLimitX96` and router-level deadline/min-out/max-in protections.
- **Partial fills revert.** If fb's liquidity cannot absorb the full requested amount, the entire transaction reverts rather than filling partially.

## Hook Permissions

```
beforeSwap: true            <- route between cur and fb pools
beforeSwapReturnDelta: true <- replace the cur swap for an fb-routed swap
all others: false
```

Permission mask = `0x88` (`BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`)

The hook does **not** use:

- `beforeInitialize` -- anyone can create pools with this hook
- `beforeAddLiquidity` -- anyone can add liquidity
- `beforeRemoveLiquidity` -- anyone can remove liquidity
- `afterSwap` -- no post-swap logic needed
- `dynamicFee` -- the fee is static and shared between cur and fb pools

## Deployment

### Step 1: Mine the Hook Address

Uniswap v4 requires the hook address's lowest 14 bits to match the permission flags. Use the mining script to find a CREATE2 salt:

```bash
forge script script/MineRingFallbackHookAddress.s.sol \
  --rpc-url $ETH_RPC_URL
```

Output:

```
HOOK_SALT: 0x...
EXPECTED_HOOK_ADDRESS: 0x...
```

### Step 2: Deploy the Hook

```bash
forge script script/DeployRingFallbackHook.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast \
  --private-key $PK
```

Environment variables:

- `HOOK_SALT` (from step 1)
- `EXPECTED_HOOK_ADDRESS` (from step 1)
- `V4_POOL_MANAGER` (optional, defaults to Ethereum mainnet)
- `FEW_FACTORY` (optional, defaults to Ring Protocol mainnet)

### Step 3: Initialize the Cur Pool

After deploying the hook, initialize the cur A/B pool with the desired starting price:

```solidity
PoolKey memory curKey = PoolKey({
    currency0: Currency.wrap(token0),
    currency1: Currency.wrap(token1),
    fee: 500,
    tickSpacing: 10,
    hooks: IHooks(fallbackHookAddress)
});
poolManager.initialize(curKey, desiredSqrtPriceX96);
```

The price is chosen by the LP; there is no requirement to mirror the fb pool's price.

### Step 4: Add Liquidity

Anyone can add liquidity to the cur pool. The hook does not intercept liquidity operations.

### Step 5: Ensure the Fb Pool Exists

The fb pool must be initialized separately (by anyone) with the same fee and tick spacing as the cur pool, using the FewToken-wrapped versions of the tokens. Until it exists and holds liquidity, all swaps execute on the cur pool. Note that the fb pool must be **strictly deeper** than cur for routing to switch; keep cur liquidity depth in mind when seeding the fb pool.

### Local Testing on Anvil

For local testing, use the all-in-one deployment script:

```bash
anvil --port 8545
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvv
```

This deploys everything from scratch (PoolManager, mock tokens, mock FewFactory, hook, cur pool, and fb pool with liquidity) and runs a test swap to verify fallback routing.

Additional anvil-based test reports with worked examples (address-order inversion, exact-input and exact-output fills) are available in:

- `docs/anvil-exact-in-test-report.md`
- `docs/anvil-exact-out-test-report.md`
- `docs/anvil-test-report-explained.md`

## Usage

```solidity
PoolKey memory curKey = PoolKey({
    currency0: USDC,
    currency1: USDT,
    fee: 500,
    tickSpacing: 10,
    hooks: IHooks(fallbackHookAddress)
});

SwapParams memory params = SwapParams({
    zeroForOne: true,
    amountSpecified: -1e6,
    sqrtPriceLimitX96: minPriceLimitX96 // caller's price limit; mapped into fb's space when fb is used
});

// hookData is ignored. The hook routes to fb when it is strictly deeper
// than cur; otherwise the cur pool executes normally.
poolManager.swap(curKey, params, "");
```

Slippage protection comes from `sqrtPriceLimitX96` (honored on both routes, mapped into the fb pool's price space when inverted) plus whatever deadline / min-out / max-in checks the caller's router applies.

## Safety Model and Limitations

- **No admin keys:** no owner, upgrade proxy, pause, route setter, fee setter, or sweep.
- **No reentrancy:** `ReentrancyGuard` protects `beforeSwap`.
- **Strict 1:1 wrap/unwrap:** return values and balance changes are verified.
- **No residual balances:** the hook is designed to hold zero tokens after each successful fb swap.
- **hookData ignored:** no user-supplied route selection, addresses, or limits are accepted.
- **Exact fill required:** exact-input and exact-output fb swaps must fill completely.
- **Depth-based routing, not best-price:** no on-chain quote comparison or best-execution guarantee; use price limits and router safeguards.
- **Cur-path safeguards are external:** the cur route relies on router/user protections (`sqrtPriceLimitX96`, deadline, min-out/max-in).
- **Fallback routing requires ERC-20 currencies:** native-ETH cur pools fall back to a normal cur swap.
- **Fallback routing does not support dynamic fees:** dynamic-fee cur pools fall back to a normal cur swap.
- **PoolManager inventory dependency:** insufficient physical origin input reverts an fb-routed swap.

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| FewFactory | `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD` |
| V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
