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

### 3. Validated Route Input

The hook accepts only two input forms:

- Empty `hookData`, which always selects the cur pool
- A 64-byte `abi.encode(uint256 deadline, uint256 amountLimit)`, which explicitly requests the fb pool

For an fb request, the hook rejects expired deadlines and zero limits. `amountLimit` is the minimum output for exact-input and the maximum input for exact-output. No pool address or arbitrary call target is supplied by the user; the fallback key and wrappers remain derived from the cur pool key and FewFactory state.

### 4. Delta Accounting Correctness

Since the hook uses `beforeSwapReturnDelta`, the returned delta must be correct. For an explicit fb request, RingFallbackHook:

- Sets `specifiedDelta = -amountSpecified` to zero out the cur pool swap
- Sets `unspecifiedDelta` from the actual fb output (exact-input) or actual fb input (exact-output)
- Uses values from real fb execution, not estimates
- Enforces complete fill; a partial fill reverts (`FbSwapPartialFill`)
- Enforces the caller's limit against the actual result

Empty `hookData` returns a zero delta and lets the cur pool execute normally.

### 5. Explicit Failure Semantics

There is no automatic or graceful route substitution. Empty `hookData` uses cur. A non-empty request explicitly chooses fb and reverts if its encoding is invalid, its deadline or limit fails, the fallback route is unavailable, PoolManager inventory is insufficient, or execution checks fail. This preserves caller intent and prevents an explicit fallback quote from silently executing on a different route.

An external off-chain quoter or router is required to compare complete cur and fb quotes before selecting `hookData`. The hook does not compare marginal spot prices or promise best execution. For the cur path, standard router/user safeguards remain responsible for deadlines and minimum-output/maximum-input protection in addition to `sqrtPriceLimitX96`.

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
RingFallbackHook is a Uniswap v4 hook exposing two explicitly selected routes for origin-token pools. Empty hookData always executes through the attached current pool. A validated abi.encode(deadline, amountLimit) request selects the corresponding hookless FewToken fallback pool and performs strict 1:1 flash wrap/swap/unwrap settlement. The limit is checked against the actual fallback result. An external off-chain quoter must compare complete route quotes before selection; the hook performs no spot-price auto-routing. Explicit fallback requests revert rather than silently changing routes. The hook has no admin functions, upgradeability, or ability to withdraw user funds.
```

### Hook address

```
[Fill in after deployment]
```

### Pool ID / address

```
[Fill in after deploying a test pool with liquidity]
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

- [ ] Hook deployed on target chain with correct permission flags (`0x88`)
- [ ] Source code verified on block explorer (Etherscan / equivalent)
- [ ] At least one pool initialized with the hook and containing minimal liquidity
- [ ] Cur and fb route swaps tested on-chain in both directions
- [ ] Exact-input and exact-output fb limits tested against actual results
- [ ] Invalid, expired, unavailable, insufficient-inventory, and limit-failure requests confirmed to revert
- [ ] Hook balances confirmed zero after successful fallback swaps
- [ ] Off-chain quoter integration compares full route results and forwards `hookData` unchanged
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
| Math complexity | Low | No custom curves or on-chain route-comparison math; actual-result limit checks only |
| External dependencies | Medium | Depends on PoolManager, FewFactory, FewWrappedToken, and external quote quality |
| Token handling | Medium | Wrap/unwrap with balance checks; flash-take from PoolManager |
| Upgradeability | None | No proxy, no owner, immutable constructor arguments |
| Governance | None | No governance, admin, or pausable functions |
| Liquidity behavior | Low | Does not modify or block liquidity operations |
| Reentrancy surface | Low | `ReentrancyGuard` + hookless fb pool |
| Oracle dependency | None | No on-chain external oracle; routing requires off-chain quotes |

### Recommended Security Actions

1. **External audit**: obtain at least one independent security audit before mainnet deployment.
2. **FewFactory integration review**: verify the FewFactory and FewWrappedToken contracts are audited and trusted.
3. **Quoter review**: verify full-route comparison, deadline/limit derivation, and correct exact-input/exact-output encoding.
4. **Edge case testing**: test with fee-on-transfer tokens, rebasing tokens, and tokens with transfer hooks.
5. **Fork testing**: run the fork test suite against mainnet state to verify real pool interactions.
6. **Monitoring**: monitor `FallbackSwap`, fallback-request reverts, PoolManager inventory, and fb liquidity.

## Submission Process

1. Complete the pre-submission checklist above.
2. Fill out the form at [https://developers.uniswap.org/hook-allowlist](https://developers.uniswap.org/hook-allowlist).
3. Wait for Uniswap Labs review (timing depends on hook complexity and submission volume).
4. If approved, pools with the hook will be eligible for routing in the Uniswap Labs interface.

> **Note**: Allowlisting is for routing compatibility only. It is not a security audit or endorsement by Uniswap Labs. The team retains sole discretion to reject or later remove a hook submission.

## UniswapX Alternative

If the hook is not allowlisted for classic routing, it can still be supported via UniswapX. From the [Uniswap Labs documentation](https://support.uniswap.org/hc/en-us/articles/33829289869965):

> UniswapX is able to support any pools including those that use `beforeSwap`, `afterSwap` and custom fee tiers. Developers of these hooks can run their own fillers to participate in Uniswap Labs interface routing.

To support RingFallbackHook via UniswapX, a filler would need to quote both routes, encode the selected request correctly, and execute swaps through the hook's pools. This is an alternative path if the classic routing allowlist is not obtained.
