// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OTC is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 acreAmount; // agreed ACRE amount
        uint256 usdtAmount; // funded USDT amount
        uint256 expiry; // timestamp that funder must buy before
        uint256 fundedDate; // last buy timestamp
        uint256 unlockDate; // timestamp that token releases
        bool unlocked; //
    }

    IERC20 public fundToken; // USDT
    IERC20 public acre;
    mapping(address => UserInfo) public userInfo;

    event DealAgreed(address funder, uint256 acreAmount, uint256 usdtAmount, uint256 expiry, uint256 unlockDate);
    event Funded(address funder, uint256 acreAmount, uint256 usdtAmount);
    event Released(address funder, uint256 acreAmount);
    event DealCancelled(address funder);

    constructor(IERC20 _fundToken, IERC20 _acre) {
        require(address(_fundToken) != address(0), "Invalid fundToken");
        require(address(_acre) != address(0), "Invalid acre Token");

        fundToken = _fundToken;
        acre = _acre;
    }

    function setUserDeal(
        address funder,
        uint256 acreAmount, // acre amount
        uint256 usdtAmount, // usdt amount
        uint256 expiry,
        uint256 unlockDate
    ) external onlyOwner {
        require(funder != address(0), "Invalid funder");
        require(acreAmount > 0, "Invalid acreAmount");
        require(usdtAmount > 0, "Invalid usdtAmount");
        require(expiry >= block.timestamp, "Invalid expiry");
        require(unlockDate >= block.timestamp, "Invalid unlockDate");
        require(userInfo[funder].fundedDate == 0, "Already funded");

        acre.safeTransferFrom(msg.sender, address(this), acreAmount);

        userInfo[funder] = UserInfo({
            acreAmount: acreAmount,
            usdtAmount: usdtAmount,
            expiry: expiry,
            fundedDate: 0,
            unlockDate: unlockDate,
            unlocked: false
        });

        emit DealAgreed(funder, acreAmount, usdtAmount, expiry, unlockDate);
    }

    function cancelDeal(address funder) external onlyOwner {
        UserInfo storage user = userInfo[funder];

        require(user.fundedDate == 0, "Already funded");
        require(user.acreAmount > 0, "Not agreed");

        acre.safeTransfer(msg.sender, user.acreAmount);

        user.acreAmount = 0;
        user.usdtAmount = 0;
        user.expiry = 0;

        emit DealCancelled(funder);
    }

    function buyDeal() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        require(user.acreAmount > 0, "Not agreed");
        require(user.fundedDate == 0, "Already funded");
        // check expire
        require(user.expiry >= block.timestamp, "Expired");

        fundToken.safeTransferFrom(msg.sender, address(this), user.usdtAmount);
        //
        user.fundedDate = block.timestamp;

        emit Funded(msg.sender, user.acreAmount, user.usdtAmount);
    }

    function releaseAcre() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        require(user.acreAmount > 0, "Not agreed");
        require(user.fundedDate > 0 || user.usdtAmount == 0, "Not funded");
        require(user.unlockDate <= block.timestamp, "Not unlocked yet");
        require(!user.unlocked, "Already released");

        acre.safeTransfer(msg.sender, user.acreAmount);

        user.unlocked = true;

        emit Released(msg.sender, user.acreAmount);
    }

    function releaseUsdt() external onlyOwner {
        uint256 balance = fundToken.balanceOf(address(this));
        fundToken.safeTransfer(msg.sender, balance);
    }

    function withdrawAnyToken(IERC20 _token, uint256 _amount) external onlyOwner {
        _token.safeTransfer(msg.sender, _amount);
    }
}
