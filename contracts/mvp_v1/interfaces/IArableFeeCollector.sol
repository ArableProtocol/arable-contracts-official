// interfaces/IArableFeeCollector.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libs/ArableFees.sol"; 

interface IArableFeeCollector {
    function calculateFees(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) external view returns (uint256 fees);

    function setAssetFeeModel(
        address asset_,
        uint256 fees_,
        ArableFees.Model model_
    ) external;

    function payFeesFor(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) external returns (uint256[] memory collectorReceipt);

    function setRewardTokens(address[] memory _rewardTokens) external;

    function deleteRewardTokens() external;

    function startNewEpoch() external;

    function increaseMinterRewards(address minter, address rewardToken, uint256 amount) external;

    function bulkIncreaseMinterRewards(
        address rewardToken,
        address[] calldata minters,
        uint256[] calldata amounts
    ) external;

    function claimReward(address rewardToken) external;

    function estimatedReward(address minter, address rewardToken) external view returns (uint256);

    function getTotalDistributableRewards(address rewardToken) external view  returns (uint256);
}
