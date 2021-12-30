// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/staking/IFarming.sol";
import "../interfaces/staking/IStaking.sol";
import "../interfaces/staking/IDStakingOverview.sol";

/**
 * @title ArableAirdrop
 *
 * This contract is for giving airdrop based on the information put on the database
 * The basic amount is given by bot and at that time, each user's allocation is determined
 * After that users who perform required actions to get further allocation can claim more airdrops
 *
 */
contract ArableAirDrop is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 basic; // 10%
        uint256 init; // 20%
        uint256 farm; // 30%
        uint256 stake; // 40%
    }

    mapping(address => UserInfo) public users;

    IERC20 public token; // ERC20 token address
    uint256 public endTime; // airdrop end time
    IFarming public farm; // liquidity mining contract
    IStaking public staking; // general staking contract
    IDStakingOverview public dstakingOverview; // contract that stores the overview of delegated stakings

    /**
     * mode: 0 => basic
     * mode: 1 => init
     * mode: 2 => farm
     * mode: 3 => stake
     */
    event AirDropped(address indexed addr, uint256 amount, uint256 mode);

    modifier canClaimAirDrop() {
        require(block.timestamp <= endTime, "Already ended");
        require(users[msg.sender].basic > 0, "No amount airdropped");
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _endTime,
        IFarming _farm,
        IStaking _staking,
        IDStakingOverview _dstakingOverview
    ) {
        require(address(_token) != address(0), "Invalid token");
        require(address(_farm) != address(0), "Invalid _farm");
        require(address(_staking) != address(0), "Invalid _staking");
        require(address(_dstakingOverview) != address(0), "Invalid _dstakingOverview");
        require(_endTime > block.timestamp, "Invalid _endTime");

        token = _token;
        endTime = _endTime;

        farm = _farm;
        staking = _staking;
        dstakingOverview = _dstakingOverview;
    }

    /**
     *  function to claim bonus airdrop for more interest on the project when join
     */
    function claimInit() external canClaimAirDrop {
        require(users[msg.sender].init == 0, "Already claimed");
        uint256 amount = users[msg.sender].basic * 2;
        users[msg.sender].init = amount;
        token.safeTransfer(msg.sender, amount);
        emit AirDropped(msg.sender, amount, 1);
    }

    /**
     *  function to claim bonus airdrop for putting the token on liquidity mining contract
     */
    function claimFarm() external canClaimAirDrop {
        require(farm.getDepositAmount(msg.sender, 0) > 0, "Not delegated on farm");
        require(users[msg.sender].farm == 0, "Already claimed");
        uint256 amount = users[msg.sender].basic * 3;
        users[msg.sender].farm = amount;
        token.safeTransfer(msg.sender, amount);
        emit AirDropped(msg.sender, amount, 2);
    }

    /**
     *  function to claim bonus airdrop for staking the token on the contract
     */
    function claimStake() external canClaimAirDrop {
        require(
            staking.getDepositAmount(msg.sender) > 0 || dstakingOverview.userDelegated(msg.sender) > 0,
            "No staked or dstaked"
        );
        require(users[msg.sender].stake == 0, "Already claimed");
        uint256 amount = users[msg.sender].basic * 4;
        users[msg.sender].stake = amount;
        token.safeTransfer(msg.sender, amount);
        emit AirDropped(msg.sender, amount, 3);
    }

    function _handleBasicAirDrop(address addr, uint256 amount) private {
        if (users[addr].basic == 0 && addr != address(0)) {
            users[addr].basic = amount;
            token.safeTransfer(addr, amount);

            emit AirDropped(addr, amount, 0);
        }
    }

    /**
     * Bulk function to allocate basic airdrop to users from the database
     * caller: owner
     */
    function handleBasicAirDrop(address addr, uint256 amount) external onlyOwner {
        _handleBasicAirDrop(addr, amount);
    }

    /**
     * Bulk function to reduce gas fees and time spent on basic airdrop
     */
    function handleBasicAirDrops(address[] calldata addrs, uint256[] calldata amounts) external onlyOwner {
        require(addrs.length == amounts.length, "Invalid params");

        for (uint256 index = 0; index < addrs.length; index++) {
            _handleBasicAirDrop(addrs[index], amounts[index]);
        }
    }

    function setEndTime(uint256 _endTime) external onlyOwner {
        require(_endTime > block.timestamp, "Invalid _endTime");

        endTime = _endTime;
    }

    function withdrawToken() external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(msg.sender, balance);
    }

    function setAddresses(
        IFarming _farm,
        IStaking _staking,
        IDStakingOverview _dstakingOverview
    ) external onlyOwner {
        require(address(_farm) != address(0), "Invalid _farm");
        require(address(_staking) != address(0), "Invalid _staking");
        require(address(_dstakingOverview) != address(0), "Invalid _dstakingOverview");

        farm = _farm;
        staking = _staking;
        dstakingOverview = _dstakingOverview;
    }
}
