// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/common/IArableAccessControl.sol";

/** @title ArableAccessControl
 * @notice
 * Owner set managers
 * Manager set operators
 * Owner -> Manager -> Operator
 */

contract ArableAccessControl is Initializable, OwnableUpgradeable, IArableAccessControl {
    mapping(address => bool) public isManager;
    mapping(address => bool) public isOperator;

    event ManagerSet(address indexed user, bool set);
    event OperatorSet(address indexed user, bool set);

    function __ArableAccessControl_init_unchained() public initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == owner() || isOperator[msg.sender], "Not operator or owner");

        _;
    }

    modifier onlyOperator() {
        require(isOperator[msg.sender], "Not operator");

        _;
    }

    modifier onlyManagerOrOwner() {
        require(msg.sender == owner() || isManager[msg.sender], "Not manager or owner");

        _;
    }

    function setManager(address manager, bool set) external override onlyOwner {
        isManager[manager] = set;

        emit ManagerSet(manager, set);
    }

    function setOperator(address operator, bool set) external override onlyManagerOrOwner {
        isOperator[operator] = set;

        emit OperatorSet(operator, set);
    }
}
