// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { DistributeIterableMapping } from "../libs/DistributeIterableMapping.sol";

/**
 * @title RootDistributor
 * 
 * This contract is for distributing vested tokens to staking, farming, community pool and
 * team distributer contracts
 *
 */
contract RootDistributor is Ownable, ReentrancyGuard {
    using DistributeIterableMapping for DistributeIterableMapping.Map;
    using SafeERC20 for IERC20;

    DistributeIterableMapping.Map private members;

    IERC20 public token; // ERC20 token address

    uint256 public totalReleased; // Amount of token (sent to members)
    uint256 public totalDistributed; // Amount of token (cumulative)
    uint256 public allocationSum; // Sum of member allocation

    uint256 public lastDistributedTimeStamp;

    event DistributeWalletCreated(address indexed addr);
    event DistributeMemberAdded(address indexed member, uint256 allocation);
    event DistributeMemberRemoved(address indexed member);
    event TokenDistributed(uint256 amount);
    event TokenReleased(address indexed member, uint256 amount);
    event DistributeMemberAddressChanged(address indexed oldAddr, address indexed newAddr);
    event DistributeMemberAllocationChanged(address indexed member, uint256 newAllocation);

    constructor(IERC20 _token) {
        require(address(_token) != address(0), "Token address can't be empty address");
        token = _token;

        lastDistributedTimeStamp = block.timestamp;

        emit DistributeWalletCreated(address(this));
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

    // getReleasableAmount returns specified member's releasable amount from root distributer
    function getReleasableAmount(address member) external view returns (uint256) {
        require(members.inserted[member], "Member doesn't exist!");

        // (totalDistributed - totalReleased) is the sum of members' pending amounts
        uint256 pendingAmount = token.balanceOf(address(this)) + totalReleased - totalDistributed;
        return members.get(member).pending + (pendingAmount * members.get(member).allocation) / allocationSum;
    }

    // admin changes allocation - in most of the case it does not change after initial set
    function updateMemberAllocation(address member, uint256 allocation) external onlyOwner {
        require(allocation > 0, "Allocation can't be ZERO!");
        require(members.inserted[member], "Member is not a member!");

        allocationSum = allocationSum + allocation - members.get(member).allocation;

        updatePendingAmounts();

        members.get(member).allocation = allocation;

        emit DistributeMemberAllocationChanged(member, allocation);
    }

    function _release(address _member) private {
        require(members.inserted[_member], "Member doesn't exist!");
        DistributeIterableMapping.DistributeMember storage member = members.get(_member);
        uint256 pendingAmount = member.pending;
        if (pendingAmount > 0) {
            member.totalReleased += pendingAmount;
            member.pending = 0;
            totalReleased += pendingAmount;
            token.safeTransfer(_member, pendingAmount);
        }
        emit TokenReleased(_member, pendingAmount);
    }

    function updatePendingAmounts() public {
        uint256 memberLength = members.size();

        if (lastDistributedTimeStamp < block.timestamp && memberLength > 0) {
            // (totalDistributed - totalReleased) is the sum of members' pending amounts
            uint256 pendingAmount = token.balanceOf(address(this)) + totalReleased - totalDistributed;
            if (pendingAmount > 0) {
                // updatePendingAmounts to members, and restAmount to baseAccount
                uint256 distributedAmount = 0;

                for (uint256 index = 0; index < memberLength; index++) {
                    address memberAddress = members.getKeyAtIndex(index);
                    DistributeIterableMapping.DistributeMember storage member = members.get(memberAddress);
                    uint256 amount = (pendingAmount * member.allocation) / allocationSum;
                    member.pending = member.pending + amount;
                    distributedAmount = distributedAmount + amount;
                }

                totalDistributed = totalDistributed + pendingAmount;
            }
            lastDistributedTimeStamp = block.timestamp;
        }
    }

    function addMember(address _member, uint256 _allocation) external onlyOwner {
        require(_member != address(0), "Member address can't be empty address");
        require(!members.inserted[_member], "Member already exist!");
        require(_allocation > 0, "Allocation can't be zero!");
        // updatePendingAmounts current pending tokens to existing members and then add new member
        updatePendingAmounts();

        allocationSum += _allocation;
        members.set(_member, DistributeIterableMapping.DistributeMember(_member, _allocation, 0, 0));
        emit DistributeMemberAdded(_member, _allocation);
    }

    function removeMember(address _member) external onlyOwner {
        require(members.inserted[_member], "Member doesn't exist!");
        // updatePendingAmounts pending Amount to members and send necessary amount to that member, and then remove
        updatePendingAmounts();
        _release(_member);
        allocationSum -= members.get(_member).allocation;
        members.remove(_member);

        emit DistributeMemberRemoved(_member);
    }

    function release() external nonReentrant {
        // updatePendingAmounts pendingAmount first and release
        updatePendingAmounts();
        _release(msg.sender);
    }

    function releaseToMember(address member) external nonReentrant {
        // updatePendingAmounts pendingAmount first and release
        updatePendingAmounts();
        _release(member);
    }

    // This function is called per epoch by bot
    function releaseToMemberAll() external nonReentrant {
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
