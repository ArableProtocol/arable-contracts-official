// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IArableAccessControl {
    function setOperator(address operator, bool set) external;

    function setManager(address manager, bool set) external;
}
