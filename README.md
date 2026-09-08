# RingFallbackHook


## Overview

`RingFallbackHook` is a Uniswap v4 hook that automatically routes swaps to whichever pool has the better marginal spot price: the origin-token cur pool or the hookless fwA/fwB FewToken fallback pool (fb pool).

- **Routing:** always compares cur and fb `sqrtPriceX96`. Routes to fb when strictly better; otherwise cur executes normally.
- **Slippage protection:** empty `hookData` uses cur's marginal estimate as the safety bound. Non-empty `hookData` (`abi.encode(deadline, amountLimit)`) uses the caller's limit for full slippage protection.

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

### Fallback Request Limits

| Swap type | `amountSpecified` | Meaning of `amountLimit` | Result check |
|---|---:|---|---|
| Exact-input | `< 0` | Minimum acceptable output | `actualAmountOut >= amountLimit` |
| Exact-output | `> 0` | Maximum acceptable input | `actualAmountIn <= amountLimit` |

`amountLimit` must be nonzero. The request reverts if the deadline has expired, the encoding is invalid, the fallback route is unavailable, the swap only partially fills, the actual result violates the limit, or PoolManager inventory is insufficient. An explicit fb request never silently degrades to the cur route.

The empty-data cur path does not apply the fb `deadline` or `amountLimit`. Cur-route protection therefore relies on the router's and user's normal safeguards, including the swap price limit and any router-level deadline or minimum-output/maximum-input checks.

## Design Constraints

| Item | Choice |
|------|--------|
| Route selection | Always spot-price comparison; hookData only controls slippage protection strength |
| Quote comparison | Marginal spot price; caller-supplied limits optional via hookData |
| Constructor | Only `_poolManager` and `_fewFactory`, no poolId |
| fb pool derivation | Derived from cur pool key's token wrappers, same fee/tickSpacing, hookless |
| Liquidity | Anyone may add liquidity to the cur pool |
| Admin powers | No owner, proxy, pause, route setter, fee setter, or sweep |
| Extra fees | None; users only pay the executed pool's LP/protocol fee |
| Wrap/unwrap | Strict 1:1, return value and balance change both checked |
| Native ETH | Cur follows standard v4 behavior; fb routing requires ERC-20 currencies, so use WETH |

### Hook Permissions

```
beforeSwap: true            <- interpret the explicit route request
beforeSwapReturnDelta: true <- replace the cur swap for an fb request
all others: false
```

Permission mask = `0x88` (`BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`)

## Deployment

### 1. Mine hook address

Uniswap v4 requires the hook address's lowest 14 bits to match the permission flags. A CREATE2 salt must be found so the address matches `0x88`.

```bash
forge script script/MineRingFallbackHookAddress.s.sol \
  --rpc-url $ETH_RPC_URL
```

### 2. Deploy hook

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

### 3. Initialize cur pool

After deploying the hook, initialize the cur A/B pool with standard v4 `initialize`. The price is chosen by the LP (no need to mirror the fb pool price).

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

### 4. Add liquidity

Anyone can add liquidity to the cur pool (the hook does not intercept liquidity operations).

## Usage

The hook always compares spot prices and picks the better pool. `hookData` is optional and only provides stronger slippage protection when fb is chosen.

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
    amountSpecified: -1e6, // exact-input
    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
});

// Default: hook compares spot prices and picks the better pool.
// If fb is chosen, cur's marginal estimate is used as the safety bound.
poolManager.swap(curKey, params, "");

// Optional: provide stronger slippage protection when fb is chosen:
uint256 deadline = block.timestamp + 5 minutes;
uint256 minimumOutput = quotedFbOutput * 99 / 100;
poolManager.swap(curKey, params, abi.encode(deadline, minimumOutput));
```

For an exact-output swap, encode the maximum acceptable input instead of a minimum output. Integrators must propagate the encoded bytes through the selected v4-compatible router.

## Contract Addresses

- FewFactory: `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD`
- V4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`

## Testing

```bash
# Unit/integration tests (mocked pools)
forge test -vv

# Fork tests against Ethereum mainnet
forge test --fork-block-number 25833244 -vv
```

## Local Deployment (anvil)

The `DeployLocal.s.sol` script deploys everything from scratch on a local anvil instance: PoolManager, mock tokens, mock FewFactory, hook (mined address), cur pool, fb pool with liquidity, and a test swap to verify fallback routing.

```bash
# Start anvil
anvil --port 8545

# Deploy and verify
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvv
```

The script outputs all deployed contract addresses and the test swap result, confirming whether the requested fb pool or cur pool was used.
