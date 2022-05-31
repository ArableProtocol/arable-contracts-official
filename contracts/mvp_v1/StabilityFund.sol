// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "hardhat/console.sol";

interface IFlashLoanReceiver {
    function executeOperation(uint256 amount, bytes calldata _params) external;
}

contract StabilityFund is Ownable, ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // usd when calculate ratio USD to LP
    uint256 private constant MULTIPLIER = 1e18;

    // flashloan users
    mapping(address => bool) public isFlashAllowed;
    // flashloan amount
    uint256 public flashLoanAmount;

    // stable coin info: usdc, usdt, arUsd
    mapping(IERC20 => bool) public isStableToken;
    mapping(IERC20 => bool) public isTokenDisabled;
    IERC20[] public stableTokens;

    uint256 private constant DEFAULT_DECIMALS = 18;

    // swap flag
    bool public swapEnabled;
    uint256 public swapFee;

    event StableTokenAdded(IERC20 token);
    event StableTokenRemoved(IERC20 token);
    event Deposit(address indexed user, IERC20 token, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawToken(address indexed user, IERC20 token, uint256 amount);
    event Swap(address indexed user, IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1);
    event FlashLoan(address indexed user, uint256 amount, bytes params, IERC20 token);

    event Pause();
    event Unpause();

    constructor() ERC20("StabilityFund", "SF-LP") {}

    function getStableTokens() external view returns (IERC20[] memory) {
        return stableTokens;
    }

    function getStableTokensCount() external view returns (uint256) {
        return stableTokens.length;
    }

    function getFundInfo()
        public
        view
        returns (
            IERC20[] memory,
            uint256[] memory,
            uint256
        )
    {
        uint256[] memory balances = new uint256[](stableTokens.length);
        for (uint256 index = 0; index < stableTokens.length; index++) {
            balances[index] = stableTokens[index].balanceOf(address(this));
        }

        return (stableTokens, balances, totalSupply());
    }

    /**
     * @notice get usd amount of all tokens on the contract
     */
    function getTotalAmount() public view returns (uint256) {
        uint256 total;

        for (uint256 index = 0; index < stableTokens.length; index++) {
            IERC20 token = stableTokens[index];
            total +=
                token.balanceOf(address(this)) *
                10**(DEFAULT_DECIMALS - IERC20Metadata(address(token)).decimals());
        }

        return total;
    }

    /**
     * @notice get ratio between usd and lpSupply
     */
    function getRatio()
        public
        view
        returns (
            uint256 usd,
            uint256 lpSupply,
            uint256 ratio
        )
    {
        usd = getTotalAmount();
        lpSupply = totalSupply();
        ratio = (usd * MULTIPLIER) / lpSupply;
    }

    function getUsdOfLp(uint256 lpAmount) public view returns (uint256) {
        (uint256 usd, uint256 lpSupply, ) = getRatio();

        return (lpAmount * usd) / lpSupply;
    }

    /**
     * @notice add stable coin
     */
    function addStableToken(IERC20 token) external onlyOwner {
        require(address(token) != address(0), "Invalid token");
        require(IERC20Metadata(address(token)).decimals() <= DEFAULT_DECIMALS, "Invalid token decimals");

        require(!isStableToken[token], "Already added");

        isStableToken[token] = true;
        stableTokens.push(token);

        emit StableTokenAdded(token);
    }

    /**
     * @notice remove stable coin
     */
    function removeStableToken(IERC20 token) external onlyOwner {
        require(isStableToken[token], "Not exist");
        require(token.balanceOf(address(this)) == 0, "Can't remove");

        uint256 index = 0;
        for (; index < stableTokens.length; index++) {
            if (stableTokens[index] == token) {
                break;
            }
        }

        if (index != stableTokens.length) {
            stableTokens[index] = stableTokens[stableTokens.length - 1];
        }

        stableTokens.pop();
        isStableToken[token] = false;

        emit StableTokenRemoved(token);
    }

    function setTokenDisabled(IERC20 token, bool disabled) external onlyOwner {
        require(isStableToken[token], "Not exist");
        isTokenDisabled[token] = disabled;
    }

    function setSwapFee(uint256 _fee) external onlyOwner {
        require(_fee < MULTIPLIER, "Invalid fee");

        swapFee = _fee;
    }

    function setSwapEnabled(bool _swapEnabled) external onlyOwner {
        swapEnabled = _swapEnabled;
    }

    function setFlashAllowed(address addr, bool allowed) external onlyOwner {
        isFlashAllowed[addr] = allowed;
    }

    function deposit(IERC20 token, uint256 amount) external whenNotPaused {
        require(isStableToken[token], "Not stable token");
        require(!isTokenDisabled[token], "Deposit is disabled");

        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 lpAmount = amount * 10**(DEFAULT_DECIMALS - IERC20Metadata(address(token)).decimals());

        _mint(msg.sender, lpAmount);

        emit Deposit(msg.sender, token, amount);
    }

    /**
     */
    function withdraw(uint256 amount) external whenNotPaused {
        require(amount <= balanceOf(msg.sender), "Insufficient balance");

        _withdraw(amount);
    }

    function withdrawAll() external whenNotPaused {
        uint256 amount = balanceOf(msg.sender);

        _withdraw(amount);
    }

    function _withdraw(uint256 amount) private {
        (uint256 totalUsd, uint256 totalLP, ) = getRatio();

        console.log("total usd: %s - totalLP: %s", totalUsd, totalLP);

        for (uint256 index = 0; index < stableTokens.length; index++) {
            IERC20 token = stableTokens[index];

            uint256 tAmount = (token.balanceOf(address(this)) * amount) / totalLP;

            console.log("%s -  - %s", address(token), tAmount);

            if (amount > 0) {
                token.safeTransfer(msg.sender, tAmount);

                emit WithdrawToken(msg.sender, token, tAmount);
            }
        }

        _burn(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    function swap(
        IERC20 token0,
        uint256 amount,
        IERC20 token1
    ) external nonReentrant whenNotPaused {
        require(swapEnabled, "Swap Disabled");
        require(isStableToken[token0] && isStableToken[token1], "Invalid tokens");
        require(!isTokenDisabled[token0] && !isTokenDisabled[token1], "Token is disabled");

        token0.safeTransferFrom(msg.sender, address(this), amount);

        uint256 usdAmount = amount * 10**(DEFAULT_DECIMALS - IERC20Metadata(address(token0)).decimals());
        uint256 feeAmount = (usdAmount * swapFee) / MULTIPLIER;
        uint256 amountToSend = (usdAmount - feeAmount) /
            10**(DEFAULT_DECIMALS - IERC20Metadata(address(token1)).decimals());

        token1.safeTransfer(msg.sender, amountToSend);

        emit Swap(msg.sender, token0, amount, token1, amountToSend);
    }

    function flashRepay(IERC20 token, uint256 amount) external whenNotPaused {
        require(isFlashAllowed[msg.sender], "flashRepay not allowed");
        require(isStableToken[token], "Not valid stable token");
        require(!isTokenDisabled[token], "Token disabled");

        uint256 newAmount = (amount * 10**DEFAULT_DECIMALS) / 10**(IERC20Metadata(address(token)).decimals());

        require(flashLoanAmount <= newAmount, "should repay full amount at once");

        token.safeTransferFrom(msg.sender, address(this), amount);
        flashLoanAmount = 0;
    }

    function flashLoan(
        IERC20 token,
        uint256 amount,
        bytes calldata params
    ) external nonReentrant whenNotPaused {
        require(isStableToken[token], "Not valid stable token");
        require(isFlashAllowed[msg.sender], "Flashloan not allowed");
        require(!isTokenDisabled[token], "Token disabled");

        token.safeTransfer(msg.sender, amount);

        // convert to 18 decimals amount
        uint256 newAmount = (amount * 10**DEFAULT_DECIMALS) / 10**(IERC20Metadata(address(token)).decimals());
        flashLoanAmount = newAmount;

        IFlashLoanReceiver(msg.sender).executeOperation(newAmount, params);

        require(flashLoanAmount == 0, "should repay within the block");

        emit FlashLoan(msg.sender, amount, params, token);
    }

    function recoverWrongToken(IERC20 token) external onlyOwner {
        require(!isStableToken[token], "Not wrong token");
        uint256 bal = token.balanceOf(address(this));

        token.safeTransfer(msg.sender, bal);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpause();
    }
}
