// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestTToken is ERC20 {
    constructor() ERC20("TestTToken", "TTTN") {
        _mint(msg.sender, 1000000000 ether);
    }

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    function decimals() public view override returns (uint8) {
        return 20;
    }
}
