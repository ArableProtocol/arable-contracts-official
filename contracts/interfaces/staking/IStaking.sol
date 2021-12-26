// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStaking {
    function getDepositAmount(address user) external view returns (uint256);

    function getTotalDepositAmount() external view returns (uint256);

    function withdrawAnyToken(
        address _token,
        uint256 amount,
        address beneficiary
    ) external;

    function claim() external;

    function requestWithdraw(uint256 amount, bool _withdrawRewards) external;

    function deposit(uint256 amount) external;

    function pendingRewards(address _user) external view returns (uint256);
}
