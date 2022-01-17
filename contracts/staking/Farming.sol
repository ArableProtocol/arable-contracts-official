// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../interfaces/staking/IFarming.sol";
import "../interfaces/staking/ITokenLocker.sol";
import "../interfaces/staking/IFarmingFactory.sol";

/** @title Farming
 *
 * @notice Contract that distribute rewards to multiple pools based on allocation point ratio
 *
 */
contract Farming is Ownable, ReentrancyGuard, IFarming, Pausable {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; // amount of tokens deposited by the user
        uint256 rewardDebt; // amount to be cut off in rewards calculation - updated when deposit, withdraw or claim
        uint256 pendingRewards; // pending rewards for the user
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint; // allocation point for the pool for rewards distribution
        uint256 accTokenPerShare; // accumulative rewards per deposited token
        uint256 lockupDuration;
    }

    IFarmingFactory public factory;
    address public token;

    uint256 public totalDistributed;
    uint256 public totalReleased;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0; // sum of pools' allocation points

    uint256 public constant SHARE_MULTIPLIER = 1e12;

    mapping(address => bool) private isLPPoolAdded; // lp token already added flag

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event RequestWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 pid, uint256 allocPoint, uint256 lockupDuration, address lp);
    event PoolLockDurationChanged(uint256 pid, uint256 lockupDuration);
    event Pause();
    event Unpause();

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    constructor(IFarmingFactory _factory, address _token) {
        require(address(_factory) != address(0), "Invalid factory!");
        require(address(_token) != address(0), "Invalid token");

        factory = _factory;
        token = _token;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // balance of the contract includes already distributed and not distributed amounts
    function getTotalDistributableRewards() public view returns (uint256) {
        // (totalDistributed - totalReleased) is the sum of members' pending amounts
        return IERC20(token).balanceOf(address(this)) + totalReleased - totalDistributed;
    }

    // accumulative rewards for deposited amount
    function accumulativeRewards(uint256 amount, uint256 _accTokenPerShare) internal pure returns (uint256) {
        return (amount * _accTokenPerShare) / (SHARE_MULTIPLIER);
    }

    function pendingToken(uint256 _pid, address _user) external view validatePoolByPid(_pid) returns (uint256) {
        require(_user != address(0), "Invalid address!");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply != 0) {
            uint256 tokenReward = (getTotalDistributableRewards() * (pool.allocPoint)) / (totalAllocPoint);
            accTokenPerShare += (tokenReward * (SHARE_MULTIPLIER)) / (lpSupply);
        }

        // last_accumulated_reward is expressed as rewardDebt
        // accumulated_rewards - last_accumulated_reward + last_pending_rewards
        return accumulativeRewards(user.amount, accTokenPerShare) - user.rewardDebt + user.pendingRewards;
    }

    // update all pools' accumulative rewards per share
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }

        totalDistributed += getTotalDistributableRewards();
    }

    // update pool's accumulative rewards per share by id
    function _updatePool(uint256 _pid) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];

        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            return;
        }

        uint256 tokenReward = (getTotalDistributableRewards() * pool.allocPoint) / totalAllocPoint;
        // accTokenPerShare is by definition accumulation of token rewards per staked token
        pool.accTokenPerShare += (tokenReward * (SHARE_MULTIPLIER)) / (lpSupply);
    }

    function _updateUserPendingRewards(uint256 _pid, address addr) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][addr];
        if (user.amount == 0) {
            return;
        }

        user.pendingRewards += accumulativeRewards(user.amount, pool.accTokenPerShare) - user.rewardDebt;
    }

    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _withdrawRewards
    ) public validatePoolByPid(_pid) whenNotPaused nonReentrant {
        require(_amount > 0, "amount should be positive");

        massUpdatePools();
        _updateUserPendingRewards(_pid, msg.sender);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (_withdrawRewards) {
            processReward(user, _pid);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount += _amount;
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, pool.accTokenPerShare);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function requestWithdraw(
        uint256 _pid,
        uint256 _amount,
        bool _withdrawRewards
    ) public nonReentrant validatePoolByPid(_pid) whenNotPaused {
        massUpdatePools();
        _updateUserPendingRewards(_pid, msg.sender);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: should withdraw less than balance");
        require(_amount > 0, "withdraw: amount should be positive");
        if (_withdrawRewards) {
            processReward(user, _pid);
        }

        address tokenLocker = factory.tokenLocker();
        pool.lpToken.approve(tokenLocker, _amount);
        ITokenLocker(tokenLocker).lockToken(
            address(pool.lpToken),
            msg.sender,
            _amount,
            block.timestamp + pool.lockupDuration
        );
        user.amount -= _amount;
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, pool.accTokenPerShare);
        emit RequestWithdraw(msg.sender, _pid, _amount);
    }

    function processReward(UserInfo storage user, uint256 _pid) private {
        uint256 amount = safeTokenTransfer(msg.sender, user.pendingRewards);

        emit Claim(msg.sender, _pid, amount);
        user.pendingRewards = user.pendingRewards - amount;

        totalReleased += amount;
    }

    function claim(uint256 _pid) public nonReentrant validatePoolByPid(_pid) whenNotPaused {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        massUpdatePools();
        _updateUserPendingRewards(_pid, msg.sender);
        processReward(user, _pid);
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, pool.accTokenPerShare);
    }

    function safeTokenTransfer(address _to, uint256 _amount) internal returns (uint256) {
        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        if (_amount > tokenBal) {
            IERC20(token).safeTransfer(_to, tokenBal);
            return tokenBal;
        } else {
            IERC20(token).safeTransfer(_to, _amount);
            return _amount;
        }
    }

    function getDepositAmount(address user, uint256 _pid)
        external
        view
        override
        validatePoolByPid(_pid)
        returns (uint256)
    {
        return userInfo[_pid][user].amount;
    }

    function withdrawAnyToken(IERC20 _token, uint256 amount) external onlyOwner {
        _token.safeTransfer(msg.sender, amount);
    }

    function updatePoolDuration(uint256 _pid, uint256 _lockupDuration) external onlyOwner validatePoolByPid(_pid) {
        poolInfo[_pid].lockupDuration = _lockupDuration;

        emit PoolLockDurationChanged(_pid, _lockupDuration);
    }

    function addPool(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        require(!isLPPoolAdded[address(_lpToken)], "There's already a pool with that LP token!");
        // Note: it is designed to support when staking token is different from reward token
        require(address(_lpToken) != token, "Staking token should be different from reward token");
        require(address(_lpToken) != address(0), "Invalid lp");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint += _allocPoint;
        uint256 lockupDuration = 14 days;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                accTokenPerShare: 0,
                lockupDuration: lockupDuration
            })
        );

        isLPPoolAdded[address(_lpToken)] = true;

        emit PoolAdded(poolInfo.length - 1, _allocPoint, lockupDuration, address(_lpToken));
    }

    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner validatePoolByPid(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint - (poolInfo[_pid].allocPoint) + (_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpause();
    }
}
