# RingFallbackHook Guide

## What is RingFallbackHook?

RingFallbackHook is a Uniswap v4 hook that automatically routes swaps to whichever pool has the better marginal spot price: the origin-token cur pool or the hookless FewToken fallback pool (fb pool). It always compares `sqrtPriceX96` and routes to fb when strictly better. Optional `hookData` provides stronger slippage protection when fb is chosen.

```
beforeSwap receives swap request
  |
  +-- compare cur and fb sqrtPriceX96
  |
  +-- fb strictly better and available?
  |     YES -> execute fb
  |           -> hookData empty? safety check vs cur marginal
  |           -> hookData non-empty? check caller's (deadline, amountLimit)
  |     NO  -> cur pool executes normally (hookData ignored)
```

## Key Concepts

### Cur Pool

The "cur pool" is the Uniswap v4 pool that has RingFallbackHook attached. It trades origin tokens (for example, USDC/USDT) directly. Anyone can add liquidity to this pool; the hook does not restrict liquidity operations. The cur pool is used when fb is unavailable or its spot price is not better.

### Fb Pool

The "fb pool" is a hookless Uniswap v4 pool that trades the FewToken-wrapped versions of the same tokens (for example, fwUSDC/fwUSDT). The hook derives this pool's key at runtime from the cur pool's tokens and the FewFactory registry. Its fee and tick spacing match the cur pool. The hook routes to fb automatically when its spot price is strictly better than cur's.

### FewToken Wrapping

FewTokens (fwA, fwB) are 1:1 wrapped representations of origin tokens. The `FewFactory` contract maps each origin token to its wrapper. Wrapping and unwrapping are strictly 1:1; the hook verifies both the return value and the balance change on every wrap/unwrap operation.

### Flash Conversion

For an fb request, the hook uses Uniswap v4's flash mechanism:

1. **Take** the origin input token from the PoolManager's global balance.
2. **Wrap** it to the corresponding FewToken.
3. **Swap** through the fb pool (fwA -> fwB).
4. **Unwrap** the output FewToken back to the origin token.
5. **Settle** the origin output back to the PoolManager.

The PoolManager must already hold enough physical origin input for the conversion. Insufficient inventory reverts an explicit fb request; it does not redirect the request to cur.

## Route and Slippage Encoding

### Default (empty hookData)

Pass empty bytes:

```solidity
bytes memory hookData = "";
```

The hook compares cur and fb marginal `sqrtPriceX96`. If fb is strictly better, it executes fb and verifies the actual result against cur's marginal estimate (a safety net that catches shallow-pool traps). If fb is not better or unavailable, the cur pool executes normally.

### Optional Caller-Supplied Limits

Pass exactly:

```solidity
bytes memory hookData = abi.encode(uint256(deadline), uint256(amountLimit));
```

The encoding is 64 bytes. `deadline` is the last valid timestamp for the request, and `amountLimit` must be nonzero.

| Swap type | `amountSpecified` | `amountLimit` means | Enforced against |
|---|---:|---|---|
| Exact-input | `< 0` | Minimum output | Actual fb output |
| Exact-output | `> 0` | Maximum input | Actual fb input |

The hook checks the actual fb result, not an estimate. For exact-input, it reverts if `actualAmountOut < amountLimit`. For exact-output, it reverts if `actualAmountIn > amountLimit`.

### Failure Semantics

An explicit fb request reverts if any of the following occurs:

- `hookData` is not the exact `(uint256,uint256)` encoding;
- the request has expired;
- `amountLimit` is zero;
- a wrapper or initialized, liquid fb pool is unavailable;
- the fb swap cannot fill completely;
- the actual output/input violates `amountLimit`;
- PoolManager origin-token inventory is insufficient;
- strict wrapping, unwrapping, balance, or settlement checks fail.

