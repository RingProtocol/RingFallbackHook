# RingFallbackHook

> Status: not deployed, not audited

## Overview

`RingFallbackHook` is a Uniswap v4 hook that provides **smart routing** for an origin-token A/B pool. On every swap, the hook compares the marginal price of the current A/B pool (cur pool) against the corresponding hookless fwA/fwB FewToken fallback pool (fb pool), and **automatically executes against whichever pool offers the better price**.

```
User swaps A -> B (via Universal Router)
  |
  +-- hook compares cur A/B pool vs fb fwA/fwB pool sqrtPriceX96
  |
  +-- fb is better -> take A -> wrap fwA -> fb swap -> unwrap fwB -> settle B
  |                   (cur pool swap replaced by BeforeSwapDelta no-op)
  |
  +-- cur is better -> return zero delta, cur pool executes normally
                       (FewToken not touched)
```

## Core Logic

**If the cur pool's quote is worse than the FewToken fallback pool's quote, use the fb pool.**

Implementation:
1. `beforeSwap` intercepts every swap request
2. Derives fwA/fwB from the cur pool's token0/token1 via `FewFactory.getWrappedToken()`
3. Constructs the fb pool key: `PoolKey(fwA, fwB, same fee, same tickSpacing, address(0))`
4. Reads both pools' `sqrtPriceX96` and compares marginal prices by swap direction
5. If fb is better and PoolManager inventory is sufficient -> execute fb swap, return `BeforeSwapDelta` to replace the cur swap
6. Otherwise -> return zero delta, cur pool handles the swap

### Price Comparison Rules

`sqrtPriceX96 = sqrt(price1/price0) * 2^96`

| Swap direction | Better price | fb is better when |
|----------------|-------------|---------------------|
| zeroForOne (sell token0, buy token1) | higher sqrtPriceX96 | fbPrice > curPrice |
| oneForZero (sell token1, buy token0) | lower sqrtPriceX96 | fbPrice < curPrice |

When the fb pool's token order is reversed (`!orderAligned`), its `sqrtPriceX96` must be inverted: `normalized = 2^192 / fbSqrtPriceX96`.

### Graceful Fallback

The hook automatically falls back to the cur pool when:
- FewFactory has no registered wrapper for one of the tokens
- fb pool is not initialized or has no active liquidity
- cur pool is not initialized
- PoolManager global balance is insufficient for the flash conversion
- fb pool price is not better than cur pool price

## Design Constraints

| Item | Choice |
|------|--------|
| Constructor | Only `_poolManager` and `_fewFactory`, no poolId |
| fb pool derivation | Derived from cur pool key's token wrappers, same fee/tickSpacing, hookless |
| Liquidity | Anyone may add liquidity to the cur pool |
| Admin powers | No owner, proxy, pause, route setter, fee setter, or sweep |
| Extra fees | None; users only pay the executed pool's LP/protocol fee |
| Wrap/unwrap | Strict 1:1, return value and balance change both checked |
| Native ETH | Not supported; WETH works as a regular ERC-20 |

### Hook Permissions

```
beforeSwap: true            <- intercept swap for price comparison and routing
beforeSwapReturnDelta: true <- replace cur swap when fb is better
all others: false
```

Permission mask = `0x88` (`BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`)

### Price Comparison Limitations

V1 uses marginal price (`sqrtPriceX96`) for comparison, which does not account for:
- Trade size vs liquidity depth (large trades may get different actual output due to slippage)
- Liquidity distribution differences between the two pools

For large trades, the pool with a better marginal price may produce a worse actual output due to slippage. A future version could use V4Quoter for full quote comparison.

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

For frontend users, it works exactly like a normal v4 pool -- swap via Universal Router. The hook transparently selects the better route.

```solidity
// Standard V4 swap
PoolKey memory curKey = PoolKey({
    currency0: USDC,
    currency1: USDT,
    fee: 500,
    tickSpacing: 10,
    hooks: IHooks(fallbackHookAddress)
});

poolManager.swap(curKey, SwapParams({
    zeroForOne: true,
    amountSpecified: -1e6,
    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
}), "");
```

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

The script outputs all deployed contract addresses and the test swap result, confirming whether the fb pool or cur pool was used.
