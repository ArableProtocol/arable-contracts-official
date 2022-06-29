// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../mvp_v1/interfaces/IArableExchange.sol";
import "../mvp_v1/interfaces/IArableOracle.sol";

contract MevTest {
    IArableExchange public exchange;
    IArableOracle public oracle;

    constructor(IArableExchange _exchange, IArableOracle _oracle) {
        exchange = _exchange;
        oracle = _oracle;
    }

    function resetContracts(IArableExchange _exchange, IArableOracle _oracle) external {
        exchange = _exchange;
        oracle = _oracle;
    }

    function tryMev(
        IERC20 inToken,
        uint256 inAmount,
        IERC20 outToken
    ) external {
        inToken.transferFrom(msg.sender, address(this), inAmount);

        inToken.approve(address(exchange), inAmount);

        // buy outToken
        exchange.swapSynths(address(inToken), inAmount, address(outToken));

        // increase outToken price 1.2x
        uint256 originPrice = oracle.getPrice(address(outToken));
        oracle.registerPrice(address(outToken), (originPrice * 12) / 10);

        // sell outToken
        uint256 outAmount = outToken.balanceOf(address(this));
        outToken.approve(address(exchange), outAmount);
        exchange.swapSynths(address(outToken), outAmount, address(inToken));

        uint256 finalAmount = inToken.balanceOf(address(this));

        oracle.registerPrice(address(outToken), originPrice);

        inToken.transfer(msg.sender, finalAmount);
    }
}
