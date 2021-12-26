// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Farming.sol";
import "../interfaces/staking/ITokenLocker.sol";
import "../interfaces/staking/IFarmingFactory.sol";

/** @title FarmingFactory
 *
 * @notice Contract that creates farming contracts
 * A single farming contract includes multiple pools and a farm is created per reward token
 * The farms are sharing locking contract for tokens for unstaking
 *
 */
contract FarmingFactory is Ownable, IFarmingFactory {
    address public override tokenLocker;

    address[] public farmings;
    mapping(address => bool) public isFarming;

    event FarmingDeployed(address owner, address farming);

    constructor(address _locker) {
        require(_locker != address(0), "Invalid locker address!");

        tokenLocker = _locker;
    }

    function deployNewFarming(address token) external onlyOwner {
        Farming farming = new Farming(this, token);

        farming.transferOwnership(msg.sender);

        farmings.push(address(farming));
        isFarming[address(farming)] = true;

        emit FarmingDeployed(msg.sender, address(farming));
    }

    function setLocker(address _locker) external onlyOwner {
        require(_locker != address(0), "Invalid locker address!");

        tokenLocker = _locker;
    }
}
