// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AFTToken is ERC20 {
    constructor() ERC20("Arable Kingdom Token", "AFT") {
        _mint(msg.sender, 25000 ether);
    }
}
