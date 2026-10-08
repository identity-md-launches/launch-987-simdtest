// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTToken} from "src/SIMDTESTToken.sol";
import {TestBase} from "./helpers/TestBase.sol";

interface DividendLogVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

contract SIMDTESTAdversarialTest is TestBase {
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant BUYER = address(0xB0A7);
    address private constant SPENDER = address(0x5EED);
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    DividendLogVm private constant logVm =
        DividendLogVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SIMDTESTToken private token;

    function distributorOf(uint64 number) external pure returns (address) {
        require(number == 1, "wrong launch");
        return address(0xD157);
    }

    function setUp() public {
        token = new SIMDTESTToken(address(this), MANAGER, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ProRataClaimsUsePreBuyBalances(
        uint256 weight,
        uint256 poolInput,
        uint256 buyInput,
        bool existingBuyer
    ) public {
        uint256 poolBalance = 34 + poolInput % (SUPPLY - 35);
        uint256 eligible = SUPPLY - poolBalance;
        uint256 aliceBalance = 1 + weight % (eligible - 1);
        uint256 bobBalance = eligible - aliceBalance;
        token.transfer(ALICE, aliceBalance);
        token.transfer(BOB, bobBalance);
        token.transfer(MANAGER, poolBalance);
        uint256 gross = 34 + buyInput % (poolBalance - 33);
        uint256 fee = gross * 3 / 100;
        address buyer = existingBuyer ? ALICE : BUYER;
        vm.prank(MANAGER);
        token.transfer(buyer, gross);

        assertEq(token.balanceOf(MANAGER), poolBalance - gross);
        assertEq(token.balanceOf(buyer), (existingBuyer ? aliceBalance : 0) + gross - fee);
        assertEq(token.balanceOf(address(token)), fee);
        // Independent rational proportion: the magnified index can lose at most one minor unit.
        _assertRoundedShare(ALICE, fee * aliceBalance / eligible);
        _assertRoundedShare(BOB, fee * bobBalance / eligible);
        assertEq(token.withdrawableDividendOf(BUYER), 0);

        uint256 aliceOwed = token.withdrawableDividendOf(ALICE);
        uint256 bobOwed = token.withdrawableDividendOf(BOB);
        vm.prank(ALICE);
        assertEq(token.claim(), aliceOwed);
        // Paying Alice cannot change Bob's already-earned share.
        assertEq(token.withdrawableDividendOf(BOB), bobOwed);
        vm.prank(BOB);
        assertEq(token.claim(), bobOwed);
        assertEq(token.totalDividendsClaimed(), aliceOwed + bobOwed);
        assertLe(token.balanceOf(address(token)), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SplitBuysLoseLessThanOneFeeUnitPerSplit(uint256 input, uint8 partsInput) public {
        uint256 parts = 2 + uint256(partsInput) % 31;
        uint256 gross = input % (SUPPLY / 2);
        token.transfer(ALICE, SUPPLY - gross);
        token.transfer(MANAGER, gross);
        uint256 remainder = gross;
        uint256 expectedFee;
        for (uint256 i; i < parts; ++i) {
            uint256 piece = i + 1 == parts ? remainder : gross / parts;
            remainder -= piece;
            expectedFee += piece * 3 / 100;
            vm.prank(MANAGER);
            token.transfer(BUYER, piece);
        }
        uint256 unsplitFee = gross * 3 / 100;
        assertLe(expectedFee, unsplitFee);
        assertLe(unsplitFee - expectedFee, parts - 1);
        assertEq(token.totalFeesCollected(), expectedFee);
        assertEq(token.balanceOf(BUYER), gross - expectedFee);
        assertEq(token.balanceOf(address(token)), expectedFee);
        assertEq(token.balanceOf(MANAGER), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedDelegatedBuyPreservesDividendsAndAllowance(uint256 input, uint8 failure) public {
        _activeDividendState();
        uint256 held = token.balanceOf(MANAGER);
        uint256 amount = input % (held + 1);
        address to = ALICE;
        uint256 approved = amount;
        bytes4 error;
        if (failure % 3 == 0) {
            to = address(0);
            error = SIMDTESTToken.InvalidReceiver.selector;
        } else if (failure % 3 == 1) {
            amount = held + 1;
            approved = type(uint256).max;
            error = SIMDTESTToken.InsufficientBalance.selector;
        } else {
            amount += 1;
            approved = amount - 1;
            error = SIMDTESTToken.InsufficientAllowance.selector;
        }
        vm.prank(MANAGER);
        token.approve(SPENDER, approved);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(error);
        vm.prank(SPENDER);
        token.transferFrom(MANAGER, to, amount);
        assertTrue(_stateDigest() == beforeState);
    }

    function test_MaximumTransferInputsFailWithoutArithmeticPanic() public {
        _activeDividendState();
        vm.prank(MANAGER);
        token.approve(SPENDER, type(uint256).max);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(SIMDTESTToken.InsufficientBalance.selector);
        vm.prank(MANAGER);
        token.transfer(ALICE, type(uint256).max);
        vm.expectRevert(SIMDTESTToken.InsufficientBalance.selector);
        vm.prank(SPENDER);
        token.transferFrom(MANAGER, ALICE, type(uint256).max);
        assertTrue(_stateDigest() == beforeState);
    }

    function test_RevokedApprovalCannotMoveBalanceOrAccruedCredit() public {
        _activeDividendState();
        vm.startPrank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        token.approve(SPENDER, 0);
        vm.stopPrank();
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(SIMDTESTToken.InsufficientAllowance.selector);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertTrue(_stateDigest() == beforeState);
        assertEq(token.allowance(ALICE, SPENDER), 0);
    }

    function test_ManagerAsSpenderDoesNotTaxWalletTokens() public {
        _activeDividendState();
        uint256 feeBefore = token.totalFeesCollected();
        uint256 owed = token.withdrawableDividendOf(ALICE);
        vm.prank(ALICE);
        token.approve(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.totalFeesCollected(), feeBefore);
        assertEq(token.withdrawableDividendOf(ALICE), owed);
        assertEq(token.withdrawableDividendOf(BOB), 0);
    }

    function test_OneWeiHolderCanClaimLargestPracticalDistribution() public {
        token.transfer(ALICE, 1);
        token.transfer(MANAGER, SUPPLY - 1);
        vm.prank(MANAGER);
        token.transfer(BUYER, SUPPLY - 1);
        uint256 fee = (SUPPLY - 1) * 3 / 100;
        assertEq(token.withdrawableDividendOf(ALICE), fee);
        vm.prank(ALICE);
        assertEq(token.claim(), fee);
        assertEq(token.balanceOf(address(token)), 0);
        // Huge historical per-share values cannot give the new whale retroactive credit.
        uint256 buyerBalance = token.balanceOf(BUYER);
        vm.prank(BUYER);
        token.transfer(BOB, buyerBalance);
        assertEq(token.withdrawableDividendOf(BOB), 0);
        assertEq(token.withdrawableDividendOf(BUYER), 0);
    }

    function test_ConstructorEmitsOnlyOneMintAndNeverSendsAllocations() public {
        logVm.recordLogs();
        SIMDTESTToken deployed = new SIMDTESTToken(address(this), MANAGER, 1);
        DividendLogVm.Log[] memory entries = logVm.getRecordedLogs();
        assertEq(entries.length, 1);
        _assertTransfer(entries[0], address(deployed), address(0), address(this), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), SUPPLY);
        assertEq(deployed.balanceOf(MANAGER), 0);
        assertEq(deployed.balanceOf(address(0xD157)), 0);
    }

    function test_BuyAndClaimEventsMatchActualReserveMovement() public {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        logVm.recordLogs();
        vm.prank(MANAGER);
        token.transfer(BUYER, 100 ether);
        DividendLogVm.Log[] memory entries = logVm.getRecordedLogs();
        assertEq(entries.length, 3);
        _assertTransfer(entries[0], address(token), MANAGER, address(token), 3 ether);
        assertTrue(entries[1].emitter == address(token));
        assertEq(entries[1].topics.length, 1);
        assertTrue(entries[1].topics[0] == keccak256("DividendsDistributed(uint256,uint256)"));
        assertTrue(keccak256(entries[1].data) == keccak256(abi.encode(3 ether, 1000 ether)));
        _assertTransfer(entries[2], address(token), MANAGER, BUYER, 97 ether);
        uint256 owed = token.withdrawableDividendOf(ALICE);
        logVm.recordLogs();
        vm.prank(ALICE);
        token.claim();
        entries = logVm.getRecordedLogs();
        assertEq(entries.length, 2);
        _assertTransfer(entries[0], address(token), address(token), ALICE, owed);
        assertTrue(entries[1].emitter == address(token));
        assertEq(entries[1].topics.length, 2);
        assertTrue(entries[1].topics[0] == keccak256("DividendClaimed(address,uint256)"));
        assertTrue(entries[1].topics[1] == bytes32(uint256(uint160(ALICE))));
        assertEq(abi.decode(entries[1].data, (uint256)), owed);
    }

    function _assertRoundedShare(address holder, uint256 ideal) private view {
        uint256 actual = token.withdrawableDividendOf(holder);
        assertLe(actual, ideal);
        assertLe(ideal - actual, 1);
    }

    function _activeDividendState() private {
        token.transfer(ALICE, 1000 ether);
        token.transfer(MANAGER, SUPPLY - 1000 ether);
        vm.prank(MANAGER);
        token.transfer(BUYER, 100 ether);
    }

    function _stateDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(BUYER),
                token.balanceOf(MANAGER),
                token.balanceOf(address(token)),
                token.totalSupply(),
                token.totalFeesCollected(),
                token.totalDividendsClaimed(),
                token.queuedDividends(),
                token.magnifiedDividendPerShare(),
                token.withdrawableDividendOf(ALICE),
                token.withdrawableDividendOf(BUYER),
                token.allowance(MANAGER, SPENDER)
            )
        );
    }

    function _assertTransfer(
        DividendLogVm.Log memory entry,
        address emitter,
        address from,
        address to,
        uint256 amount
    ) private pure {
        assertTrue(entry.emitter == emitter);
        assertEq(entry.topics.length, 3);
        assertTrue(entry.topics[0] == keccak256("Transfer(address,address,uint256)"));
        assertTrue(entry.topics[1] == bytes32(uint256(uint160(from))));
        assertTrue(entry.topics[2] == bytes32(uint256(uint160(to))));
        assertEq(abi.decode(entry.data, (uint256)), amount);
    }
}
