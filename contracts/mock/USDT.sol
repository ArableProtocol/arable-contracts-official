// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract USDT is ERC20, Ownable {
    constructor() ERC20("USDT", "Test USDT") {}

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    function decimals() public view override returns (uint8) {
        return 6;
    }
}
