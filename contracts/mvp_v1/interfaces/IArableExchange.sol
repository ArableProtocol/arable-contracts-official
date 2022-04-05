// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IArableExchange {
    function swapSynths(address inToken, uint256 inAmount, address outToken) external;
}