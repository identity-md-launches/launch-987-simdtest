// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";
import {TestBase} from "./helpers/TestBase.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test-only pair currency. Fork tests preserve the REAL mainnet PoolManager;
/// only IMD is replaced to give isolated traders deterministic funding.
contract PairCurrencyFixture {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ITransferToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

abstract contract UniswapV4TestBase is TestBase, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant TRADER = address(0x7ADE);
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    IPoolManager internal manager = IPoolManager(MANAGER);
    SIMDTESTToken internal token;
    PairCurrencyFixture internal pair;
    PoolKey internal key;
    int24 internal lower;
    int24 internal upper;
    uint128 internal liquidity;
    uint256 internal seedSpent;

    function tokenFirst() internal pure virtual returns (bool);

    function setUp() public {
        if (MANAGER.code.length == 0) {
            vm.chainId(1);
            // Execute initcode AT the canonical address so NoDelegateCall's immutable is correct.
            vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
            (bool built, bytes memory runtime) = MANAGER.call("");
            require(built && runtime.length != 0, "manager construction failed");
            vm.etch(MANAGER, runtime);
        } else {
            require(block.chainid == 1, "fork must be Ethereum mainnet");
        }
        vm.etch(IMD, address(new PairCurrencyFixture()).code);
        pair = PairCurrencyFixture(IMD);
        _deployInOrder();
        bool first = tokenFirst();
        key = PoolKey({
            currency0: Currency.wrap(first ? address(token) : IMD),
            currency1: Currency.wrap(first ? IMD : address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        uint160 price = first ? 125270724187523965593206900 : 50108289675009586237282760313921;
        int24 tick = manager.initialize(key, price);
        int24 floorTick = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) floorTick -= 60;
        lower = first ? floorTick + 60 : TickMath.minUsableTick(60);
        upper = first ? TickMath.maxUsableTick(60) : floorTick;
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 seed = SUPPLY * 9 / 10;
        uint256 computed = first
            ? FullMath.mulDiv(seed, FullMath.mulDiv(a, b, 1 << 96), b - a)
            : FullMath.mulDiv(seed, 1 << 96, b - a);
        require(computed <= uint256(uint128(type(int128).max)), "liquidity too large");
        liquidity = uint128(computed);
        token.transfer(DISTRIBUTOR, SUPPLY / 10);
        uint256 before = token.balanceOf(address(this));
        manager.unlock(abi.encode(uint8(0), false, int256(0), false));
        seedSpent = before - token.balanceOf(address(this));
        token.transfer(token.BURN_ADDRESS(), token.balanceOf(address(this)));
        pair.mint(TRADER, 10 ether);
        vm.prank(TRADER);
        pair.approve(address(this), 10 ether);
    }

    function test_SingleSidedSeedAndSwapsSettleWithoutShortfall() public {
        assertGt(seedSpent, 0);
        assertLe(seedSpent, 900_000_000 ether);
        assertApprox(seedSpent, 900_000_000 ether, 1_000_000);
        assertEq(token.balanceOf(MANAGER), seedSpent);
        assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000 ether);
        assertEq(token.totalFeesCollected(), 0);

        BalanceDelta bought = _swap(!tokenFirst(), -0.01 ether, false);
        uint256 gross = uint256(uint128(tokenFirst() ? bought.amount0() : bought.amount1()));
        uint256 fee = gross * 3 / 100;
        assertGt(gross, 0);
        assertEq(token.balanceOf(TRADER), gross - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(MANAGER), seedSpent - gross);
        assertGt(token.withdrawableDividendOf(DISTRIBUTOR), 0);
        _assertSettled();

        uint256 net = token.balanceOf(TRADER);
        vm.prank(TRADER);
        token.approve(address(this), net);
        uint256 pairBefore = pair.balanceOf(TRADER);
        _swap(tokenFirst(), -int256(net), false);
        assertEq(token.balanceOf(TRADER), 0);
        assertEq(token.balanceOf(MANAGER), seedSpent - fee);
        assertEq(token.totalFeesCollected(), fee);
        assertGt(pair.balanceOf(TRADER), pairBefore);
        assertEq(token.totalSupply(), SUPPLY);
        _assertSettled();
    }

    function test_ExactOutputBuySettlesGrossButRecipientGetsNet() public {
        _swap(!tokenFirst(), 100 ether, false);
        assertEq(token.balanceOf(TRADER), 97 ether);
        assertEq(token.balanceOf(address(token)), 3 ether);
        _assertSettled();
    }

    function test_UnderpaidSellRevertsCurrencyNotSettledAndRollsBack() public {
        _swap(!tokenFirst(), -0.01 ether, false);
        uint256 held = token.balanceOf(TRADER);
        vm.prank(TRADER);
        token.approve(address(this), held);
        uint256 managerBefore = token.balanceOf(MANAGER);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        manager.unlock(abi.encode(uint8(1), tokenFirst(), -int256(held), true));
        assertEq(token.balanceOf(TRADER), held);
        assertEq(token.balanceOf(MANAGER), managerBefore);
        assertEq(token.allowance(TRADER, address(this)), held);
        _assertSettled();
    }

    function test_CallbackRejectsNonManager() public {
        vm.expectRevert();
        this.unlockCallback("");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == MANAGER, "only manager");
        (uint8 operation, bool zeroForOne, int256 specified, bool underpay) =
            abi.decode(data, (uint8, bool, int256, bool));
        BalanceDelta delta;
        if (operation == 0) {
            (delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), ""
            );
        } else {
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(key, SwapParams(zeroForOne, specified, limit), "");
        }
        address payer = operation == 0 ? address(this) : TRADER;
        _settle(key.currency0, delta.amount0(), payer, underpay);
        _settle(key.currency1, delta.amount1(), payer, underpay);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer, bool underpay) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            if (underpay && Currency.unwrap(currency) == address(token)) --owed;
            manager.sync(currency);
            ITransferToken asset = ITransferToken(Currency.unwrap(currency));
            if (payer == address(this)) require(asset.transfer(MANAGER, owed), "transfer failed");
            else require(asset.transferFrom(payer, MANAGER, owed), "transferFrom failed");
            assertEq(manager.settle(), owed);
        } else if (delta > 0) {
            manager.take(currency, TRADER, uint128(delta));
        }
    }

    function _swap(bool zeroForOne, int256 specified, bool underpay) private returns (BalanceDelta) {
        return
            abi.decode(manager.unlock(abi.encode(uint8(1), zeroForOne, specified, underpay)), (BalanceDelta));
    }

    function _assertSettled() private view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertTrue(!manager.isUnlocked());
        assertTrue(manager.currencyDelta(address(this), key.currency0) == 0);
        assertTrue(manager.currencyDelta(address(this), key.currency1) == 0);
    }

    function _deployInOrder() private {
        bytes32 initHash = keccak256(type(SIMDTESTToken).creationCode);
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if ((predicted < IMD) == tokenFirst()) {
                token = new SIMDTESTToken{salt: salt}();
                return;
            }
        }
        revert("token address search exhausted");
    }
}

contract UniswapV4Token0Test is UniswapV4TestBase {
    function tokenFirst() internal pure override returns (bool) {
        return true;
    }
}

contract UniswapV4Token1Test is UniswapV4TestBase {
    function tokenFirst() internal pure override returns (bool) {
        return false;
    }
}
