# SIMDTEST

`src/SIMDTESTToken.sol` is the only launch contract. It has no owner, admin functions,
upgrades, or mint/burn functions. Its constructor takes the launch factory address,
the PoolManager address and the launch number (`uint64`). Its
constructor credits exactly **1,000,000,000 × 10¹⁸** units to `msg.sender` and emits
the initial ERC-20 `Transfer`. The calling launch factory receives the entire supply.

## Launch parameters

| Parameter | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| Name / symbol / decimals | SIMDTEST / SIMDTEST / 18 |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Paired IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Supply in minor units | `1000000000000000000000000000` |
| Swarm allocation | 10%, 100,000,000 tokens, external distributor |
| Pool allocation | `poolBps: 9000`, 900,000,000 tokens |
| Opening market cap | `initialMarketCapWei: "2500000000000000000000"`, 2500 IMD |
| Remainder recipient | `0x000000000000000000000000000000000000dead` |
| Pool fee / tick spacing | `3000` / `60` |
| Token buy tax | 300 basis points, 3% |

The **mandatory build requirements** resolve the brief's contradictory pool fee:
`launch.json` uses `3000` (0.30%). The earlier 1.25% would be `12500` in Uniswap's
millionths units, or 125 basis points, and is not used. The separate 3% token tax
uses conventional basis points. No fee can be changed in the token.

The constructor does not distribute the swarm portion, seed a pool, or mint a
second allocation. The launch factory forwards the already minted 10% to its
Merkle distributor, spends up to 90% on single-sided liquidity, and forwards any
integer-rounding remainder to the specified burn address. Contributor/seat shares,
Merkle roots and claims belong to that external distribution process. The token's
allocation constants describe the launch economics; the factory executes them.
Sending tokens to the burn address locks that balance without reducing total supply.

`launch.json` has the required string `notes` and no root `chainId` field.
`contracts` is empty; `token.constructorArgs` is
`["$factory", "$poolManager", "$launchNumber"]`. These are factory-resolved launch
identifiers, not guessed deployment values. The constructor requires the factory
to be its caller with deployed code, distinct from PoolManager and the burn address,
and requires the PoolManager argument to equal the fixed mainnet constant.
No application, distributor, router,
PoolManager, hook or fee splitter is deployed by this manifest.

## Opening price provenance

Use minor units throughout: supply `S = 10^27`, paired cap `C = 2500 × 10^18`.
The paired IMD contract returned `symbol() = IMD` and `decimals() = 18` during the
read-only mainnet checks. Currency0 is the lower numerical address.

| Sorted order | Calculation | Decimal sqrtPriceX96 |
| --- | --- | --- |
| SIMDTEST < IMD | `floor(sqrt(C / S) × 2^96)` | `125270724187523965593206900` |
| IMD < SIMDTEST | `floor(sqrt(S / C) × 2^96)` | `50108289675009586237282760313921` |

The manifest records the first orientation as provenance and states both values
in its notes. The factory address and CREATE2 launch salt are external launch
inputs, so no final SIMDTEST address is invented here. The launch factory derives
the authoritative opening price using the actual sorted deployment addresses.
`python3 tools/launch_price.py <actual-or-predicted-token-address>` returns the
proper value using integer square roots, with no network or floating-point math.
The factory also selects valid ticks and liquidity within the 90% budget.

## Transfers and dividends

The ERC-20 surface is `balanceOf`, `totalSupply`, `allowance`, `approve`, `transfer`
and `transferFrom`. Zero-value and self transfers work. Zero-address recipients
and spenders are rejected. Allowances apply to the gross transfer, with the usual
infinite-allowance behavior for `uint256.max`; balance failures revert allowance
changes atomically. Transfer and approval changes emit ERC-20 events.

Only `from == POOL_MANAGER && to != POOL_MANAGER` incurs the tax, independently
of who invokes `transferFrom`. The fee is `floor(amount × 300 / 10000)`; the sender
loses exactly the gross amount, the destination receives the net, and the token
contract retains the fee. Transfers into PoolManager, factory/distributor flows,
wallet transfers and dividend payouts are fee-free.

Dividends use a cumulative index scaled by `2^128`. Every balance change first
records the account's earned credit. Each buy distributes its fee in proportion
to eligible balances **before the buyer receives the net amount**. A buyer earns
only on tokens it already held; newly purchased tokens cannot rebate their own fee.
The PoolManager, this token, the burn address, the launch factory and the swarm's
Merkle distributor are excluded; zero-address transfers are impossible.

The factory and launch number are immutable. Because the distributor's address
depends on the token's address, the token reads `factory.distributorOf(launchNumber)`
after deployment. The first nonzero result observed during a transfer is stored
permanently. Later registry changes cannot change dividend eligibility. The factory
must register the correct distributor before forwarding the swarm allocation or
seeding the pool. Before this binding, the registry must support that read; after
binding, token operations make no external calls. A zero registry result represents
an unregistered launch, not an address configured in the manifest. Exclusions are
deduplicated when calculating eligible supply.

