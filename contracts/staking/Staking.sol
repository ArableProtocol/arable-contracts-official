// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../interfaces/staking/IStaking.sol";
import "../interfaces/staking/IStakingRoot.sol";
import "../interfaces/staking/ITokenLocker.sol";

/** @title Staking
 * @notice General staking contract for staking ACRE
 */
contract Staking is Ownable, ReentrancyGuard, IStaking, Pausable {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; // amount of tokens staked by the user
        uint256 rewardDebt; // amount to be cut off in rewards calculation - updated when deposit, withdraw or claim
        uint256 pendingRewards; // pending rewards for the user
    }

    struct PoolInfo {
        uint256 accTokenPerShare; // accumulative rewards per deposited token
        uint256 depositAmount;
        uint256 rewardsAmount;
        uint256 lockupDuration;
    }

    IStakingRoot public stakingRoot;

    IERC20 public token;

    uint256 public totalDistributed;
    uint256 public totalReleased;

    PoolInfo public poolInfo;
    mapping(address => UserInfo) public userInfo;
    uint256 public constant SHARE_MULTIPLIER = 1e12;

    event Deposit(address indexed user, uint256 amount);
    event RequestWithdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event TokenAddressSet(address token);
    event PoolLockDurationChanged(uint256 lockupDuration);

    event Pause();
    event Unpause();

    constructor(IStakingRoot _root) {
        require(address(_root) != address(0), "Invalid StakingRoot");
        stakingRoot = _root;
    }

    modifier onlyRoot() {
        require(msg.sender == address(stakingRoot), "Not StakingRoot");
        _;
    }

    function getTotalDepositAmount() public view override returns (uint256) {
        return poolInfo.depositAmount;
    }

    // staking token and reward token are same, reward amount is contract_token_balance - total_staked
    function getTotalDistributableRewards() public view returns (uint256) {
        return token.balanceOf(address(this)) + totalReleased - getTotalDepositAmount() - totalDistributed;
    }

    // accumulative rewards for staking amount
    function accumulativeRewards(uint256 amount, uint256 _accTokenPerShare) internal pure returns (uint256) {
        return (amount * _accTokenPerShare) / (SHARE_MULTIPLIER);
    }

    /**
     * @notice get Pending Rewards of a user
     *
     * @param _user: User Address
     */
    function pendingRewards(address _user) external view override returns (uint256) {
        require(_user != address(0), "Invalid user address");
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 depositAmount = pool.depositAmount;
        if (depositAmount != 0) {
            uint256 tokenReward = getTotalDistributableRewards();
            accTokenPerShare = accTokenPerShare + ((tokenReward * (SHARE_MULTIPLIER)) / (depositAmount));
        }

        // last_accumulated_reward is expressed as rewardDebt
        // accumulated_rewards - last_accumulated_reward + last_pending_rewards
        return accumulativeRewards(user.amount, accTokenPerShare) - (user.rewardDebt) + (user.pendingRewards);
    }

    /**
     * @notice _updatePool distribute pending rewards
     *
     */
    function _updatePool() internal {
        uint256 depositAmount = poolInfo.depositAmount;

        if (depositAmount == 0) {
            return;
        }

        uint256 tokenReward = getTotalDistributableRewards();
        poolInfo.rewardsAmount += tokenReward;
        // accTokenPerShare is by definition accumulation of token rewards per staked token
        poolInfo.accTokenPerShare += (tokenReward * SHARE_MULTIPLIER) / depositAmount;

        totalDistributed = totalDistributed + tokenReward;
    }

    function _updateUserPendingRewards(address addr) internal {
        UserInfo storage user = userInfo[addr];
        if (user.amount == 0) {
            return;
        }

        user.pendingRewards += accumulativeRewards(user.amount, poolInfo.accTokenPerShare) - user.rewardDebt;
    }

    /**
     * @notice deposit token to the contract
     *
     * @param amount: Amount of token to deposit
     */
    function deposit(uint256 amount) external override whenNotPaused {
        require(amount > 0, "should deposit positive amount");

        _updatePool();
        _updateUserPendingRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        token.safeTransferFrom(address(msg.sender), address(this), amount);
        user.amount += amount;
        poolInfo.depositAmount += amount;
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);
        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice request token to be back
     *
     * @param amount: Amount of token to withdraw
     * @param _withdrawRewards: flag to withdraw reward or not
     */
    function requestWithdraw(uint256 amount, bool _withdrawRewards) external override nonReentrant whenNotPaused {
        require(amount > 0, "amount should be positive");
        _updatePool();
        _updateUserPendingRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Withdrawing more than you have!");

        if (_withdrawRewards) {
            uint256 claimedAmount = safeTokenTransfer(msg.sender, user.pendingRewards);
            emit Claim(msg.sender, claimedAmount);
            user.pendingRewards = user.pendingRewards - claimedAmount;
            totalReleased += claimedAmount;
        }

        address tokenLocker = (stakingRoot).tokenLocker();
        token.approve(tokenLocker, amount);
        ITokenLocker(tokenLocker).lockToken(
            address(token),
            msg.sender,
            amount,
            block.timestamp + poolInfo.lockupDuration
        );
        user.amount -= amount;
        poolInfo.depositAmount -= amount;
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);
        emit RequestWithdraw(msg.sender, amount);
    }

    /**
     * @notice claim rewards from a certain pool
     *
     */
    function claim() external override nonReentrant whenNotPaused {
        _updatePool();
        _updateUserPendingRewards(msg.sender);

        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        if (user.pendingRewards > 0) {
            uint256 claimedAmount = safeTokenTransfer(msg.sender, user.pendingRewards);
            emit Claim(msg.sender, claimedAmount);
            totalReleased += claimedAmount;
            user.pendingRewards -= claimedAmount;
            pool.rewardsAmount -= claimedAmount;
        }
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);
    }

    function safeTokenTransfer(address to, uint256 amount) internal returns (uint256) {
        PoolInfo memory pool = poolInfo;
        if (amount > pool.rewardsAmount) {
            token.safeTransfer(to, pool.rewardsAmount);
            return pool.rewardsAmount;
        } else {
            token.safeTransfer(to, amount);
            return amount;
        }
    }

    function getDepositAmount(address user) external view override returns (uint256) {
        return userInfo[user].amount;
    }

    function withdrawAnyToken(
        address _token,
        uint256 amount,
        address beneficiary
    ) external override onlyRoot {
        IERC20(_token).safeTransfer(beneficiary, amount);
    }

    function setToken(IERC20 _token) external onlyOwner {
        require(address(token) == address(0), "Token already set!");
        require(address(_token) != address(0), "Invalid Token Address");

        token = _token;

        emit TokenAddressSet(address(token));

        poolInfo.lockupDuration = 14 days;
        emit PoolLockDurationChanged(poolInfo.lockupDuration);
    }

    function updatePoolDuration(uint256 _lockupDuration) external onlyOwner {
        poolInfo.lockupDuration = _lockupDuration;

        emit PoolLockDurationChanged(_lockupDuration);
    }

    // This function is called per epoch by bot
    function claimRewardsFromRoot() external {
        stakingRoot.claimRewards();
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
