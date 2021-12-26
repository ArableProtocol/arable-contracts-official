// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDStakingOverview {
    function userDelegated(address) external view returns (uint256);

    function onDelegate(address, uint256) external;

    function onUndelegate(address, uint256) external;
}
