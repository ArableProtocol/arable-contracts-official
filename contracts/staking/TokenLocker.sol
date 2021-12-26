// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/staking/ITokenLocker.sol";

/** @title TokenLocker
 * @notice Contract to release tokens after a specific duration
 */
contract TokenLocker is ITokenLocker, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockInfo {
        IERC20 token;
        address locker;
        address beneficiary;
        uint256 amount;
        uint256 startTime;
        uint256 unlockTime;
        bool released;
    }

    mapping(address => uint256[]) public userLockIds; // beneficiary => lockIds
    LockInfo[] public locks;

    uint256 public lockSize;

    event TokenLocked(
        address indexed token,
        address locker,
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 unlockTime,
        uint256 lockId
    );
    event TokenReleased(address indexed token, address beneficiary, uint256 lockId, uint256 amount);

    function lockToken(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 unlockTime
    ) external override {
        require(address(token) != address(0), "Invalid token");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Invalid amount");
        require(block.timestamp < unlockTime, "Invalid unlockTime");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        locks.push(
            LockInfo({
                token: IERC20(token),
                locker: msg.sender,
                beneficiary: beneficiary,
                amount: amount,
                startTime: block.timestamp,
                unlockTime: unlockTime,
                released: false
            })
        );

        userLockIds[beneficiary].push(lockSize);

        emit TokenLocked(address(token), msg.sender, beneficiary, amount, block.timestamp, unlockTime, lockSize);

        lockSize++;
    }

    function getLockCounts(address beneficiary) external view returns (uint256) {
        return userLockIds[beneficiary].length;
    }

    function getLockInfoOfUser(address beneficiary, uint256 lockIndex) external view returns (LockInfo memory) {
        uint256 lockId = userLockIds[beneficiary][lockIndex];
        return locks[lockId];
    }

    function _relaseLock(address beneficiary, uint256 _lockId) private {
        require(_lockId < lockSize, "Invalid lockId");
        require(locks[_lockId].beneficiary == beneficiary, "Incorrect beneficiary");
        require(block.timestamp >= locks[_lockId].unlockTime, "Not released yet");
        require(!locks[_lockId].released, "Already released");

        locks[_lockId].token.safeTransfer(beneficiary, locks[_lockId].amount);

        locks[_lockId].released = true;

        emit TokenReleased(address(locks[_lockId].token), beneficiary, _lockId, locks[_lockId].amount);
    }

    function releaseLock(uint256 lockId) external nonReentrant {
        _relaseLock(msg.sender, lockId);
    }

    function releaseLockTo(address beneficiary, uint256 lockId) external nonReentrant {
        _relaseLock(beneficiary, lockId);
    }
}
