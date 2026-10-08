// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract SIMDTESTTokenTest is TestBase {
    SIMDTESTToken internal token;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function distributorOf(uint64) external pure returns (address) {
        return DISTRIBUTOR;
    }

    function setUp() public {
        token = new SIMDTESTToken(address(this), MANAGER, 1);
    }

    function test_ConstructorMintsEverythingOnlyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.decimals(), 18);
        assertTrue(keccak256(bytes(token.name())) == keccak256("SIMDTEST"));
        assertTrue(keccak256(bytes(token.symbol())) == keccak256("SIMDTEST"));
    }

    function test_FactoryAndSwarmFlowsAreExact() public {
        token.transfer(DISTRIBUTOR, SUPPLY / 10);
        token.transfer(MANAGER, SUPPLY * 9 / 10);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(MANAGER), 900_000_000 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100_000_000 ether);
        assertEq(token.balanceOf(ALICE), 100_000_000 ether);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_BuyTaxesThreePercentAndAccruesProRataBeforePurchase() public {
        token.transfer(ALICE, 600 ether);
        token.transfer(BOB, 300 ether);
        token.transfer(MANAGER, SUPPLY - 900 ether);
        _buy(CAROL, 100 ether);
        assertEq(token.balanceOf(CAROL), 97 ether);
        assertEq(token.balanceOf(address(token)), 3 ether);
        assertEq(token.balanceOf(MANAGER), SUPPLY - 1000 ether);
        assertEq(token.eligibleSupply(), 997 ether);
        assertEq(token.totalFeesCollected(), 3 ether);
        assertApprox(token.withdrawableDividendOf(ALICE), 2 ether, 1);
        assertApprox(token.withdrawableDividendOf(BOB), 1 ether, 1);
        assertEq(token.withdrawableDividendOf(CAROL), 0);
    }

    function test_SellsAndWalletTransfersAreUntaxed() public {
        token.transfer(ALICE, 1000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 300 ether);
        vm.prank(BOB);
        token.transfer(MANAGER, 100 ether);
        assertEq(token.balanceOf(ALICE), 700 ether);
        assertEq(token.balanceOf(BOB), 200 ether);
        assertEq(token.balanceOf(MANAGER), 100 ether);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_ClaimPaysOnceAndDoesNotMint() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        _buy(BOB, 1000 ether);
        uint256 owed = token.withdrawableDividendOf(ALICE);
        assertApprox(owed, 30 ether, 1);
        vm.prank(ALICE);
        assertEq(token.claim(), owed);
        assertEq(token.balanceOf(ALICE), 1000 ether + owed);
        assertEq(token.balanceOf(address(token)), 30 ether - owed);
        assertEq(token.withdrawnDividends(ALICE), owed);
        assertEq(token.totalDividendsClaimed(), owed);
        vm.prank(ALICE);
        assertEq(token.claim(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferCannotMoveOrDuplicateEarnedDividends() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        _buy(CAROL, 1000 ether);
        uint256 earned = token.withdrawableDividendOf(ALICE);
        uint256 held = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, held);
        assertEq(token.withdrawableDividendOf(ALICE), earned);
        assertEq(token.withdrawableDividendOf(BOB), 0);
        _buy(CAROL, 1000 ether);
        assertEq(token.withdrawableDividendOf(ALICE), earned);
        assertApprox(token.withdrawableDividendOf(BOB), uint256(30 ether) * 1000 / 1970, 1);
        assertApprox(token.withdrawableDividendOf(CAROL), uint256(30 ether) * 970 / 1970, 1);
        vm.prank(ALICE);
        assertEq(token.claim(), earned);
    }

    function test_SellerKeepsPastDividendsAndStopsEarningOnSoldTokens() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        _buy(BOB, 1000 ether);
        uint256 earned = token.withdrawableDividendOf(ALICE);
        uint256 held = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.transfer(MANAGER, held);
        _buy(BOB, 1000 ether);
        assertEq(token.withdrawableDividendOf(ALICE), earned);
        assertApprox(token.withdrawableDividendOf(BOB), 30 ether, 1);
    }

    function test_ClaimedTokensOnlyEarnFutureDividends() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        _buy(BOB, 1000 ether);
        vm.prank(ALICE);
        token.claim();
        uint256 aliceBalance = token.balanceOf(ALICE);
        _buy(CAROL, 1000 ether);
        uint256 expected = 30 ether * aliceBalance / (aliceBalance + 970 ether);
        assertApprox(token.withdrawableDividendOf(ALICE), expected, 1);
        assertApprox(token.withdrawableDividendOf(BOB), 30 ether * 970 ether / (aliceBalance + 970 ether), 1);
        assertEq(token.withdrawableDividendOf(CAROL), 0);
    }

    function test_ExcludedBalancesAndDonationsDoNotEarn() public {
        token.transfer(token.BURN_ADDRESS(), 100 ether);
        token.transfer(address(token), 100 ether);
        token.transfer(MANAGER, SUPPLY - 200 ether);
        _buy(ALICE, 1000 ether);
        assertEq(token.eligibleSupply(), 970 ether);
        assertEq(token.balanceOf(address(token)), 130 ether);
        assertEq(token.withdrawableDividendOf(ALICE), 0);
        assertEq(token.queuedDividends(), 30 ether);
        _buy(BOB, 1000 ether);
        assertApprox(token.withdrawableDividendOf(ALICE), 60 ether, 1);
        address[6] memory excluded =
            [MANAGER, address(token), token.BURN_ADDRESS(), address(0), address(this), DISTRIBUTOR];
        for (uint256 i; i < excluded.length; ++i) {
            assertEq(token.withdrawableDividendOf(excluded[i]), 0);
            vm.prank(excluded[i]);
            assertEq(token.claim(), 0);
        }
    }

    function test_ZeroEligibleSupplyQueuesFeesUntilNextTaxedBuy() public {
        token.transfer(MANAGER, SUPPLY);
        _buy(token.BURN_ADDRESS(), 1000 ether);
        assertEq(token.eligibleSupply(), 0);
        assertEq(token.queuedDividends(), 30 ether);
        _buy(ALICE, 1000 ether);
        assertEq(token.queuedDividends(), 60 ether);
        assertEq(token.withdrawableDividendOf(ALICE), 0);
        vm.prank(ALICE);
        assertEq(token.claim(), 0);
        _buy(BOB, 1000 ether);
        assertEq(token.queuedDividends(), 0);
        assertApprox(token.withdrawableDividendOf(ALICE), 90 ether, 1);
        assertEq(token.withdrawableDividendOf(BOB), 0);
        assertEq(token.balanceOf(address(token)), 90 ether);
    }

    function test_ZeroAndSelfTransfersDoNotChangeEntitlements() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        _buy(BOB, 1000 ether);
        uint256 earned = token.withdrawableDividendOf(ALICE);
        vm.startPrank(ALICE);
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 0);
        vm.stopPrank();
        vm.prank(MANAGER);
        token.transfer(MANAGER, 100 ether);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.withdrawableDividendOf(ALICE), earned);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    function test_DustFeeRoundsDown() public {
        token.transfer(MANAGER, 67);
        _buy(ALICE, 33);
        assertEq(token.balanceOf(ALICE), 33);
        assertEq(token.totalFeesCollected(), 0);
        _buy(BOB, 34);
        assertEq(token.balanceOf(BOB), 33);
        assertEq(token.totalFeesCollected(), 1);
    }

    function test_TransferFromConsumesGrossAllowanceAndUsesFromForTax() public {
        token.transfer(MANAGER, 1000 ether);
        vm.prank(MANAGER);
        token.approve(BOB, 1000 ether);
        vm.prank(BOB);
        token.transferFrom(MANAGER, ALICE, 1000 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.allowance(MANAGER, BOB), 0);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, MANAGER, 970 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(MANAGER), 970 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    function test_InvalidTransfersAndApprovalsRevertAtomically() public {
        vm.expectRevert(SIMDTESTToken.InvalidReceiver.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(SIMDTESTToken.InvalidSpender.selector);
        token.approve(address(0), 1);
        vm.expectRevert(SIMDTESTToken.InsufficientBalance.selector);
        token.transfer(ALICE, SUPPLY + 1);
        vm.expectRevert(SIMDTESTToken.InsufficientAllowance.selector);
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1);
        vm.expectRevert(SIMDTESTToken.InvalidSender.selector);
        token.transferFrom(address(0), ALICE, 0);
        token.approve(BOB, SUPPLY + 1);
        vm.expectRevert(SIMDTESTToken.InsufficientBalance.selector);
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, SUPPLY + 1);
        assertEq(token.allowance(address(this), BOB), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalFeesCollected(), 0);
    }

    function test_NoAdminMintBurnOrBalanceSeizure() public {
        token.transfer(ALICE, 1000 ether);
        string[12] memory calls = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "setFee(uint256)",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "setMinter(address)",
            "seize(address)",
            "setDividendExcluded(address,bool)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(calls[i], ALICE, 1000 ether));
            assertTrue(!ok);
            vm.prank(BOB);
            (ok,) = address(token).call(abi.encodeWithSignature(calls[i], ALICE, 1000 ether));
            assertTrue(!ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 1000 ether);
        assertEq(token.balanceOf(BOB), 1000 ether);
    }

    function test_RuntimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzz_BuyAndClaimConserveSupply(uint256 input) public {
        uint256 amount = input % SUPPLY;
        token.transfer(MANAGER, SUPPLY);
        _buy(ALICE, amount);
        uint256 fee = amount * 3 / 100;
        assertEq(token.balanceOf(ALICE), amount - fee);
        assertEq(token.balanceOf(address(token)), fee);
        vm.prank(ALICE);
        uint256 claimed = token.claim();
        assertEq(claimed, 0);
        assertEq(token.queuedDividends(), fee);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(MANAGER) + token.balanceOf(address(token)), SUPPLY);
    }

    function testFuzz_CheckpointsPreserveFractions(uint96 input) public {
        token.transfer(MANAGER, SUPPLY);
        uint256 amount = uint256(input) % (SUPPLY / 4) + 34;
        _buy(ALICE, amount);
        uint256 firstIndex = token.magnifiedDividendPerShare();
        uint256 firstBalance = token.balanceOf(ALICE);
        for (uint256 i; i < 10; ++i) {
            vm.prank(ALICE);
            token.transfer(ALICE, 0);
            _buy(BOB, 101);
        }
        uint256 expected = firstBalance * token.magnifiedDividendPerShare() / token.MAGNITUDE();
        assertEq(firstIndex, 0);
        assertGt(token.magnifiedDividendPerShare(), 0);
        assertEq(token.withdrawableDividendOf(ALICE), expected);
    }

    function testFuzz_StatefulConservationAndDividendSolvency(uint256 seed) public {
        address[8] memory accounts =
            [address(this), ALICE, BOB, CAROL, MANAGER, address(token), token.BURN_ADDRESS(), DISTRIBUTOR];
        token.transfer(MANAGER, SUPPLY / 2);
        token.transfer(ALICE, SUPPLY / 10);
        for (uint256 i; i < 80; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address from = accounts[seed % accounts.length];
            // The token reserve has no transfer entrypoint for spending its own balance.
            if (from == address(token)) from = DISTRIBUTOR;
            address to = accounts[(seed >> 16) % accounts.length];
            if (seed % 4 == 0) {
                vm.prank(from);
                token.claim();
            } else {
                uint256 amount = (seed >> 32) % (token.balanceOf(from) + 1);
                vm.prank(from);
                token.transfer(to, amount);
            }
            uint256 sum;
            uint256 owed;
            for (uint256 j; j < accounts.length; ++j) {
                sum += token.balanceOf(accounts[j]);
                owed += token.withdrawableDividendOf(accounts[j]);
            }
            assertEq(sum, SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
            assertLe(owed + token.queuedDividends(), token.balanceOf(address(token)));
            assertLe(token.totalDividendsClaimed(), token.totalFeesCollected());
            assertLe(
                token.totalFeesCollected() - token.totalDividendsClaimed(), token.balanceOf(address(token))
            );
            assertEq(
                token.eligibleSupply(),
                SUPPLY - token.balanceOf(MANAGER) - token.balanceOf(address(token))
                    - token.balanceOf(token.BURN_ADDRESS()) - token.balanceOf(address(this))
                    - token.balanceOf(DISTRIBUTOR)
            );
        }
    }

    function _buy(address to, uint256 amount) private {
        vm.prank(MANAGER);
        token.transfer(to, amount);
    }
}
