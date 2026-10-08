// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @notice Fixed-supply SIMDTEST with a PoolManager-outgoing tax paid as token dividends.
/// @dev No administrative roles or post-construction mint/burn paths.
contract SIMDTESTToken {
    string public constant name = "SIMDTEST";
    string public constant symbol = "SIMDTEST";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;
    uint256 public constant BUY_FEE_BPS = 300;
    uint256 public constant BPS = 10_000;
    uint256 public constant POOL_BPS = 9_000;
    uint256 public constant SWARM_BPS = 1_000;
    uint256 public constant MAGNITUDE = 1 << 128;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public immutable FACTORY;
    uint64 public immutable LAUNCH_NUMBER;
    address private _dividendDistributor;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public magnifiedDividendPerShare;
    uint256 public queuedDividends;
    uint256 public totalFeesCollected;
    uint256 public totalDividendsClaimed;
    mapping(address => uint256) private _checkpoint;
    mapping(address => uint256) private _magnifiedCredit;
    mapping(address => uint256) public withdrawnDividends;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed holder, address indexed spender, uint256 value);
    event DividendsDistributed(uint256 amount, uint256 eligibleBalance);
    event DividendClaimed(address indexed holder, uint256 amount);

    error InvalidSender();
    error InvalidReceiver();
    error InvalidSpender();
    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidFactory();
    error InvalidPoolManager();

    constructor(address factory_, address poolManager_, uint64 launchNumber_) {
        if (
            factory_ != msg.sender || factory_.code.length == 0 || factory_ == POOL_MANAGER
                || factory_ == BURN_ADDRESS
        ) revert InvalidFactory();
        if (poolManager_ != POOL_MANAGER) revert InvalidPoolManager();
        FACTORY = factory_;
        LAUNCH_NUMBER = launchNumber_;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function isDividendExcluded(address account) public view returns (bool) {
        return _isFixedDividendExcluded(account) || account == dividendDistributor();
    }

    /// @notice Resolve after deployment: the distributor's address depends on the token's address.
    function dividendDistributor() public view returns (address) {
        if (_dividendDistributor != address(0)) return _dividendDistributor;
        return ILaunchFactory(FACTORY).distributorOf(LAUNCH_NUMBER);
    }

    function eligibleSupply() public view returns (uint256) {
        uint256 eligible = totalSupply - balanceOf[POOL_MANAGER] - balanceOf[address(this)]
            - balanceOf[BURN_ADDRESS] - balanceOf[FACTORY];
        address distributor = dividendDistributor();
        // Count each excluded balance once, including while the registry still returns zero.
        if (!_isFixedDividendExcluded(distributor)) eligible -= balanceOf[distributor];
        return eligible;
    }

    /// @notice Previously earned dividends remain claimable even after selling the entire balance.
    function withdrawableDividendOf(address account) public view returns (uint256) {
        if (isDividendExcluded(account)) return 0;
        return (_magnifiedCredit[account]
                + balanceOf[account]
                * (magnifiedDividendPerShare - _checkpoint[account])) / MAGNITUDE;
    }

    /// @notice Pays only the caller's entitlement. Empty or excluded claims return zero.
    function claim() external returns (uint256 amount) {
        if (isDividendExcluded(msg.sender)) return 0;
        _accrue(msg.sender);
        amount = _magnifiedCredit[msg.sender] / MAGNITUDE;
        if (amount == 0) return 0;

        // Keep fractional credit; new payout tokens earn only subsequent distributions.
        _magnifiedCredit[msg.sender] %= MAGNITUDE;
        withdrawnDividends[msg.sender] += amount;
        totalDividendsClaimed += amount;
        _move(address(this), msg.sender, amount);
        emit DividendClaimed(msg.sender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert InvalidSender();
        if (to == address(0)) revert InvalidReceiver();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        // Bind the first registered distributor permanently; no setter or later registry override.
        if (_dividendDistributor == address(0)) _dividendDistributor = dividendDistributor();

        // Destination takes precedence: ALL transfers into the manager settle at face value.
        uint256 fee = from == POOL_MANAGER && to != POOL_MANAGER ? amount * BUY_FEE_BPS / BPS : 0;
        if (fee != 0) {
            _move(from, address(this), fee);
            totalFeesCollected += fee;
            _distribute(fee);
        }
        // Accrue the recipient's pre-buy balance at the new index before crediting the net buy.
        _move(from, to, amount - fee);
    }

    function _isFixedDividendExcluded(address account) private view returns (bool) {
        return account == POOL_MANAGER || account == address(this) || account == BURN_ADDRESS
            || account == address(0) || account == FACTORY;
    }

    function _move(address from, address to, uint256 amount) private {
        _accrue(from);
        _accrue(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _accrue(address account) private {
        if (isDividendExcluded(account)) return;
        _magnifiedCredit[account] += balanceOf[account] * (magnifiedDividendPerShare - _checkpoint[account]);
        _checkpoint[account] = magnifiedDividendPerShare;
    }

    function _distribute(uint256 fee) private {
        uint256 amount = queuedDividends + fee;
        uint256 eligible = eligibleSupply();
        if (eligible == 0) {
            queuedDividends = amount;
            return;
        }
        queuedDividends = 0;
        // Snapshot BEFORE the net purchase: new tokens cannot rebate their own buy fee.
        // Global division dust stays reserved, never redistributed or withdrawable by an admin.
        magnifiedDividendPerShare += amount * MAGNITUDE / eligible;
        emit DividendsDistributed(amount, eligible);
    }
}