`withdrawableDividendOf(holder)` gives claimable whole minor units. `claim()` pays
only its caller and returns the amount, or zero if nothing is claimable. Selling
or transferring away all tokens preserves earlier credit. Receiving tokens gives
no retroactive entitlement. Claimed tokens earn future distributions only.
Fractional account credit survives transfers and repeated claims. Global index
rounding dust remains in the contract; there is no sweep function. Each distribution
rounds down by less than `eligibleSupply / 2^128` minor units in aggregate, while
individual claims round down to whole minor units.

If no eligible balances exist before a buy, fees queue until a subsequent
fee-bearing buy with eligible prior holders. For example, with all supply at the
distributor and PoolManager, the first buyer cannot immediately reclaim its fee;
that fee remains queued. A second buy distributes both fees to prior holders.
Wallet transfers, `claim()` and zero-fee dust buys do not flush this queue. Swarm
recipients earn only after receiving their allocation, without inheriting past
distributor credit. Direct donations to the token are excluded balances and are not added to
dividends; they cannot be rescued. Transfers from PoolManager to the token itself
place both the net amount and fee in its balance, but only the fee enters the index.

## Integration responsibilities and limits

The address-based buy definition also taxes liquidity withdrawals and any other
outgoing PoolManager transfer, including withdrawals of an LP's own principal or
the factory's seeded position. It cannot distinguish swaps from withdrawals or
identify a pool within the singleton. A trader can buy into ERC-6909 claims using
`PoolManager.mint()` and sell them using `burn()` without an ERC-20 transfer or token
tax. Redeeming those claims through `take()` does trigger the tax. These limitations
follow the requested transfer rule without hooks or dynamic fees; the 3% is not a
fee on every economic trade within v4. Integration tests cover both cases.

Routers must account for net received tokens. An exact-output swap requests gross
PoolManager output, and the recipient receives 97% subject to integer rounding.
Slippage checks should inspect the recipient's balance change. Successful core
settlement does not guarantee compatibility with every router, aggregator or
multi-hop route. The integration tests explicitly validate the `sync → transfer →
settle` and `take` paths from Uniswap's
[PoolManager implementation](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol).

Dividends follow spot balances; there is no minimum holding time, snapshot delay
or protection against borrowing tokens around fee-generating trades. Custodians
other than the excluded launch infrastructure earn on their own balances and must
support calling `claim()` to recover that entitlement; the token cannot attribute
it to their beneficiaries. Routers that receive and immediately sweep a buy's
output earn nothing on those new tokens from that buy. A router retaining tokens
across later buys is still an eligible custodian. Neither balances nor earned
dividends can be moved by an admin.

The launch operator must enforce mainnet deployment, perform factory distribution
and liquidity setup, and arrange the external 1% SIMD creator fee split: 0.5% to
SIMD holders and 0.5% to IMD seat agents. That external split does not reduce this
token's 3% dividend reserve. There are no after-launch token settings or privileged
keys. Deployment verification and independent adversarial review remain release
responsibilities. This project contains no broadcasting script or wallet access.

## Reproducible checks

Foundry pins Solidity 0.8.26, Cancun, optimizer enabled at 200 runs, and
`bytecode_hash = "none"`. FFI and filesystem permissions are not enabled. The
production token is dependency-free; the real v4 source and its import dependencies
are vendored as ordinary files with licenses and exact commits in
`lib/DEPENDENCIES.md`. A fresh verifier needs only Foundry and the pinned compiler.

```sh
forge build
forge test
forge fmt --check
python3 tools/launch_price.py --check
```

The default suite is entirely local, does not read or set environment variables,
and runs independently of network or test ordering. It covers fees, allocations,
ERC-20 failures, dividend timing and rounding, excluded/zero balances, absent
privileges, runtime opcode restrictions, and three fuzz properties (256 runs each),
including 80-action sequences that check supply conservation and dividend solvency
after every action. Both currency orderings seed a real local v4 PoolManager at
the mainnet address, buy and sell, check exact-output behavior, and prove an
underpaid settlement reverts atomically with `CurrencyNotSettled`. The revision
regressions cover unclaimable distributor credit, factory exclusions, pre-buy
dividend snapshots, queued first-buy fees, router sweeps, late distributor
registration, permanent binding, and invalid constructor arguments.

The same twelve integration tests also passed against the deployed mainnet
PoolManager at block **26145306** using:

```sh
forge test --match-path test/UniswapV4.t.sol \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26145306 --no-storage-caching
```

This optional command requires an RPC serving that block; the earlier revision's
block 26145068 was no longer available from that endpoint during this revision.
The fork preserves the
real PoolManager code and state. It replaces IMD with a test-only ERC-20 at the
specified address for deterministic funding, so it tests real v4 settlement but
not the production IMD token's transfer policies or the complete launch factory.
No fork or RPC is required by `forge test`. The pinned protected admission harness
is an external verifier input and is not represented as having been run locally.

The token's runtime is 3,805 bytes. The local review checked conservation, access
control, rounding, allowance rollback, and the registry's read-only interaction
before distributor binding. Slither and Mythril were not run; these checks are not an independent
security audit.
