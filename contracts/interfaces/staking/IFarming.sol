// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFarming {
    function getDepositAmount(address user, uint256 _pid) external view returns (uint256);
}
