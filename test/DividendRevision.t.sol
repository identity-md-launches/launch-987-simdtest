// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract DistributorStub {
    function release(SIMDTESTToken token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract DividendRevisionTest is TestBase {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant HOLDER = address(0x401D);
    SIMDTESTToken token;
    DistributorStub distributor;

    function distributorOf(uint64 number) external view returns (address) {
        require(number == 1, "wrong launch number");
        return address(distributor);
    }

    function setUp() public {
        distributor = new DistributorStub();
        token = new SIMDTESTToken(address(this), MANAGER, 1);
    }

    function test_DistributorHasNoUnclaimableCredit() public {
        token.transfer(address(distributor), 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 1_000_000 ether);
        assertEq(token.withdrawableDividendOf(address(distributor)), 0);
    }

    function test_FeesAreNotStrandedAfterAllHoldersClaim() public {
        token.transfer(address(distributor), 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 1_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(BOB, 2_000_000 ether);
        distributor.release(token, HOLDER, 100_000_000 ether);
        vm.prank(ALICE);
        token.claim();
        vm.prank(BOB);
        token.claim();
        vm.prank(HOLDER);
        token.claim();
        uint256 stranded = token.balanceOf(address(token)) - token.queuedDividends();
        assertLe(stranded, 2);
    }

    function test_WhaleCannotReclaimItsOwnBuyFee() public {
        token.transfer(HOLDER, 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 400_000_000 ether);
        assertEq(token.withdrawableDividendOf(ALICE), 0);
        assertApprox(token.withdrawableDividendOf(HOLDER), 12_000_000 ether, 1);
    }

    function test_FirstBuyerFeeStaysQueued() public {
        token.transfer(token.BURN_ADDRESS(), 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 1_000_000 ether);
        assertEq(token.withdrawableDividendOf(ALICE), 0);
        assertEq(token.queuedDividends(), 30_000 ether);
    }

    function test_FactoryRemainderDoesNotEarnDividends() public {
        token.transfer(HOLDER, 100 ether);
        token.transfer(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 100 ether);
        assertEq(token.withdrawableDividendOf(address(this)), 0);
        assertApprox(token.withdrawableDividendOf(HOLDER), 3 ether, 1);
        assertEq(token.eligibleSupply(), 197 ether);
    }

    function test_RegistrationAfterDeploymentAndBindingCannotChange() public {
        DistributorStub registered = distributor;
        delete distributor;
        assertTrue(token.dividendDistributor() == address(0));
        assertEq(token.eligibleSupply(), 0);
        distributor = registered;
        token.transfer(address(distributor), 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        distributor = new DistributorStub(); // A later factory change must have no token effect.
        assertTrue(token.dividendDistributor() == address(registered));
        assertTrue(token.isDividendExcluded(address(registered)));
        assertTrue(!token.isDividendExcluded(address(distributor)));
        vm.prank(MANAGER);
        token.transfer(ALICE, 1_000_000 ether);
        assertEq(token.withdrawableDividendOf(address(registered)), 0);
        assertEq(token.queuedDividends(), 30_000 ether);
        registered.release(token, HOLDER, 100_000_000 ether);
        assertEq(token.balanceOf(HOLDER), 100_000_000 ether);
        assertEq(token.withdrawableDividendOf(HOLDER), 0);
        vm.prank(MANAGER);
        token.transfer(BOB, 1_000_000 ether);
        uint256 expected = uint256(60_000 ether) * 100_000_000 / 100_970_000;
        assertApprox(token.withdrawableDividendOf(HOLDER), expected, 1);
    }

    function test_OverlappingExclusionsNeverDoubleSubtract() public {
        address[5] memory overlap = [address(0), MANAGER, address(token), token.BURN_ADDRESS(), address(this)];
        for (uint256 i; i < overlap.length; ++i) {
            distributor = DistributorStub(overlap[i]);
            assertEq(token.eligibleSupply(), 0);
        }
    }

    function test_ExistingBuyerEarnsOnlyOnPreviouslyHeldTokens() public {
        token.transfer(HOLDER, 600 ether);
        token.transfer(ALICE, 300 ether);
        token.transfer(MANAGER, token.balanceOf(address(this)));
        vm.prank(MANAGER);
        token.transfer(ALICE, 100 ether);
        assertApprox(token.withdrawableDividendOf(HOLDER), 2 ether, 1);
        assertApprox(token.withdrawableDividendOf(ALICE), 1 ether, 1);
        assertEq(token.balanceOf(ALICE), 397 ether);
    }

    function test_RouterSweepReceivesNoRetroactiveDividend() public {
        DistributorStub router = new DistributorStub();
        token.transfer(HOLDER, 100_000_000 ether);
        token.transfer(MANAGER, 900_000_000 ether);
        vm.prank(MANAGER);
        token.transfer(address(router), 1_000_000 ether);
        router.release(token, ALICE, 970_000 ether);
        assertEq(token.withdrawableDividendOf(address(router)), 0);
        assertEq(token.withdrawableDividendOf(ALICE), 0);
        assertApprox(token.withdrawableDividendOf(HOLDER), 30_000 ether, 1);
        vm.prank(HOLDER);
        token.claim();
        assertLe(token.balanceOf(address(token)), 1);
    }

    function test_ConstructorRejectsMismatchedLaunchInfrastructure() public {
        vm.expectRevert(SIMDTESTToken.InvalidFactory.selector);
        new SIMDTESTToken(ALICE, MANAGER, 1);
        vm.expectRevert(SIMDTESTToken.InvalidFactory.selector);
        vm.prank(ALICE);
        new SIMDTESTToken(ALICE, MANAGER, 1);
        vm.expectRevert(SIMDTESTToken.InvalidPoolManager.selector);
        new SIMDTESTToken(address(this), ALICE, 1);
    }
}
