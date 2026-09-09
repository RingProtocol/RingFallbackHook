# RingFallbackHook Allowlist Application

## Overview

Uniswap Labs maintains a **routing allowlist** for hooks that use certain permissions. Pools with allowlisted hooks are eligible for inclusion in the Uniswap Labs interface routing algorithm. Without allowlisting, swaps through the hook's pools will not be routed by the Uniswap Labs frontend (though they remain fully functional via direct contract calls or third-party routers).

RingFallbackHook **requires allowlisting** because it uses the `beforeSwapReturnDelta` flag.

## Does This Hook Need Allowlisting?

Yes. Per the [Uniswap v4 Hooks Routing Allowlist](https://developers.uniswap.org/hook-allowlist) page:

> You only need to fill in this form if your hook deployment addresses start with 0x91 or your hook uses any of the following flags: `beforeSwapReturnsDelta`, `afterSwapReturnsDelta`, or `dynamicFees`. If your hook meets neither of these criteria, it is already automatically allowlisted and you do not need to fill in this form.

RingFallbackHook uses `beforeSwapReturnDelta` (permission mask `0x88`), so it must be submitted for review.

## Allowlisting Criteria

Uniswap Labs prioritizes swapper and LPer safety. Based on the [Uniswap v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security) and public allowlist requirements, the following criteria are relevant for RingFallbackHook:

### 1. No Fund Withdrawal Risk

The hook must not be able to withdraw user funds or LP liquidity. RingFallbackHook:

- Has no owner, no upgrade proxy, and no admin functions
- Cannot sweep tokens (no `sweep` function)
- Cannot modify fees
- Cannot block liquidity operations (no `beforeAddLiquidity` / `beforeRemoveLiquidity`)
- Holds zero token balances after every successful fallback swap (verified in tests)

### 2. No Reentrancy Risk

The hook must not allow reentrancy that could manipulate pool state. RingFallbackHook:

- Uses `ReentrancyGuard` on `beforeSwap`
- Does not call back into the same pool during fallback execution
- Uses a hookless fb pool (`IHooks(address(0))`), so there are no nested hook calls

### 3. No User-Controlled Route Input

The hook accepts no user-supplied routing instructions. `hookData` is ignored entirely — the routing decision is computed on chain by comparing cur and fb active liquidity (`getLiquidity`), and the fallback pool key is derived purely from the cur pool key and FewFactory state. No pool address, arbitrary call target, deadline, or amount limit is supplied by the user.

### 4. Delta Accounting Correctness

Since the hook uses `beforeSwapReturnDelta`, the returned delta must be correct. When the fb route is chosen, RingFallbackHook:

- Sets `specifiedDelta = -amountSpecified` to zero out the cur pool swap
- Sets `unspecifiedDelta` from the actual fb output (exact-input) or actual fb input (exact-output)
- Uses values from real fb execution, not estimates
- Enforces complete fill; a partial fill reverts (`FbSwapPartialFill`)
- Maps the caller's `sqrtPriceLimitX96` into the fb pool's price space (with inversion when token order differs), so the caller's price limit stays effective on the fb route

When fb is not chosen, the hook returns a zero delta and the cur pool executes normally.

### 5. Deterministic Routing and Explicit Failure Semantics

Routing is deterministic and fully on-chain: the hook routes to fb only when the fallback pool is available (wrappers registered and verified, fb pool initialized with liquidity, static fee, ERC-20 currencies) and strictly deeper than cur; otherwise the cur pool executes with the caller's original parameters. There is no silent route substitution at execution time and no partial-fill mode: an fb-routed swap reverts if the fb swap cannot fill completely, PoolManager inventory is insufficient, or wrap/unwrap/balance/settlement checks fail.

Because `hookData` is ignored, callers protect themselves with the same v4-native mechanisms used for direct swaps: `sqrtPriceLimitX96` (honored on both routes) plus router-level deadline and minimum-output/maximum-input checks.

### 6. Source Code Verification

The deployed contract must have verified source code on the block explorer, matching the deployed bytecode. The GitHub repository link must also be provided.

## Application Form Fields

Below is a pre-filled template for the [allowlist submission form](https://developers.uniswap.org/hook-allowlist):

### Hook name

```
RingFallbackHook
```

### Hook description

```
RingFallbackHook is a Uniswap v4 hook that automatically routes swaps between the attached origin-token pool (cur) and the corresponding hookless FewToken fallback pool (fb). Routing is fully on-chain and deterministic: the hook compares the two pools' active liquidity via getLiquidity and executes on fb only when it is strictly deeper, using strict 1:1 flash wrap/swap/unwrap settlement inside the swap callback. The caller's sqrtPriceLimitX96 is mapped into the fb pool's price space so price-limit protection remains effective. hookData is ignored; there are no user-supplied routes, addresses, or limits. fb swaps must fill completely or the whole transaction reverts. The hook has no admin functions, upgradeability, or ability to withdraw user funds.
```

### Hook address

```
0x5803991b45EA694914FB4806b86b962563a50088
```

Deployed on Ethereum mainnet via CREATE2 (salt `0x0000000000000000000000000000000000000000000000000000000000001881`).
Permission mask: `0x88` (`BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`).
Deployment tx: `0xc797f371b0bc1e9b72560a112cd6fbe56f7767dc2cd16f8906518724365dd9d8` (block 25933038).
Source verified on Etherscan: https://etherscan.io/address/0x5803991b45EA694914FB4806b86b962563a50088

Constructor args (ABI-encoded):
```
0x000000000000000000000000000000000004444c5dc75cb358380d2e3de08a900000000000000000000000007d86394139bf1122e82fdf45bb4e3b038a4464dd
```
- `poolManager`: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- `fewFactory`: `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD`

### Pool ID / address

```
[Fill in after initializing a cur pool with the hook on Uniswap v4 frontend]
```

### Hook details

```
[x] My hook uses a delta flag and/or dynamic fee
```

(RingFallbackHook uses `beforeSwapReturnDelta`.)

### Chain(s)

```
Ethereum
```

(Add other chains as needed.)

### Link to source

```
https://github.com/ringprotocol/RingFallbackHook
```

(Replace with actual repository URL. Source must also be verified on Etherscan.)

### Website

```
[Fill in if available]
```

### Audit links

```
[Fill in after audit is completed]
```

## Pre-Submission Checklist

Before submitting the allowlist application, ensure the following are complete:

- [x] Hook deployed on target chain with correct permission flags (`0x88`)
- [x] Source code verified on block explorer (Etherscan / equivalent)
- [ ] At least one pool initialized with the hook and containing minimal liquidity
- [ ] Cur and fb route swaps tested on-chain in both directions
- [ ] Exact-input and exact-output fb swaps tested, including complete-fill enforcement
- [ ] `sqrtPriceLimitX96` mapping verified on the fb route (both token orderings)
- [ ] Unavailable, insufficient-inventory, and partial-fill requests confirmed to revert
- [ ] Hook balances confirmed zero after successful fallback swaps
- [ ] Cur-route router/user deadline and slippage safeguards verified
- [ ] Security review completed (see below)
- [ ] GitHub repository public with matching source code
- [ ] README and documentation up to date

## Security Review Recommendations

Based on the [Uniswap v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security), RingFallbackHook falls into the following risk profile:

### Risk Dimensions

| Dimension | Score | Notes |
|-----------|-------|-------|
| Hook complexity | Low | Only `beforeSwap` + `beforeSwapReturnDelta`, no other callbacks |
| Math complexity | Low | Liquidity-depth comparison and sqrt-price-limit mapping; actual-result delta checks only |
| External dependencies | Medium | Depends on PoolManager, FewFactory, and FewWrappedToken |
| Token handling | Medium | Wrap/unwrap with balance checks; flash-take from PoolManager |
| Upgradeability | None | No proxy, no owner, immutable constructor arguments |
| Governance | None | No governance, admin, or pausable functions |
| Liquidity behavior | Low | Does not modify or block liquidity operations |
| Reentrancy surface | Low | `ReentrancyGuard` + hookless fb pool |
| Oracle dependency | None | No on-chain external oracle; routing uses pool liquidity directly |

### Recommended Security Actions

1. **External audit**: obtain at least one independent security audit before mainnet deployment.
2. **FewFactory integration review**: verify the FewFactory and FewWrappedToken contracts are audited and trusted.
3. **Price-limit mapping review**: verify `sqrtPriceLimitX96` inversion and clamping for both token orderings of the fb pool.
4. **Edge case testing**: test with fee-on-transfer tokens, rebasing tokens, and tokens with transfer hooks.
5. **Fork testing**: run the fork test suite against mainnet state to verify real pool interactions.
6. **Monitoring**: monitor `FallbackSwap`, fb-route reverts, PoolManager inventory, and fb liquidity.

## Submission Process

1. Complete the pre-submission checklist above.
2. Fill out the form at [https://developers.uniswap.org/hook-allowlist](https://developers.uniswap.org/hook-allowlist).
3. Wait for Uniswap Labs review (timing depends on hook complexity and submission volume).
4. If approved, pools with the hook will be eligible for routing in the Uniswap Labs interface.

> **Note**: Allowlisting is for routing compatibility only. It is not a security audit or endorsement by Uniswap Labs. The team retains sole discretion to reject or later remove a hook submission.

## UniswapX Alternative

If the hook is not allowlisted for classic routing, it can still be supported via UniswapX. From the [Uniswap Labs documentation](https://support.uniswap.org/hc/en-us/articles/33829289869965):

> UniswapX is able to support any pools including those that use `beforeSwap`, `afterSwap` and custom fee tiers. Developers of these hooks can run their own fillers to participate in Uniswap Labs interface routing.

To support RingFallbackHook via UniswapX, a filler would quote the swap through the hook's pools (the hook routes between cur and fb on chain) and execute swaps with appropriate price-limit protection. This is an alternative path if the classic routing allowlist is not obtained.
