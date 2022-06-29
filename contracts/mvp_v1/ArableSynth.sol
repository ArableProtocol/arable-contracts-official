// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Generalized ERC20 token contract for synths
// Tokens are mintable by staking or exchange contract
contract ArableSynth is ERC20, AccessControl, ReentrancyGuard, Pausable {
    // Define roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public totalSupplyLimit = 2**256 - 1;

    event Pause();
    event Unpause();

    constructor(
        string memory name_,
        string memory symbol_,
        address owner,
        address farming_,
        address exchange_,
        address collateral_
    ) ERC20(name_, symbol_) {
        // grant permission on owner to add more admins
        _setupRole(DEFAULT_ADMIN_ROLE, owner);

        // provide minter role for staking and exchange contract
        _setupRole(MINTER_ROLE, farming_);
        _setupRole(MINTER_ROLE, exchange_);
        _setupRole(MINTER_ROLE, collateral_);

        // Note: decimals is set to 18 as default
        // TODO: probably later time, just keep address of manager contract and get the addresses from there since it
        // could be changed?
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        _unpause();
        emit Unpause();
    }

    function setTotalSupplyLimit(uint256 _limit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        totalSupplyLimit = _limit;
    }

    function mint(address toAddress, uint256 amount) public onlyRole(MINTER_ROLE) whenNotPaused {
        require(totalSupply() + amount <= totalSupplyLimit, "Supply Limitation is reached");
        _mint(toAddress, amount);
    }

    function safeMint(address toAddress, uint256 amount) public onlyRole(MINTER_ROLE) whenNotPaused returns (uint256) {
        uint256 remaining = totalSupplyLimit - totalSupply();

        if (remaining > amount) {
            _mint(toAddress, amount);
            return amount;
        } else {
            _mint(toAddress, remaining);
            return remaining;
        }
    }

    function burn(uint256 amount) public whenNotPaused {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) public whenNotPaused {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        unchecked {
            _approve(account, _msgSender(), currentAllowance - amount);
        }
        _burn(account, amount);
    }
}
