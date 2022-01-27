// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStakingRoot {
    function dstakingOverview() external view returns (address);

    function tokenLocker() external view returns (address);

    function staking() external view returns (address);

    function redelegationAttemptPeriod() external view returns (uint256);

    function isRedelegationDisabled() external view returns (bool);

    function isDStaking(address) external view returns (bool);

    function isDStakingRemoved(address) external view returns (bool);

    function dStakingCreators(address) external view returns (address);

    function claimRewards() external;

    function minTokenAmountForDStaker() external view returns (uint256);
}
