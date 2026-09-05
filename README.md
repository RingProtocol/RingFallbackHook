# RingFallbackHook

> Status: not deployed, not audited

## Overview

`RingFallbackHook` is a Uniswap v4 hook that exposes two explicitly selected routes for an origin-token A/B pool:

- **Cur route:** empty `hookData` always leaves the swap in the current A/B pool (cur pool).
- **Fb route:** non-empty `hookData` must be `abi.encode(uint256 deadline, uint256 amountLimit)` and explicitly requests execution through the corresponding hookless fwA/fwB FewToken fallback pool (fb pool).

The hook does not compare spot prices or automatically select a route. An off-chain quoter or router must obtain full, trade-size-aware quotes for both routes, compare them, and submit the selected route with appropriate safeguards.

```
Off-chain quoter compares complete cur and fb route quotes
  |
  +-- choose cur -> pass empty hookData -> cur pool executes normally
  |                                      (FewToken not touched)
  |
  +-- choose fb  -> pass abi.encode(deadline, amountLimit)
                    -> take A -> wrap fwA -> fb swap -> unwrap fwB -> settle B
                    (cur pool swap replaced by BeforeSwapDelta no-op)
```

## Core Logic

1. `beforeSwap` intercepts each swap request.
2. Empty `hookData` returns a zero delta, so the cur pool executes normally.
3. Non-empty `hookData` must be exactly the ABI encoding of `(uint256 deadline, uint256 amountLimit)` and explicitly selects fb.
4. The hook derives fwA/fwB from the cur pool's token0/token1 through `FewFactory.getWrappedToken()`.
5. It constructs the hookless fb pool key with the same fee and tick spacing.
6. It executes the fb swap, verifies a complete fill, and checks `amountLimit` against the actual result.
7. It returns a `BeforeSwapDelta` that replaces the cur swap.

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
| Route selection | Explicit; empty data selects cur, encoded data selects fb |
| Quote comparison | Required off chain using complete route quotes |
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

The caller must quote both routes off chain before choosing `hookData`.

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

// Explicit cur route:
poolManager.swap(curKey, params, "");

// Explicit fb route, after an off-chain quote comparison:
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
