# Vendored test dependencies

The production `SIMDTESTToken` is self-contained. These ordinary source files are
used only to test settlement against Uniswap's actual PoolManager implementation.
No package download, submodule initialization, or network is needed for default checks.

- [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75),
  commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`: unchanged import closure of
  `PoolManager.sol`, `StateLibrary.sol`, and `TransientStateLibrary.sol`.
  Upstream licenses are in `v4-core/licenses/`; individual files carry SPDX identifiers.
- [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647),
  commit `4b47a19038b798b4a33d9749d25e570443520647`: unchanged `src/auth/Owned.sol`
  (the v4 dependency) and upstream `LICENSE`.

The PoolManager's protocol-fee owner is part of the external Uniswap system and
test dependency; it grants no authority over SIMDTEST. Neither dependency is
included in the token's creation or runtime bytecode or deployed by this manifest.
