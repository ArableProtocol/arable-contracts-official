// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ArableToken is ERC20, Ownable {
    mapping(address => bool) public isBlacklisted;

    constructor() ERC20("Arable Protocol", "ACRE") {
        _mint(msg.sender, 1000000000 ether); // 1 billion
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(!isBlacklisted[from], "Sender is blacklisted");
        require(!isBlacklisted[to], "Recipient is blacklisted");
        super._beforeTokenTransfer(from, to, amount);
    }

    function setBlacklist(address addr, bool blacklist) external onlyOwner {
        isBlacklisted[addr] = blacklist;
    }
}
