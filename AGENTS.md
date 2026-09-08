# AGENTS.md

## Language

Use English for all source code, comments, documentation, tests, commit messages, pull request descriptions, and agent responses related to this repository.

## Project Overview

RingFallbackHook is a Foundry-based Solidity project implementing a Uniswap v4 `beforeSwap` hook that can route swaps through a hookless FewToken fallback pool.

## Development Guidelines

- Preserve the hook permission mask: `BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG` (`0x88`).
- Treat `PoolManager`, `FewFactory`, and FewToken wrappers as explicit trust boundaries.
- Keep wrap and unwrap operations strictly 1:1 and preserve exact balance checks.
- Do not add owner, upgrade, pause, fee, route setter, or sweep capabilities unless explicitly requested.
- Do not support native currency or dynamic-fee fallback routes without corresponding design review and tests.
- Follow the existing Solidity style and run `forge fmt` after Solidity changes.
- Do not edit vendored code under `lib/` unless explicitly requested.

## Verification

Run the following before considering a change complete:

```bash
forge fmt --check
forge test -vv
```

Fork tests require `ETH_RPC_URL` and use the pinned block configured in the test suite:

```bash
forge test --fork-block-number 25833244 -vv
```

When changing routing, settlement, or delta accounting, add tests for both swap directions and both exact-input and exact-output behavior. Verify that the hook retains no origin-token or FewToken balances after a successful fallback swap.

## Security Expectations

- The hook always compares cur and fb marginal spot prices and routes to the better pool. `hookData` only controls slippage protection strength (cur-marginal safety check vs caller-supplied limit), not the routing decision.
- Preserve user-controlled slippage or price-limit protections.
- Require complete fills for fallback swaps, or revert the entire transaction.
- Validate all external-call assumptions and avoid leaving token allowances or balances on the hook.
- Document unresolved assumptions and test gaps in `docs/AI-Audit-Report.md`.
