// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ArableSynth.sol";
import "./interfaces/IArableFarming.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableOracle.sol";

contract MultisigFeeder is Ownable {
    struct Action {
        address suggestor;
        uint256 actionType;
        uint256 timeSlot;
        address param1;
        uint256 param2;
        uint256 param3;
    }

    uint256 public slotZeroTime;
    uint256 public slotDuration = 1 hours;

    address public addressRegistry;
    uint256 public requiredApprovals;
    mapping(address => bool) public isMember;
    Action[] public actions;
    mapping(uint256 => mapping(address => bool)) public isApproved;
    mapping(uint256 => uint256) public numApprovals;

    event SuggestAction(
        address suggestor,
        uint256 actionIndex,
        uint256 actionType,
        uint256 timeSlot,
        address param1, uint256 param2, uint256 param3);
    event ApproveAction(address approver, uint256 actionIndex);
    event ExecuteAction(address executor, uint256 actionIndex);
    event SetRequiredApprovals(uint256 requiredApprovals);

    modifier onlyMember {
      require(isMember[msg.sender], "Not a multisig member");
      _;
    }

    constructor(address addressRegistry_) {
        addressRegistry = addressRegistry_;
        slotZeroTime = block.timestamp;
        isMember[msg.sender] = true;
    }

    function setMember(address provider_) external onlyOwner {
        isMember[provider_] = true;
    }

    function unsetMember(address provider_) external onlyOwner {
        isMember[provider_] = false;
    }

    function setRequiredApprovals(uint256 value) external onlyOwner {
        requiredApprovals = value;
        emit SetRequiredApprovals(value);
    }

    function currentSlot() public view returns (uint256) {
        return (block.timestamp - slotZeroTime) / slotDuration;
    }

    function suggestAction(uint256 actionType, address param1, uint256 param2, uint256 param3)
        public onlyMember {
        uint256 timeSlot = currentSlot();
        uint256 actionIndex = actions.length;
        actions.push(Action(
            msg.sender,
            actionType,
            timeSlot,
            param1,
            param2,
            param3
        ));
        isApproved[actionIndex][msg.sender] = true;
        numApprovals[actionIndex] = 1;
        emit SuggestAction(msg.sender, actionIndex, actionType, timeSlot, param1, param2, param3);
    }

    function approveAction(uint256 actionIndex) public onlyMember {
        require(isApproved[actionIndex][msg.sender] == false, "already approved the action");
        require(currentSlot() == actions[actionIndex].timeSlot, "action timeslot already passed");
        isApproved[actionIndex][msg.sender] = true;
        numApprovals[actionIndex] ++;
        emit ApproveAction(msg.sender, actionIndex);
    }

    function executeAction(uint256 actionIndex) public {
        require(numApprovals[actionIndex] >= requiredApprovals, "not enough approvals");
        Action storage action = actions[actionIndex];
        require(currentSlot() == action.timeSlot, "action timeslot already passed");
        if (action.actionType == 1) { // register price
            IArableOracle oracle = IArableOracle(IArableAddressRegistry(addressRegistry).getArableOracle());
            oracle.registerPrice(action.param1, action.param2);
        } else if (action.actionType == 2) { // register reward rate
            IArableOracle oracle = IArableOracle(IArableAddressRegistry(addressRegistry).getArableOracle());
            oracle.registerRewardRate(action.param2, action.param1, action.param3);
        }
        emit ExecuteAction(msg.sender, actionIndex);
    }

    function bulkSuggestAction(
        uint256[] calldata actionTypes,
        address[] calldata param1Arr, uint256[] calldata param2Arr, uint256[] calldata param3Arr)
        external {
        for (uint256 i = 0; i < actionTypes.length; i ++) {
            suggestAction(actionTypes[i], param1Arr[i], param2Arr[i], param3Arr[i]);
        }
    }

    function bulkApproveAction(uint256[] calldata actionIndexes) external {
        for (uint256 i = 0; i < actionIndexes.length; i ++) {
            approveAction(actionIndexes[i]);
        }
    }

    function bulkExecuteAction(uint256[] calldata actionIndexes) external {
        for (uint256 i = 0; i < actionIndexes.length; i ++) {
            executeAction(actionIndexes[i]);
        }
    }
}
