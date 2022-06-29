// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IArableManager {
    function isSynth(address _token) external view returns (bool);
    function isSynthDisabled(address _token) external view returns (bool);
    function isEnabledSynth(address _token) external view returns (bool);
    function getSynthAddress(string memory tokenSymbol) external view returns (address);
    function onAssetPriceChange(address asset, uint256 oldPrice, uint256 newPrice) external;
}
