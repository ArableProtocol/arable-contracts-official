// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Generalized ERC20 token contract for synths
// Tokens are mintable by staking or exchange contract
contract ArableSynth is ERC20, AccessControl, ReentrancyGuard {
    // Define roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(
        string memory name_,
        string memory symbol_,
        address owner, address farming_, address exchange_, address collateral_) ERC20(name_, symbol_) {

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

    function mint(address toAddress, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(toAddress, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
    
    function burnFrom(address account, uint256 amount) public {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        unchecked {
            _approve(account, _msgSender(), currentAllowance - amount);
        }
        _burn(account, amount);
    }
}
