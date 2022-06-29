// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILendPool {
    function flashRepay(IERC20 token, uint256 amount) external;

    function flashLoan(
        IERC20 token,
        uint256 amount,
        bytes calldata params
    ) external;
}

contract MockFlashLoanReceiver {
    IERC20 usd;

    function setUsd(IERC20 _usd) external {
        usd = _usd;
    }

    function executeOperation(uint256 amount, bytes calldata _params) external {
        // convert to 18 decimals amount
        uint256 newAmount = (amount * 10**(IERC20Metadata(address(usd)).decimals())) / 10**18;

        usd.approve(address(msg.sender), newAmount);

        ILendPool(msg.sender).flashRepay(usd, newAmount);
    }

    function testFlashLoan(
        ILendPool pool,
        IERC20 token,
        uint256 amount
    ) external {
        pool.flashLoan(token, amount, "");
    }
}
