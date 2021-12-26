// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/** @title ITokenLocker
 * @notice
 */

interface ITokenLocker {
    function lockToken(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 unlockTime
    ) external;
}