There is no explicit "force fb" mode — the hook always picks the better pool by spot price. If fb is chosen but its liquidity is too shallow, the safety check (or caller's limit) reverts the transaction. The caller cannot override the routing decision via `hookData`; `hookData` only controls slippage protection strength when fb is chosen.

## BeforeSwapDelta

For an fb request, the hook uses `beforeSwapReturnDelta` to replace the cur pool swap:

- `specifiedDelta = -amountSpecified` sets `amountToSwap = 0` in the cur pool.
- `unspecifiedDelta` is based on the actual fb output for exact-input or actual fb input for exact-output.

For empty `hookData` where fb is not better or unavailable, the hook returns a zero delta and the cur pool executes normally. When fb is chosen (empty or non-empty `hookData`), the hook returns a `BeforeSwapDelta` that replaces the cur swap.

## Auto-Routing Safety Model

The hook always uses marginal `sqrtPriceX96` as the routing signal. This is the price for an infinitesimally small trade and does not account for trade size, liquidity depth, or tick crossings. To protect against shallow-pool traps, the hook performs a post-execution safety check when fb is chosen with empty `hookData`:

- For exact-input: fb's actual output must be >= cur's marginal output for the same input.
- For exact-output: fb's actual input must be <= cur's marginal input for the same output.

If the safety check fails, the transaction reverts. This means fb only executes when it is definitively better than cur's best-case scenario. The check is conservative — it may revert in cases where fb is still competitive but does not beat cur's marginal rate. In such cases, the user can retry with `hookData` containing a caller-supplied limit that accepts the actual fb result.

## Optional Caller-Supplied Limits

For stronger slippage protection, the caller can encode `(deadline, amountLimit)` in `hookData`. When fb is chosen and `hookData` is non-empty, the caller's limit is enforced instead of the cur-marginal safety check:

1. derive a nonzero minimum output or maximum input from a complete off-chain fb quote;
2. set a short deadline;
3. encode those values in `hookData` and ensure the router forwards it unchanged.

If fb is not better by spot price, `hookData` is ignored and cur executes normally. The caller's limit only applies when fb is actually chosen.

## Hook Permissions

```
beforeSwap: true            <- interpret the explicit route request
beforeSwapReturnDelta: true <- replace the cur swap for an fb request
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

The fb pool must be initialized separately (by anyone) with the same fee and tick spacing as the cur pool, using the FewToken-wrapped versions of the tokens. If it is unavailable, empty-data cur swaps still work, but explicit fb requests revert.

### Local Testing on Anvil

For local testing, use the all-in-one deployment script:

```bash
anvil --port 8545
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvv
```

This deploys everything from scratch (PoolManager, mock tokens, mock FewFactory, hook, cur pool, and fb pool with liquidity) and runs a test swap to verify fallback routing.

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
    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
});

// Default: hook compares spot prices and picks the better pool.
// If fb is chosen, cur's marginal estimate is used as the safety bound.
poolManager.swap(curKey, params, "");

// Optional: stronger slippage protection when fb is chosen:
poolManager.swap(curKey, params, abi.encode(block.timestamp + 5 minutes, minimumOutput));
```

For an exact-output request, the second encoded value is `maximumInput`.

## Safety Model and Limitations

- **No admin keys:** no owner, upgrade proxy, pause, route setter, fee setter, or sweep.
- **No reentrancy:** `ReentrancyGuard` protects `beforeSwap`.
- **Strict 1:1 wrap/unwrap:** return values and balance changes are verified.
- **No residual balances:** the hook is designed to hold zero tokens after each successful fb swap.
- **Validated hookData:** only empty data or the exact 64-byte fb request encoding is accepted.
- **Actual-result limits:** fb minimum output or maximum input is checked after execution; any violation reverts the transaction atomically.
- **Exact fill required:** exact-input and exact-output fb swaps must fill completely.
- **External quoting required:** the hook provides no optimal-route guarantee; quote quality and route comparison are integration responsibilities.
- **Cur-path safeguards are external:** the cur route relies on router/user protections because it has no encoded fb limit or deadline.
- **Fallback routing requires ERC-20 currencies:** an empty-data cur route retains standard v4 native-currency behavior; use WETH when requesting fb.
- **Fallback routing does not support dynamic fees:** an empty-data cur route retains the pool's standard dynamic-fee behavior.
- **PoolManager inventory dependency:** insufficient physical origin input reverts an fb request.

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| FewFactory | `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD` |
| V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
