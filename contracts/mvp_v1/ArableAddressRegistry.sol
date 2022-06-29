// SPDX-License-Identifier: GNU-GPL v3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/IArableAddressRegistry.sol";

contract ArableAddressRegistry is Initializable, OwnableUpgradeable, IArableAddressRegistry {
    bytes32 public constant ARABLE_ORACLE = "ARABLE_ORACLE";
    bytes32 public constant ARABLE_FARMING = "ARABLE_FARMING";
    bytes32 public constant ARABLE_EXCHANGE = "ARABLE_EXCHANGE";
    bytes32 public constant ARABLE_MANAGER = "ARABLE_MANAGER";
    bytes32 public constant ARABLE_COLLATERAL = "ARABLE_COLLATERAL";
    bytes32 public constant ARABLE_LIQUIDATION = "ARABLE_LIQUIDATION";
    bytes32 public constant ARABLE_FEE_COLLECTOR = "ARABLE_FEE_COLLECTOR";
    // TODO: we can add ADMIN address

    mapping(bytes32 => address) private _addresses;

    function initialize() external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    // Set up all addresses for the registry.
    function init(
        address arableOracle_,
        address arableFarming_,
        address arableExchange_,
        address arableManager_,
        address arableCollateral_,
        address arableLiquidation_,
        address arableFeeCollector_
    ) external onlyOwner {
        _addresses[ARABLE_ORACLE] = arableOracle_;
        _addresses[ARABLE_FARMING] = arableFarming_;
        _addresses[ARABLE_EXCHANGE] = arableExchange_;
        _addresses[ARABLE_MANAGER] = arableManager_;
        _addresses[ARABLE_COLLATERAL] = arableCollateral_;
        _addresses[ARABLE_LIQUIDATION] = arableLiquidation_;
        _addresses[ARABLE_FEE_COLLECTOR] = arableFeeCollector_;
    }

    function setAddress(bytes32 id, address address_) external override onlyOwner {
        _addresses[id] = address_;
    }

    function getArableOracle() external view override returns (address) {
        return getAddress(ARABLE_ORACLE);
    }

    function setArableOracle(address arableOracle_) external override onlyOwner {
        _addresses[ARABLE_ORACLE] = arableOracle_;
    }

    function getArableFarming() external view override returns (address) {
        return getAddress(ARABLE_FARMING);
    }

    function setArableFarming(address arableFarming_) external override onlyOwner {
        _addresses[ARABLE_FARMING] = arableFarming_;
    }

    function getArableExchange() external view override returns (address) {
        return getAddress(ARABLE_EXCHANGE);
    }

    function setArableExchange(address arableExchange_) external override onlyOwner {
        _addresses[ARABLE_EXCHANGE] = arableExchange_;
    }

    function getArableManager() external view override returns (address) {
        return getAddress(ARABLE_MANAGER);
    }

    function setArableManager(address arableManager_) external override onlyOwner {
        _addresses[ARABLE_MANAGER] = arableManager_;
    }

    function getArableCollateral() external view override returns (address) {
        return getAddress(ARABLE_COLLATERAL);
    }

    function setArableCollateral(address arableCollateral_) external override onlyOwner {
        _addresses[ARABLE_COLLATERAL] = arableCollateral_;
    }

    function getArableLiquidation() external view override returns (address) {
        return getAddress(ARABLE_LIQUIDATION);
    }

    function setArableLiquidation(address arableLiquidation_) external override onlyOwner {
        _addresses[ARABLE_LIQUIDATION] = arableLiquidation_;
    }

    function setArableFeeCollector(address arableFeeCollector_) external override onlyOwner {
        _addresses[ARABLE_MANAGER] = arableFeeCollector_;
    }

    function getArableFeeCollector() external view override returns (address) {
        return getAddress(ARABLE_FEE_COLLECTOR);
    }

    /**
     * @dev Returns an address by id
     * @return The address
     */
    function getAddress(bytes32 id) public view override returns (address) {
        return _addresses[id];
    }
}
