// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../common/ArableAccessControl.sol";
import "../interfaces/staking/IDStakingOverview.sol";

/** @title DStakingOverview
 *
 * @notice Contract that stores the overview of total delegated staking amounts
 *
 */
contract DStakingOverview is ArableAccessControl, IDStakingOverview {
    mapping(address => uint256) public override userDelegated;

    function initialize() external initializer {
        __ArableAccessControl_init_unchained();
    }

    function onDelegate(address user, uint256 amount) external override onlyOperator {
        userDelegated[user] = userDelegated[user] + amount;
    }

    function onUndelegate(address user, uint256 amount) external override onlyOperator {
        userDelegated[user] = userDelegated[user] - amount;
    }
}
