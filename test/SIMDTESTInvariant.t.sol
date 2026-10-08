// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTToken} from "src/SIMDTESTToken.sol";
import {TestBase} from "./helpers/TestBase.sol";

/// @dev Closed actor set; balances, fees and donations are recorded independently of token getters.
/// The reserve and burn address never originate transfers. Only claim() can spend the reserve.
contract SIMDTESTHandler is TestBase {
    SIMDTESTToken public immutable token;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public immutable distributor;
    address public immutable factory;
    address[4] public holders;
    mapping(address => uint256) public expectedBalance;
    mapping(address => uint256) public paidTo;
    uint256 public fees;
    uint256 public donations;
    uint256 public claimed;

    constructor(SIMDTESTToken token_, address distributor_) {
        token = token_;
        factory = msg.sender;
        distributor = distributor_;
        for (uint256 i; i < holders.length; ++i) {
            holders[i] = address(uint160(uint256(keccak256(abi.encode("invariant holder", i)))));
        }
        expectedBalance[MANAGER] = 900_000_000 ether;
        expectedBalance[distributor] = 100_000_000 ether;
    }

    function buy(uint256 recipient, uint256 seed, bool delegated) external {
        _transfer(MANAGER, _recipient(recipient), _amount(seed, expectedBalance[MANAGER]), delegated);
    }

    function sell(uint256 actor, uint256 seed, bool delegated) external {
        address from = holders[actor % holders.length];
        _transfer(from, MANAGER, _amount(seed, expectedBalance[from]), delegated);
    }

    function walletTransfer(uint256 actor, uint256 recipient, uint256 seed, bool delegated) external {
        address from = holders[actor % holders.length];
        _transfer(from, _recipient(recipient), _amount(seed, expectedBalance[from]), delegated);
    }

    function releaseSwarm(uint256 actor, uint256 seed) external {
        _transfer(
            distributor, holders[actor % holders.length], _amount(seed, expectedBalance[distributor]), false
        );
    }

    function forwardFactoryBalance(uint256 recipient, uint256 seed) external {
        _transfer(factory, _recipient(recipient), _amount(seed, expectedBalance[factory]), false);
    }

    function claim(uint256 actor) external {
        address holder = holders[actor % holders.length];
        uint256 owed = token.withdrawableDividendOf(holder);
        uint256 balanceBefore = token.balanceOf(holder);
        uint256 reserveBefore = token.balanceOf(address(token));
        vm.prank(holder);
        uint256 paid = token.claim();
        require(paid == owed, "claim did not pay entitlement");
        require(token.balanceOf(holder) == balanceBefore + paid, "claim balance mismatch");
        require(token.balanceOf(address(token)) == reserveBefore - paid, "reserve payout mismatch");
        expectedBalance[address(token)] -= paid;
        expectedBalance[holder] += paid;
        paidTo[holder] += paid;
        claimed += paid;
        require(token.withdrawableDividendOf(holder) == 0, "claim leaves whole units owed");
        vm.prank(holder);
        require(token.claim() == 0, "duplicate claim paid twice");
    }

    function rejectedOverspend(uint256 actor, bool delegated) external {
        address from = holders[actor % holders.length];
        uint256 tooMuch = expectedBalance[from] + 1;
        uint256 owedBefore = token.withdrawableDividendOf(from);
        bytes memory callData;
        if (delegated) {
            vm.prank(from);
            token.approve(address(this), tooMuch);
            callData = abi.encodeCall(token.transferFrom, (from, MANAGER, tooMuch));
        } else {
            callData = abi.encodeCall(token.transfer, (MANAGER, tooMuch));
        }
        vm.prank(delegated ? address(this) : from);
        (bool ok, bytes memory reason) = address(token).call(callData);
        require(!ok, "overspend succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(SIMDTESTToken.InsufficientBalance.selector)),
            "wrong overspend error"
        );
        if (delegated) {
            require(token.allowance(from, address(this)) == tooMuch, "failed transfer spent allowance");
        }
        require(token.withdrawableDividendOf(from) == owedBefore, "failed transfer changed credit");
    }

    function _transfer(address from, address to, uint256 amount, bool delegated) private {
        uint256 fee = from == MANAGER && to != MANAGER ? amount * 3 / 100 : 0;
        uint256 fromOwed = token.withdrawableDividendOf(from);
        uint256 toOwed = token.withdrawableDividendOf(to);
        if (delegated) {
            // Exercise exact and unlimited allowances, including zero-amount transferFrom.
            uint256 approved = amount % 2 == 0 ? amount : type(uint256).max;
            vm.prank(from);
            require(token.approve(address(this), approved), "approve returned false");
            require(token.transferFrom(from, to, amount), "transferFrom returned false");
            require(
                token.allowance(from, address(this)) == (approved == type(uint256).max ? approved : 0),
                "wrong remaining allowance"
            );
        } else {
            vm.prank(from);
            require(token.transfer(to, amount), "transfer returned false");
        }
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        expectedBalance[address(token)] += fee;
        fees += fee;
        if (to == address(token)) donations += amount - fee;
        // Moving a balance never transfers its already-earned credit to the recipient.
        if (fee == 0) {
            require(token.withdrawableDividendOf(from) == fromOwed, "untaxed transfer lost sender credit");
            require(token.withdrawableDividendOf(to) == toOwed, "untaxed transfer changed recipient credit");
        }
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 choice = seed % 9;
        if (choice < 4) return holders[choice];
        if (choice == 4) return MANAGER;
        if (choice == 5) return address(token);
        if (choice == 6) return token.BURN_ADDRESS();
        if (choice == 7) return distributor;
        return factory;
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        uint256 choice = seed % 7;
        if (choice == 0) return 0;
        if (choice == 1) return maximum;
        if (choice == 2) return maximum / 2;
        if (choice == 3) return maximum < 1 ? maximum : 1;
        if (choice == 4) return maximum < 33 ? maximum : 33;
        if (choice == 5) return maximum < 34 ? maximum : 34;
        return seed % (maximum + 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract SIMDTESTInvariantTest is TestBase {
    SIMDTESTToken private token;
    SIMDTESTHandler private handler;
    address private constant DISTRIBUTOR = address(0xD157);

    function distributorOf(uint64 launchNumber) external pure returns (address) {
        require(launchNumber == 1, "wrong launch");
        return DISTRIBUTOR;
    }

    function setUp() public {
        address manager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        token = new SIMDTESTToken(address(this), manager, 1);
        token.transfer(DISTRIBUTOR, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        handler = new SIMDTESTHandler(token, DISTRIBUTOR);
    }

    // Foundry's invariant targeting ABI, without adding a new library or a remapping.
    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_BalancesAndSupplyMatchIndependentLedger() public view {
        address[9] memory accounts = [
            address(this),
            DISTRIBUTOR,
            token.POOL_MANAGER(),
            address(token),
            token.BURN_ADDRESS(),
            handler.holders(0),
            handler.holders(1),
            handler.holders(2),
            handler.holders(3)
        ];
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            uint256 actual = token.balanceOf(accounts[i]);
            require(actual == handler.expectedBalance(accounts[i]), "balance differs from independent ledger");
            sum += actual;
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function invariant_ReserveCoversEveryClaimAndQueuedFee() public view {
        uint256 owed;
        uint256 eligible;
        for (uint256 i; i < 4; ++i) {
            address holder = handler.holders(i);
            owed += token.withdrawableDividendOf(holder);
            eligible += handler.expectedBalance(holder);
            assertEq(token.withdrawnDividends(holder), handler.paidTo(holder));
        }
        uint256 reserve = token.balanceOf(address(token));
        assertLe(owed + token.queuedDividends(), reserve - handler.donations());
        assertEq(reserve + handler.claimed(), handler.fees() + handler.donations());
        assertEq(token.totalFeesCollected(), handler.fees());
        assertEq(token.totalDividendsClaimed(), handler.claimed());
        assertLe(handler.claimed(), handler.fees());
        assertEq(token.eligibleSupply(), eligible);
    }

    function invariant_ExcludedAddressesNeverEarn() public view {
        address[6] memory excluded = [
            address(0), token.POOL_MANAGER(), address(token), token.BURN_ADDRESS(), address(this), DISTRIBUTOR
        ];
        for (uint256 i; i < excluded.length; ++i) {
            assertEq(token.withdrawableDividendOf(excluded[i]), 0);
            assertEq(token.withdrawnDividends(excluded[i]), 0);
        }
    }

    /// @dev Every random history must end with all whole-unit debts payable, even by zero-balance sellers.
    function afterInvariant() public {
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        invariant_BalancesAndSupplyMatchIndependentLedger();
        invariant_ReserveCoversEveryClaimAndQueuedFee();
    }
}
