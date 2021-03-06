// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./ArableSynth.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableFeeCollector.sol";
import "./interfaces/IArableCollateral.sol";
import "./libs/ArableFees.sol";

// Synths registration contract
contract ArableManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // manage synths deployed so far
    address[] public synths;
    mapping(bytes32 => address) public synthIds;
    mapping(address => bool) public isSynthDisabled;
    mapping(address => bool) public isSynth;

    address public addressRegistry;

    event RegisterSynth(address synthAddress, string tokenName, string tokenSymbol);
    event FeeModelUpdated(address asset, ArableFees.Model model, uint256 fees);
    event Pause();
    event Unpause();

    function initialize(address addressRegistry_) external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __ReentrancyGuard_init();
        __Pausable_init_unchained();

        require(addressRegistry_ != address(0), "Invalid addressRegistry_");

        addressRegistry = addressRegistry_;
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpause();
    }

    function bulkRegisterSynths(string[] calldata tokenNames_, string[] calldata tokenSymbols_) external onlyOwner {
        require(tokenNames_.length == tokenSymbols_.length, "Please check you input data.");
        for (uint256 i = 0; i < tokenNames_.length; i++) {
            registerSynth(tokenNames_[i], tokenSymbols_[i]);
        }
    }

    // function used to set the synths disabled status
    function setIsSynthDisabled(address synthAddress, bool isDisabled) external onlyOwner {
        isSynthDisabled[synthAddress] = isDisabled;

        // Note: disabled synths are not eligible for swap
    }

    function isEnabledSynth(address _token) external view returns (bool) {
        if (!isSynth[_token] || isSynthDisabled[_token]) {
            return false;
        }
        return true;
    }

    // TODO: this function is assuming that no more than 500 synths are registered
    function listSynths() external view returns (address[] memory) {
        return synths;
    }

    function getSynthsCount() external view returns (uint256) {
        return synths.length;
    }

    // TODO: this function is assuming that no more than 500 synths are registered
    function listEnabledSynths() external view returns (address[] memory) {
        uint256 enabledSynthsLength = 0;
        for (uint256 i = 0; i < synths.length; i++) {
            if (isSynthDisabled[synths[i]] == false) {
                enabledSynthsLength++;
            }
        }

        address[] memory enabledSynths = new address[](enabledSynthsLength);
        uint256 j = 0;
        for (uint256 i = 0; i < synths.length; i++) {
            if (isSynthDisabled[synths[i]] == false) {
                enabledSynths[j] = synths[i];
                j++;
            }
        }
        return enabledSynths;
    }

    /**
     * @dev Set the fee model for an asset
     * @param asset_ address of the asset
     * @param fees_ fees in base 3
     * @param model_ The model used
     */
    function setFeesModelFor(
        address asset_,
        uint256 fees_,
        ArableFees.Model model_
    ) external onlyOwner {
        address feeCollectorAddress = IArableAddressRegistry(addressRegistry).getArableFeeCollector();
        IArableFeeCollector(feeCollectorAddress).setAssetFeeModel(asset_, fees_, model_);

        emit FeeModelUpdated(asset_, ArableFees.Model(model_), fees_);
    }

    // calculate totalDebt for asset price change
    function onAssetPriceChange(
        address asset_,
        uint256 oldPrice,
        uint256 newPrice
    ) external nonReentrant whenNotPaused {
        IArableAddressRegistry _addressRegistry = IArableAddressRegistry(addressRegistry);
        require(msg.sender == _addressRegistry.getArableOracle(), "should be called by oracle contract");

        if (!isSynth[asset_]) {
            return;
        }

        IArableCollateral collateral = IArableCollateral(_addressRegistry.getArableCollateral());
        uint256 totalSupply = IERC20(asset_).totalSupply();
        if (oldPrice < newPrice) {
            collateral.addToDebt((totalSupply * (newPrice - oldPrice)) / 1 ether);
        } else if (oldPrice > newPrice) {
            collateral.removeFromDebt((totalSupply * (oldPrice - newPrice)) / 1 ether);
        }
    }

    function registerSynth(string memory tokenName, string memory tokenSymbol) public onlyOwner {
        // Note: farming and exchange contracts should be set before synths register
        address farming = IArableAddressRegistry(addressRegistry).getArableFarming();
        address exchange = IArableAddressRegistry(addressRegistry).getArableExchange();
        address collateral = IArableAddressRegistry(addressRegistry).getArableCollateral();

        require(synthIds[keccak256(abi.encodePacked(tokenSymbol))] == address(0), "synth is already registered");

        ArableSynth synth = new ArableSynth(tokenName, tokenSymbol, owner(), farming, exchange, collateral);
        synths.push(address(synth));
        isSynth[address(synth)] = true;

        //addition of synth ids, this is needed to call contract addresses
        //from collateral & liquidation
        synthIds[keccak256(abi.encodePacked(tokenSymbol))] = address(synth);

        emit RegisterSynth(address(synth), tokenName, tokenSymbol);
    }

    function getSynthAddress(string memory tokenSymbol) public view returns (address) {
        return synthIds[keccak256(abi.encodePacked(tokenSymbol))];
    }
}
