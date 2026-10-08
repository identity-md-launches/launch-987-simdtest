#!/usr/bin/env python3
"""Compute launch provenance from integer minor units; no dependencies or network."""

import argparse
import json
from math import isqrt
from pathlib import Path


def sqrt_price(token_address: str, paired: str, cap: int, supply: int) -> int:
    for address in (token_address, paired):
        if len(address) != 42 or not address.startswith("0x"):
            raise ValueError("expected a 20-byte hex address")
        if not 0 < int(address, 16) < 2**160:
            raise ValueError("expected a nonzero address")
    if token_address.lower() == paired.lower():
        raise ValueError("currencies must differ")
    if cap <= 0 or supply <= 0:
        raise ValueError("cap and supply must be positive")
    numerator, denominator = (cap, supply) if int(token_address, 16) < int(paired, 16) else (supply, cap)
    return isqrt((numerator << 192) // denominator)


def validate(manifest: dict) -> None:
    """Validate this assignment's exact manifest fields without a schema dependency."""
    assert set(manifest) == {"kind", "token", "contracts", "pool", "economics", "notes"}
    assert manifest["kind"] == "custom_token"
    assert manifest["token"] == {
        "contract": "SIMDTESTToken", "name": "SIMDTEST", "symbol": "SIMDTEST",
        "decimals": 18, "constructorArgs": ["$factory", "$poolManager", "$launchNumber"],
        "totalSupply": str(10**27),
    }
    assert manifest["contracts"] == []
    assert manifest["economics"] == {
        "poolBps": 9000, "initialMarketCapWei": "2500000000000000000000",
        "remainderTo": "0x000000000000000000000000000000000000dead",
    }
    pool = manifest["pool"]
    assert set(pool) == {"pairedCurrency", "fee", "tickSpacing", "initialPrice"}
    assert pool["pairedCurrency"] == "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"
    assert pool["fee"] == 3000 and pool["tickSpacing"] == 60
    assert pool["initialPrice"] == str(isqrt((2500 * 10**18 << 192) // 10**27))
    assert isinstance(manifest["notes"], str) and manifest["notes"].strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("token_address", nargs="?", help="actual or factory-predicted token address")
    parser.add_argument("--check", action="store_true", help="validate the delivered manifest")
    args = parser.parse_args()
    manifest = json.loads((Path(__file__).resolve().parents[1] / "launch.json").read_text())
    if args.check:
        validate(manifest)
        print("Launch manifest matches the assignment; notes is a string and no chainId key is present.")
    if args.token_address:
        print(sqrt_price(args.token_address, manifest["pool"]["pairedCurrency"],
                         int(manifest["economics"]["initialMarketCapWei"]),
                         int(manifest["token"]["totalSupply"])))
    elif not args.check:
        parser.error("provide the actual token address or --check")


if __name__ == "__main__":
    main()
