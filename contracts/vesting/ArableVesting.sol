// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/** @title ArableVesting
 *
 * ACRE token is vested based on vesting schedule
 * The vesting amount is deduced per year by specific percentage
 * Release tokens are sent to RootDistributer contract regularly by a bot
 *
 */
contract ArableVesting is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public token; // ERC20 token address
    uint256 public totalAmount;
    uint256 public startAmount;

    uint256 public startTime;

    uint256 public constant ONE_YEAR = 365 days;

    uint256 public totalReleased;

    uint256 public divider;
    uint256 public numerator;

    address public beneficiary;

    event Pause();
    event Unpause();

    modifier IsInitialized() {
        require(startTime != 0, "Not inititialized yet");

        _;
    }

    function initialize(
        address _beneficiary,
        IERC20 _token,
        uint256 _totalAmount,
        uint256 _startAmount,
        uint256 _divider,
        uint256 _numerator
    ) external onlyOwner {
        require(startTime == 0, "Initialized already");

        require(_beneficiary != address(0), "Invalid beneficiary address");
        require(address(_token) != address(0), "Invalid token address");
        require(_startAmount > 0, "Invalid start amount");
        require(_startAmount < _totalAmount, "Too small total amount");
        require(_numerator > 0, "Invalid numerator");
        require(_numerator < _divider, "Divider is too small");

        beneficiary = _beneficiary;

        token = _token;
        totalAmount = _totalAmount;
        startAmount = _startAmount;

        divider = _divider;
        numerator = _numerator;

        startTime = block.timestamp;

        token.safeTransferFrom(msg.sender, address(this), totalAmount);
    }

    // This function is called per epoch by bot
    function release() external IsInitialized nonReentrant whenNotPaused {
        uint256 yearIndex = (block.timestamp - startTime) / ONE_YEAR;
        uint256 yearAmount = startAmount;

        // calculate past years amount - considering yearly deduction
        uint256 pastYearsAmount;
        for (uint256 index = 0; index < yearIndex; index++) {
            pastYearsAmount += yearAmount;
            yearAmount = (yearAmount * numerator) / divider;
        }

        // Ideally this case does not exist
        if (pastYearsAmount + yearAmount > totalAmount) {
            yearAmount = totalAmount - pastYearsAmount;
        }

        // current year's release amount from beginning to now
        uint256 currentYearAmount = (yearAmount * (block.timestamp - yearIndex * ONE_YEAR - startTime)) / ONE_YEAR;

        // releasable = past_years_amount + current_year_amount - already_released
        uint256 releasableAmount = pastYearsAmount + currentYearAmount - totalReleased;

        token.safeTransfer(beneficiary, releasableAmount);
        totalReleased += releasableAmount;
    }

    function withdrawAnyToken(IERC20 _token, uint256 amount) external onlyOwner {
        _token.safeTransfer(msg.sender, amount);
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
