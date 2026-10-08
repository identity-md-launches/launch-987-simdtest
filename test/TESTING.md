# Additional SIMDTEST coverage

Run `forge build` and `forge test` from the repository root. No additional libraries,
configuration changes, submodules, or downloads are needed for these tests.

- `SIMDTESTAdversarial.t.sol` adds three 1,000-run fuzz properties for proportional
  dividend payouts, split-transfer rounding, and atomic rollback of rejected buys.
  It also covers maximum input values, revoked approvals, the PoolManager acting
  as a spender, one-wei eligible supply, and mint/fee/claim event accounting.
- `SIMDTESTInvariant.t.sol` uses Foundry's handler targeting interface directly.
  Inline configuration selects 256 histories of 80 calls and fails on unexpected
  reverts. Buys, sells, wallet transfers, swarm releases, factory forwarding,
  claims, and rejected overspends execute in random order with zero, dust, full
  balance, and random amounts. A separate ledger checks every balance and the
  exact fee/donation/payout conservation equation. Other checks cover outstanding
  claims, queued fees, excluded balances, allowance consumption, and preservation
  of past credit. After each history, all holders attempt to claim their debts.
- `SIMDTESTMainnetFork.t.sol` adds explicit optional mainnet checks in both currency
  orderings, reusing the existing v4 fixture. With no `MAINNET_RPC_URL`, its four
  tests are reported as skipped; the existing real local PoolManager integration
  tests still run offline. With a URL, a missing mainnet manager or a broken RPC
  fails the fork tests instead of falling back to the local deployment.

For an RPC that serves historical state:

```sh
MAINNET_RPC_URL=https://your-mainnet-rpc.example \
  forge test --match-path test/SIMDTESTMainnetFork.t.sol
```

The default fork block is 26145306, the block recorded by the existing integration
suite. Set `SIMDTEST_FORK_BLOCK` in the command environment to use another block.
No test writes shared environment variables or requires a key.

The fork fixture preserves the deployed PoolManager, but replaces IMD at the
specified paired-currency address with an ERC-20 fixture for funding. Production
IMD transfer behavior and the complete launch factory are outside this fixture's
coverage. Live mainnet execution remains unverified in this task: the three public
RPC endpoints attempted returned HTTP 403. The pinned protected admission suite
is a separate external harness and is not represented as having run locally.
