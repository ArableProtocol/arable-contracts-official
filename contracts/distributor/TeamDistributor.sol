// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { DistributeIterableMapping } from "../libs/DistributeIterableMapping.sol";

/**
 * @title TeamDistributor
 * 
 * This contract is for distributing team tokens to team members
 * The first member is team treasury account which get allocation - remaining of other members
 * Rest of the members are added by admin
 *
 */
contract TeamDistributor is Ownable, ReentrancyGuard {
    using DistributeIterableMapping for DistributeIterableMapping.Map;
    using SafeERC20 for IERC20;

    // list of members getting distribution - 1st member is treasury account
    DistributeIterableMapping.Map private members;

    uint256 constant public TOTAL_ALLOCATION = 1000; // total allocation is 100%

    IERC20 public token; // ERC20 token address
    address public treasuryAccount; // Base Account: (total - member amounts) will be distributed to this account

    uint256 public totalReleased; // Amount of token (sent to members)
    uint256 public totalDistributed; // Amount of token (cumulative)
    uint256 public allocationSum; // allocation sum except treasury account

    uint256 public lastDistributedTimeStamp;

    uint256 public cliffStartTime; // TODO: add comment
    uint256 public vestingDuration = 1095 days;

    event DistributeWalletCreated(address indexed addr, address indexed treasuryAccount);
    event DistributeBaseAccountChanged(address indexed treasuryAccount);
    event DistributeMemberAdded(address indexed member, uint256 allocation);
    event DistributeMemberRemoved(address indexed member);
    event TokenDistributed(uint256 amount);
    event TokenReleased(address indexed member, uint256 amount);
    event DistributeMemberAddressChanged(address indexed oldAddr, address indexed newAddr);
    event DistributeMemberAllocationChanged(address indexed member, uint256 newAllocation);

    modifier isCliffStarted() {
        require(block.timestamp >= cliffStartTime, "You can't withdraw yet!");

        _;
    }

    constructor(
        IERC20 _token,
        address _treasuryAccount,
        uint256 _cliffStartTime
    ) {
        require(_treasuryAccount != address(0), "BaseAccount can't be empty address");
        require(address(_token) != address(0), "Token address can't be empty address");
        require(_cliffStartTime > block.timestamp + 7 days, "CliffStartTime should be at least 7 days from now");

        token = _token;
        treasuryAccount = _treasuryAccount;
        cliffStartTime = _cliffStartTime;

        members.set(treasuryAccount,
            DistributeIterableMapping.DistributeMember(
                treasuryAccount,
                TOTAL_ALLOCATION,
                0,
                0
            ));

        lastDistributedTimeStamp = block.timestamp;

        emit DistributeWalletCreated(address(this), treasuryAccount);
    }

    function getTotalMembers() external view returns (uint256) {
        return members.size();
    }

    function getMemberInfo(address _member)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256
        )
    {
        require(members.inserted[_member], "Member doesn't exist!");
        DistributeIterableMapping.DistributeMember storage member = members.get(_member);

        return (member.addr, member.allocation, member.pending, member.totalReleased);
    }

    function getMemberInfoAtIndex(uint256 memberIndex)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256
        )
    {
        require(memberIndex < members.size(), "MemberIndex invalid!");
        address memberAddress = members.getKeyAtIndex(memberIndex);
        require(members.inserted[memberAddress], "Member doesn't exist!");
        DistributeIterableMapping.DistributeMember storage member = members.get(memberAddress);

        return (member.addr, member.allocation, member.pending, member.totalReleased);
    }

    // getReleasableAmount returns specified member's releasable amount from team distributer
    function getReleasableAmount(address member) public view returns (uint256) {
        require(members.inserted[member], "Member doesn't exist!");
        // (totalDistributed - totalReleased) is the sum of members' pending amounts
        uint256 pendingAmount = token.balanceOf(address(this)) + totalReleased - totalDistributed;

        if (block.timestamp < cliffStartTime) {
            return 0;
        }

        uint256 personalPending;
        if (member == treasuryAccount) {
            personalPending =
                members.get(member).pending +
                (pendingAmount * (TOTAL_ALLOCATION - allocationSum)) /
                TOTAL_ALLOCATION;
        } else {
            personalPending =
                members.get(member).pending +
                (pendingAmount * members.get(member).allocation) /
                TOTAL_ALLOCATION;
        }

        uint256 percent;
        if (block.timestamp >= cliffStartTime + vestingDuration) {
            percent = 100;
        } else {
            percent = (100 * (block.timestamp - cliffStartTime)) / vestingDuration;
        }

        return (personalPending * percent) / 1e2 - members.get(member).totalReleased;
    }

    // transaction sender is the member who change address
    function updateMemberAddress(address newAddr) external {
        address member = msg.sender;
        require(newAddr != address(0), "New address can't be a ZERO address!");
        require(members.inserted[member], "You're not a member!");
        require(!members.inserted[newAddr], "NewAddr already exist!");

        members.set(
            newAddr,
            DistributeIterableMapping.DistributeMember(
                newAddr,
                members.get(member).allocation,
                members.get(member).pending,
                0
            )
        );

        members.remove(member);

        emit DistributeMemberAddressChanged(member, newAddr);
    }

    // admin changes allocation of a member
    function updateMemberAllocation(address member, uint256 allocation) external onlyOwner {
        require(members.inserted[member], "Member is not a member!");

        allocationSum = allocationSum + allocation - members.get(member).allocation;

        require(allocationSum <= TOTAL_ALLOCATION, "Allocation is too big!");

        updatePendingAmounts();

        members.get(member).allocation = allocation;
        members.get(treasuryAccount).allocation = TOTAL_ALLOCATION - allocationSum;

        emit DistributeMemberAllocationChanged(member, allocation);
    }

    function _release(address _member) private nonReentrant {
        require(members.inserted[_member], "Member doesn't exist!");

        DistributeIterableMapping.DistributeMember storage member = members.get(_member);
        uint256 releasableAmount = getReleasableAmount(_member);
        if (releasableAmount > 0) {
            member.totalReleased += releasableAmount;
            totalReleased += releasableAmount;
            token.safeTransfer(_member, releasableAmount);
            emit TokenReleased(_member, releasableAmount);
        }
    }

    function updatePendingAmounts() public {
        if (lastDistributedTimeStamp < block.timestamp) {
            // (totalDistributed - totalReleased) is the sum of members' pending amounts
            uint256 pendingAmount = token.balanceOf(address(this)) + totalReleased - totalDistributed;
            if (pendingAmount > 0) {
                // updatePendingAmounts to members, and restAmount to treasuryAccount
                uint256 distributedAmount = 0;
                uint256 memberLength = members.size();
                for (uint256 index = 1; index < memberLength; index++) {
                    address memberAddress = members.getKeyAtIndex(index);
                    DistributeIterableMapping.DistributeMember storage member = members.get(memberAddress);
                    uint256 amount = (pendingAmount * member.allocation) / TOTAL_ALLOCATION;
                    member.pending = member.pending + amount;
                    distributedAmount = distributedAmount + amount;
                }

                DistributeIterableMapping.DistributeMember storage treasuryMember = members.get(treasuryAccount);
                uint256 restAmount = pendingAmount - distributedAmount;
                treasuryMember.pending = treasuryMember.pending + restAmount;

                totalDistributed = totalDistributed + pendingAmount;
            }
            lastDistributedTimeStamp = block.timestamp;
        }
    }

    function addMember(address _member, uint256 _allocation) external onlyOwner {
        require(_member != address(0), "Member address can't be empty address");
        require(!members.inserted[_member], "Member already exist!");
        require(_allocation > 0, "Allocation can't be zero!");
        allocationSum += _allocation;
        require(allocationSum <= TOTAL_ALLOCATION, "Allocation is too big!");
        // updatePendingAmounts current pending tokens to existing members and then add new member
        updatePendingAmounts();
        members.set(_member, DistributeIterableMapping.DistributeMember(_member, _allocation, 0, 0));
        members.get(treasuryAccount).allocation = TOTAL_ALLOCATION - allocationSum;
        emit DistributeMemberAdded(_member, _allocation);
    }

    function removeMember(address _member) external onlyOwner {
        require(_member != treasuryAccount, "You can't remove treasuryAccount!");
        require(members.inserted[_member], "Member doesn't exist!");
        // updatePendingAmounts pending Amount to members and send necessary amount to that member, and then remove
        updatePendingAmounts();
        _release(_member);

        // move rest locked to treasury
        uint256 restLocked = members.get(_member).pending - members.get(_member).totalReleased;
        members.get(treasuryAccount).pending = members.get(treasuryAccount).pending + restLocked;

        allocationSum -= members.get(_member).allocation;
        members.get(treasuryAccount).allocation = TOTAL_ALLOCATION - allocationSum;
        members.remove(_member);

        emit DistributeMemberRemoved(_member);
    }

    function release() external isCliffStarted {
        // updatePendingAmounts pendingAmount first and release
        updatePendingAmounts();
        _release(msg.sender);
    }

    function releaseToMember(address member) external isCliffStarted {
        // updatePendingAmounts pendingAmount first and release
        updatePendingAmounts();
        _release(member);
    }

    function releaseToMemberAll() external isCliffStarted {
        updatePendingAmounts();

        uint256 memberLength = members.size();
        for (uint256 index = 0; index < memberLength; index++) {
            address memberAddress = members.getKeyAtIndex(index);
            _release(memberAddress);
        }
    }

    function withdrawAnyToken(IERC20 _token, uint256 amount) external onlyOwner {
        _token.safeTransfer(msg.sender, amount);
    }
}
