
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IArableLiquidation {
    function isFlaggable(address user) external view returns (bool);
    function isFlagged(address user) external view returns (bool);
    function userRiskRate(address user) external view returns (uint);
    function flagForLiquidation(address user) external returns (uint);
    function removeFlagIfHealthy(address user) external;
    function liquidate(address user) external;
    function setAddressRegistry(address newAddressRegistry) external ;
    function setLiquidationRate(uint newRate) external ;
    function setImmediateLiquidationRate(uint newRate) external;
    function setLiquidationDelay(uint newDelay) external;
    function setLiquidationPenalty(uint newPenalty) external;
}
