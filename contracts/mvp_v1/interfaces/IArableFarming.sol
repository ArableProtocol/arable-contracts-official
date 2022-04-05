// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IArableFarming {
    function isRewardToken(uint256 farmId, address rewardToken) external view returns (bool);
    function getRewardTokens(uint256 farmId) external view returns (address[] memory);
    function currentEpoch() external view returns (uint256);
    function updateRewardRateSum(uint256 farmId, address rewardToken) external;
    function registerFarm(address stakingToken) external returns (uint256);
    function setRewardTokens(uint256 farmId, address[] memory _rewardTokens) external;
    function deleteRewardTokens(uint256 farmId) external;
    function setIsDisabledFarm(uint256 farmId, bool isDisabled) external;
    function stake(uint256 farmId, uint256 amount) external;
    function unstake(uint256 farmId, uint256 amount) external;
    function claimReward(uint256 farmId, address rewardToken) external;
    function claimAllRewards(uint256 farmId) external;
    function estimatedReward(uint256 farmId, address rewardToken, address user) external view returns (uint256);
}
