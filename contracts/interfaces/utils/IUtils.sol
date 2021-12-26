// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IUtils {
    function isContract(address addr) external view returns (bool);

    function isContracts(address[] calldata addrs) external view returns (bool[] memory);

    function getBalances(address token, address[] calldata addrs) external view returns (uint256[] memory);
}
