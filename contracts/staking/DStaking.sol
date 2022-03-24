// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/staking/IDStaking.sol";
import "../interfaces/staking/IStakingRoot.sol";
import "../interfaces/staking/IDStakingOverview.sol";
import "../interfaces/staking/ITokenLocker.sol";

/**
 * @title DStaking
 *
 * Contract that is operated by a validator where it accepts delegations from users
 * Total voting power of a validator is determined by the total sum of delegations
 * Validators run a service for their delegators and delegators are paying commissions
 * from the delegated staking rewards
 *
 */

contract DStaking is Ownable, IDStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; // amount of tokens delegated by the user
        uint256 rewardDebt; // amount to be cut off in rewards calculation - updated when deposit, withdraw or claim
        uint256 pendingRewards; // pending rewards for the user
        uint256 lastRedelegation; // last timestamp that users claim
    }

    struct PoolInfo {
        uint256 accTokenPerShare; // accumulative rewards per deposited token
        uint256 delegatedAmount; // total delegation amount of the contract
        uint256 rewardsAmount; // total rewards amount of the contract - change on rewards distribution / claim
        uint256 lockupDuration; // lockup duration - applied when undelegate - static
    }

    IStakingRoot public stakingRoot;
    IERC20 public token;

    uint256 public totalDistributed;
    uint256 public totalReleased;

    PoolInfo public poolInfo;
    mapping(address => UserInfo) public userInfo;

    uint256 public commissionRate;
    uint256 public commissionReward;
    uint256 public constant COMMION_RATE_MULTIPLIER = 1e3;
    uint256 public lastCommissionRateUpdateTimeStamp;
    uint256 public constant COMMION_RATE_MAX = 200; // max is 20%
    uint256 public constant COMMION_UPDATE_MIN_DURATION = 1 days; // update once once in a day

    uint256 public constant SHARE_MULTIPLIER = 1e12;

    event Delegate(address indexed user, uint256 amount);
    event Undelegate(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event Redelegate(address indexed user, address toDStaking, uint256 amount);
    event CommissionRateUpdated(uint256 commissionRate);
    event CommissionRewardClaimed(uint256 claimedAmount);
    event PoolLockDurationChanged(uint256 lockupDuration);

    modifier onlyRoot() {
        require(msg.sender == address(stakingRoot), "Not StakingRoot");
        _;
    }

    modifier onlyActiveDStaking(address dStaking) {
        require(stakingRoot.isDStaking(dStaking) && !stakingRoot.isDStakingRemoved(dStaking), "Invalid dStaking");
        _;
    }

    constructor(
        IERC20 _token,
        IStakingRoot _stakingRoot,
        uint256 _commissionRate
    ) {
        require(address(_token) != address(0), "Invalid token");
        require(address(_stakingRoot) != address(0), "Invalid stakingRoot");
        token = _token;
        stakingRoot = _stakingRoot;

        require(_commissionRate <= COMMION_RATE_MAX, "Too big commissionRate");

        commissionRate = _commissionRate;
        lastCommissionRateUpdateTimeStamp = block.timestamp;

        poolInfo.lockupDuration = 14 days;

        emit PoolLockDurationChanged(poolInfo.lockupDuration);
    }

    function updatePoolDuration(uint256 _lockupDuration) external override onlyRoot {
        poolInfo.lockupDuration = _lockupDuration;

        emit PoolLockDurationChanged(_lockupDuration);
    }

    // The creator of this contract
    function stakingCreator() private view returns (address) {
        return stakingRoot.dStakingCreators(address(this));
    }

    // delegating token and reward token are same, reward amount is contract_token_balance - total_delegation
    function getTotalDistributableRewards() public view returns (uint256) {
        return token.balanceOf(address(this)) + totalReleased - poolInfo.delegatedAmount - totalDistributed;
    }

    // accumulative rewards for delegated amount
    function accumulativeRewards(uint256 amount, uint256 _accTokenPerShare) internal pure returns (uint256) {
        return (amount * _accTokenPerShare) / (SHARE_MULTIPLIER);
    }

    /**
     * @notice get pending rewards of a user
     *
     * @param _user: User Address
     */
    function pendingRewards(address _user) external view override returns (uint256) {
        require(_user != address(0), "Invalid user address");
        UserInfo storage user = userInfo[_user];
        uint256 accTokenPerShare = poolInfo.accTokenPerShare;
        uint256 delegatedAmount = poolInfo.delegatedAmount;

        uint256 tokenReward = getTotalDistributableRewards();

        if (tokenReward != 0 && delegatedAmount != 0) {
            accTokenPerShare += (tokenReward * SHARE_MULTIPLIER) / delegatedAmount;
        }

        // last_accumulated_reward is expressed as rewardDebt
        // accumulated_rewards - last_accumulated_reward + last_pending_rewards
        return accumulativeRewards(user.amount, accTokenPerShare) - user.rewardDebt + user.pendingRewards;
    }

    /**
     * @notice _updatePool distribute pendingRewards
     *
     */
    function _updatePool() internal {
        uint256 delegatedAmount = poolInfo.delegatedAmount;
        if (delegatedAmount == 0) {
            return;
        }
        uint256 tokenReward = getTotalDistributableRewards();
        poolInfo.rewardsAmount += tokenReward;
        // accTokenPerShare is by definition accumulation of token rewards per delegated token
        poolInfo.accTokenPerShare += (tokenReward * SHARE_MULTIPLIER) / delegatedAmount;

        totalDistributed += tokenReward;
    }

    function _updateUserPendingRewards(address addr) internal {
        UserInfo storage user = userInfo[addr];
        if (user.amount == 0) {
            return;
        }

        user.pendingRewards += accumulativeRewards(user.amount, poolInfo.accTokenPerShare) - user.rewardDebt;
    }

    /**
     * @notice delegate token
     *
     * @param depositer: {address}
     * @param amount: {uint256}
     * @param beneficiary: {address}
     */
    function _delegate(
        address depositer,
        uint256 amount,
        address beneficiary
    ) private onlyActiveDStaking(address(this)) {
        require(amount > 0, "amount should be positive");
        _updatePool();
        _updateUserPendingRewards(beneficiary);
        UserInfo storage user = userInfo[beneficiary];
        token.safeTransferFrom(depositer, address(this), amount);
        poolInfo.delegatedAmount += amount;
        user.amount += amount;

        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);

        IDStakingOverview(IStakingRoot(stakingRoot).dstakingOverview()).onDelegate(beneficiary, amount);

        emit Delegate(beneficiary, amount);
    }

    // initDeposit is a function called by StakingRoot right after creation of the contract
    function initDeposit(
        address creator,
        address beneficiary,
        uint256 amount
    ) external override onlyRoot {
        _delegate(creator, amount, beneficiary);
    }

    function delegateFor(address beneficiary, uint256 amount) external override {
        _delegate(msg.sender, amount, beneficiary);
    }

    /**
     * @notice delegate token
     *
     * @param amount: Amount of token to delegate
     */
    function delegate(uint256 amount) external override {
        _delegate(msg.sender, amount, msg.sender);
    }

    function processRewards(address addr) private {
        UserInfo storage user = userInfo[addr];

        uint256 commissionFee = (user.pendingRewards * commissionRate) / COMMION_RATE_MULTIPLIER;
        uint256 rewards = user.pendingRewards - commissionFee;
        uint256 claimedAmount = safeTokenTransfer(addr, rewards);

        uint256 total = (claimedAmount * COMMION_RATE_MULTIPLIER) / (COMMION_RATE_MULTIPLIER - commissionRate);
        uint256 fee = total - claimedAmount;

        if (claimedAmount == rewards) {
            total = user.pendingRewards;
            fee = commissionFee;
        }

        totalReleased += claimedAmount;
        user.pendingRewards = user.pendingRewards - total;
        poolInfo.rewardsAmount -= claimedAmount;

        commissionReward = commissionReward + fee;

        emit Claim(addr, total);
    }

    /**
     * @notice redelegate token
     *
     * @param toDStaking: DStaking address
     * @param amount: Amount of token to redelegate
     */
    function redelegate(address toDStaking, uint256 amount) external override onlyActiveDStaking(toDStaking) {
        require(amount > 0, "amount should be positive");

        _updatePool();
        _updateUserPendingRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Redelegating more than you have!");

        require(!stakingRoot.isRedelegationDisabled(), "Redelegation is disabled");
        require(
            user.lastRedelegation + stakingRoot.redelegationAttemptPeriod() <= block.timestamp,
            "You can't redelegate now"
        );

        user.amount -= amount;
        poolInfo.delegatedAmount -= amount;
        user.lastRedelegation = block.timestamp;

        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);

        IDStakingOverview(stakingRoot.dstakingOverview()).onUndelegate(msg.sender, amount);

        token.approve(toDStaking, amount);
        IDStaking(toDStaking).delegateFor(msg.sender, amount);

        emit Redelegate(msg.sender, toDStaking, amount);
    }

    /**
     * @notice undelegate token
     *
     * @param amount: Amount of token to deposit
     */
    function undelegate(uint256 amount) external override nonReentrant {
        require(amount > 0, "Amount should be positive");

        _updatePool();
        _updateUserPendingRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Withdrawing more than you have!");

        // check for owner
        if (stakingCreator() == msg.sender) {
            // creator is trying to undelegate
            if (!stakingRoot.isDStakingRemoved(address(this))) {
                require(user.amount - amount >= (stakingRoot).minTokenAmountForDStaker(), "Too much");
            }
        }

        address tokenLocker = (stakingRoot).tokenLocker();
        token.approve(tokenLocker, amount);
        ITokenLocker(tokenLocker).lockToken(
            address(token),
            msg.sender,
            amount,
            block.timestamp + poolInfo.lockupDuration
        );
        poolInfo.delegatedAmount -= amount;
        user.amount -= amount;
        // last_accumulated_reward is expressed as rewardDebt
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);

        IDStakingOverview(stakingRoot.dstakingOverview()).onUndelegate(msg.sender, amount);
        emit Undelegate(msg.sender, amount);
    }

    /**
     * @notice claim rewards
     *
     */
    function claim() external override nonReentrant {
        _updatePool();
        _updateUserPendingRewards(msg.sender);
        processRewards(msg.sender);

        // last_accumulated_reward is expressed as rewardDebt
        UserInfo storage user = userInfo[msg.sender];
        user.rewardDebt = accumulativeRewards(user.amount, poolInfo.accTokenPerShare);
    }

    function safeTokenTransfer(address to, uint256 amount) internal returns (uint256) {
        if (amount > poolInfo.rewardsAmount) {
            token.safeTransfer(to, poolInfo.rewardsAmount);
            return poolInfo.rewardsAmount;
        } else {
            token.safeTransfer(to, amount);
            return amount;
        }
    }

    function getDelegatedAmount(address user) external view override returns (uint256) {
        return userInfo[user].amount;
    }

    function getTotalDelegatedAmount() external view override returns (uint256) {
        return poolInfo.delegatedAmount;
    }

    function withdrawAnyToken(
        address _token,
        uint256 amount,
        address beneficiary
    ) external override onlyRoot {
        IERC20(_token).safeTransfer(beneficiary, amount);
    }

    // This function is called per epoch by bot
    function claimRewardsFromRoot() external {
        stakingRoot.claimRewards();
    }

    function setCommissionRate(uint256 _commissionRate) external onlyOwner {
        require(block.timestamp - lastCommissionRateUpdateTimeStamp >= COMMION_UPDATE_MIN_DURATION, "Can't update");
        require(_commissionRate <= COMMION_RATE_MAX, "Too big commissionRate");
        commissionRate = _commissionRate;

        emit CommissionRateUpdated(commissionRate);
    }

    function claimCommissionRewards() external onlyOwner nonReentrant {
        uint256 claimedAmount = safeTokenTransfer(msg.sender, commissionReward);

        commissionReward -= claimedAmount;
        totalReleased += claimedAmount;
        poolInfo.rewardsAmount -= claimedAmount;

        emit CommissionRewardClaimed(claimedAmount);
    }
}
