// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDStaking {
    function getTotalDelegatedAmount() external view returns (uint256);

    function getDelegatedAmount(address user) external view returns (uint256);

    function withdrawAnyToken(
        address _token,
        uint256 amount,
        address beneficiary
    ) external;

    function claim() external;

    function undelegate(uint256 amount) external;

    function delegateFor(address beneficiary, uint256 amount) external;

    function delegate(uint256 amount) external;

    function redelegate(address toDStaking, uint256 amount) external;

    function pendingRewards(address _user) external view returns (uint256);

    function initDeposit(
        address creator,
        address beneficiary,
        uint256 amount
    ) external;

    function updatePoolDuration(uint256 _lockupDuration) external;
}
