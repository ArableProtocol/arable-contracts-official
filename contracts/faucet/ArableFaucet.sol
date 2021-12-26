// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/** @title ArableFaucet
 *
 * Multi-token faucet contract used for testing of application on testnet
 * Can give faucet for native token and ERC20 tokens
 *
 */
contract ArableFaucet is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public faucetAmount; // amount of tokens per faucet
    uint256 public faucetPeriod; // duration to ask for new faucet
    mapping(address => bool) public allowedTokens; // set allowed tokens for faucet
    mapping(address => uint256) public lastWithdrawTime; // last withdraw time set per address

    event FaucetRequested(address indexed addr, address token);

    constructor(uint256 _faucetAmount, uint256 _faucetPeriod) {
        faucetAmount = _faucetAmount;
        faucetPeriod = _faucetPeriod;
    }

    function editFaucetInfo(uint256 _faucetAmount, uint256 _faucetPeriod) external onlyOwner {
        faucetAmount = _faucetAmount;
        faucetPeriod = _faucetPeriod;
    }

    function requestFaucet(address token) external {
        require(lastWithdrawTime[msg.sender] + faucetPeriod < block.timestamp, "Need to wait for faucet period!");

        if (token == address(0x0)) {
            (bool success, ) = payable(address(this)).call{ value: faucetAmount }("");
            require(success, "Native token faucet failed");
        } else {
            lastWithdrawTime[msg.sender] = block.timestamp;
            IERC20(token).safeTransfer(msg.sender, faucetAmount);
        }
        emit FaucetRequested(msg.sender, token);
    }

    function addAllowedToken(address token) external onlyOwner {
        allowedTokens[token] = true;
    }

    function removeAllowedToken(address token) external onlyOwner {
        allowedTokens[token] = false;
    }

    function withdrawToken(address token) external onlyOwner {
        if (token == address(0)) {
            uint256 balance = address(this).balance;
            payable(msg.sender).call{ value: balance }("");
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }

    receive() external payable {}
}
