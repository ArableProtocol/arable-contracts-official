// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../common/ArableAccessControl.sol";
import "../interfaces/staking/IStakingRoot.sol";
import "../interfaces/staking/IDStaking.sol";
import "../interfaces/staking/IStaking.sol";
import "../interfaces/common/IArableAccessControl.sol";
import "./DStaking.sol";

/** @title StakingRoot
 * @notice Contract that manages delegated staking and staking contracts along with reward distributions
 */
contract StakingRoot is ArableAccessControl, IStakingRoot {
    using SafeERC20 for IERC20;

    struct RewardsInfo {
        address addr;
        uint256 rewardsAmount;
    }

    address public override dstakingOverview;
    address public override tokenLocker;
    IERC20 public token;

    // address: dStakingCreator
    mapping(address => bool) public isDStakingCreationAllowed;
    mapping(address => bool) public dStakingCreated;

    address public override staking; // staking contract address
    RewardsInfo public stakingInfo; // delegated staking contract address
    mapping(address => bool) public override isDStaking; // store delegated staking addresses
    mapping(address => bool) public override isDStakingRemoved; // store removed delegated staking addresses
    RewardsInfo[] public dStakingRewardInfos; // store delegated staking rewards info
    mapping(address => address) public override dStakingCreators; // mapping between validator and validator owner
    mapping(address => uint256) public dStakingIndex; // index of a validator

    address[] public removedDStakings; // removed validators

    uint256 public override minTokenAmountForDStaker; // minimum amount for self delegation
    uint256 public dStakingCount; // available validators count

    uint256 public totalDistributed;
    uint256 public totalReleased;

    uint256 public stakingMultiplier; // reward multipler compared to delegated staking - default 0.5
    uint256 public constant BASE_MULTIPLIER = 1e2;

    uint256 public constant DSTAKING_LIMIT = 50; // validator count limitation

    event DStakingRegistered(address creator, address dStaking, uint256 commissionRate);
    event DStakingRemoved(address dStaking);
    event StakingRewardsClaimed(address beneficiary, uint256 amount);
    event DStakingRewardsClaimed(address beneficiary, uint256 amount);

    modifier onlyStakingOrDStaking(address addr) {
        require(staking == addr || isDStaking[addr], "Not staking or dStaking");

        _;
    }

    modifier onlyDStakingCreator(address dStaking, address addr) {
        require(dStakingCreators[dStaking] == addr, "Not DStaking owner");
        _;
    }

    function initialize(IERC20 _token) external initializer {
        super.__ArableAccessControl_init_unchained();

        require(address(_token) != address(0), "Invalid token");
        token = _token;
        stakingMultiplier = 50;
    }

    function getRemovedDStakingCount() external view returns (uint256) {
        return removedDStakings.length;
    }

    function getRewardsInfo(address dStaking) public view returns (RewardsInfo memory) {
        return dStakingRewardInfos[dStakingIndex[dStaking]];
    }

    function registerDStaking(uint256 amount, uint256 commissionRate) external {
        require(amount >= minTokenAmountForDStaker, "Low amount!");
        require(isDStakingCreationAllowed[msg.sender], "Not allowed to register DStaking");
        require(dStakingCount < DSTAKING_LIMIT, "Limit");
        require(!dStakingCreated[msg.sender], "Already created");

        DStaking dStaking = new DStaking(token, this, commissionRate);

        address dStakingAddr = address(dStaking);

        isDStaking[dStakingAddr] = true;
        dStakingCreators[dStakingAddr] = msg.sender;
        dStakingIndex[dStakingAddr] = dStakingCount;

        IArableAccessControl(dstakingOverview).setOperator(dStakingAddr, true);

        token.safeTransferFrom(msg.sender, address(this), amount);
        token.approve(dStakingAddr, amount);
        dStaking.initDeposit(address(this), msg.sender, amount);

        dStakingRewardInfos.push(RewardsInfo({ addr: dStakingAddr, rewardsAmount: 0 }));

        dStakingCount++;

        dStaking.transferOwnership(msg.sender);

        dStakingCreated[msg.sender] = true;

        emit DStakingRegistered(msg.sender, dStakingAddr, commissionRate);
    }

    function removeDStaking(address dStaking) external onlyDStakingCreator(dStaking, msg.sender) {
        _distributeRewards();

        RewardsInfo memory info = getRewardsInfo(dStaking);
        uint256 curIndex = dStakingIndex[dStaking];

        if (info.rewardsAmount > 0) {
            uint256 claimedAmount = safeTokenTransfer(dStaking, info.rewardsAmount);
            emit DStakingRewardsClaimed(msg.sender, claimedAmount);
            totalReleased += claimedAmount;
        }

        isDStakingRemoved[dStaking] = true;

        if (curIndex == dStakingCount - 1) {
            delete dStakingRewardInfos[curIndex];
            dStakingCount--;
            delete dStakingIndex[dStaking];
        } else {
            dStakingCount--;
            dStakingRewardInfos[curIndex].addr = dStakingRewardInfos[dStakingCount].addr;
            dStakingRewardInfos[curIndex].rewardsAmount = dStakingRewardInfos[dStakingCount].rewardsAmount;
            delete dStakingRewardInfos[dStakingCount];
            dStakingIndex[dStakingRewardInfos[curIndex].addr] = curIndex;
            delete dStakingIndex[dStaking];
        }

        removedDStakings.push(dStaking);

        emit DStakingRemoved(dStaking);
    }

    function _distributeRewards() private {
        // (totalDistributed - totalReleased) is the sum of members' pending amounts
        uint256 pendingRewards = IERC20(token).balanceOf(address(this)) + totalReleased - totalDistributed;

        if (pendingRewards > 0) {
            uint256 totalAllocation = 0;
            for (uint256 index = 0; index < dStakingCount; index++) {
                totalAllocation += IDStaking(dStakingRewardInfos[index].addr).getTotalDelegatedAmount();
            }

            uint256 stakingAllocation = (IStaking(staking).getTotalDepositAmount() * stakingMultiplier) /
                BASE_MULTIPLIER;
            totalAllocation += stakingAllocation;

            if (totalAllocation > 0) {
                for (uint256 index = 0; index < dStakingCount; index++) {
                    uint256 dstaked = IDStaking(dStakingRewardInfos[index].addr).getTotalDelegatedAmount();
                    uint256 newRewards = (pendingRewards * dstaked) / totalAllocation;
                    dStakingRewardInfos[index].rewardsAmount += newRewards;
                    totalDistributed += newRewards;
                }

                uint256 stakingRewards = (pendingRewards * stakingAllocation) / totalAllocation;

                stakingInfo.rewardsAmount += stakingRewards;
                totalDistributed += stakingRewards;
            }
        }
    }

    function distributeRewards() external {
        _distributeRewards();
    }

    function claimRewards() external override onlyStakingOrDStaking(msg.sender) {
        if (msg.sender == staking) {
            // staking rewards claim
            uint256 rewards = stakingInfo.rewardsAmount;
            if (rewards > 0) {
                uint256 claimedAmount = safeTokenTransfer(msg.sender, rewards);
                stakingInfo.rewardsAmount = stakingInfo.rewardsAmount - claimedAmount;

                totalReleased += claimedAmount;

                emit StakingRewardsClaimed(msg.sender, claimedAmount);
            }
        } else {
            // dstaking rewards claim
            uint256 rewards = getRewardsInfo(msg.sender).rewardsAmount;

            if (rewards > 0) {
                uint256 claimedAmount = safeTokenTransfer(msg.sender, rewards);

                dStakingRewardInfos[dStakingIndex[msg.sender]].rewardsAmount -= claimedAmount;

                totalReleased += claimedAmount;

                emit DStakingRewardsClaimed(msg.sender, claimedAmount);
            }
        }
    }

    function safeTokenTransfer(address to, uint256 amount) internal returns (uint256) {
        uint256 bal = token.balanceOf(address(this));

        if (bal >= amount) {
            token.safeTransfer(to, amount);
            return amount;
        } else {
            token.safeTransfer(to, bal);
            return bal;
        }
    }

    function setStaking(address _staking) external onlyOwner {
        require(_staking != address(0), "Invalid staking address");
        staking = _staking;
        stakingInfo.addr = _staking;
    }

    function setDStakingOverview(address _dstakingOverview) external onlyOwner {
        require(_dstakingOverview != address(0), "Invalid");
        dstakingOverview = _dstakingOverview;
    }

    function setTokenLocker(address _tokenLocker) external onlyOwner {
        require(_tokenLocker != address(0), "Invalid");
        tokenLocker = _tokenLocker;
    }

    function setStakingMultiplier(uint256 _multiplier) external onlyOwner {
        require(_multiplier < BASE_MULTIPLIER, "Invalid");
        stakingMultiplier = _multiplier;
    }

    function setMinTokenAmountForDStaking(uint256 _minTokenAmountForDStaker) external onlyOwner {
        minTokenAmountForDStaker = _minTokenAmountForDStaker;
    }

    function withdrawTokenFromStaking(
        address _staking,
        uint256 amount,
        address beneficiary
    ) external onlyOwner {
        require(beneficiary != address(0), "Invalid beneficiary");
        IStaking(_staking).withdrawAnyToken(address(token), amount, beneficiary);
    }

    function setDStakingCreationAllowed(address creator, bool allowed) external onlyOwner {
        isDStakingCreationAllowed[creator] = allowed;
    }
}
