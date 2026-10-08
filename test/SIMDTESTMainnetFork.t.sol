// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {UniswapV4TestBase, UniswapV4Token0Test, UniswapV4Token1Test} from "./UniswapV4.t.sol";

interface MainnetForkVm {
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function skip(bool shouldSkip) external;
}

/// @notice Opt-in deployed PoolManager checks. The existing fixture replaces IMD with a local ERC-20.
/// This checks mainnet v4 settlement, not production IMD transfer policies or the launch factory.
contract SIMDTESTMainnetForkTest is TestBase {
    MainnetForkVm private constant forkVm =
        MainnetForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function test_MainnetToken0SeedBuySell() public {
        _fork();
        _roundTrip(new UniswapV4Token0Test());
    }

    function test_MainnetToken1SeedBuySell() public {
        _fork();
        _roundTrip(new UniswapV4Token1Test());
    }

    function test_MainnetToken0UnderpaymentRollsBack() public {
        _fork();
        _underpayment(new UniswapV4Token0Test());
    }

    function test_MainnetToken1UnderpaymentRollsBack() public {
        _fork();
        _underpayment(new UniswapV4Token1Test());
    }

    function _fork() private {
        string memory url = forkVm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) forkVm.skip(true);
        // Override only when the endpoint cannot serve this previously used deployment block.
        uint256 forkBlock = forkVm.envOr("SIMDTEST_FORK_BLOCK", uint256(26_145_306));
        forkVm.createSelectFork(url, forkBlock);
        require(block.chainid == 1, "expected Ethereum mainnet");
        require(MANAGER.code.length > 0, "mainnet PoolManager missing at fork block");
    }

    function _roundTrip(UniswapV4TestBase scenario) private {
        bytes32 codeHash = MANAGER.codehash;
        scenario.setUp();
        scenario.test_SingleSidedSeedAndSwapsSettleWithoutShortfall();
        require(MANAGER.codehash == codeHash, "deployed manager code was replaced");
    }

    function _underpayment(UniswapV4TestBase scenario) private {
        bytes32 codeHash = MANAGER.codehash;
        scenario.setUp();
        scenario.test_UnderpaidSellRevertsCurrencyNotSettledAndRollsBack();
        require(MANAGER.codehash == codeHash, "deployed manager code was replaced");
    }
}
