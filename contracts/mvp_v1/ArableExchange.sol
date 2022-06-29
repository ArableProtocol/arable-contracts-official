// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/IArableOracle.sol";
import "./interfaces/IArableSynth.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableFeeCollector.sol";
import "./interfaces/IArableCollateral.sol";
import "./libs/ArableFees.sol";

// Implement swap between two synths based on exchange rate on oracle
contract ArableExchange is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    string private constant _arUSD = "arUSD";
    address public addressRegistry;
    uint256 public assetProtectionTime;
    mapping(address => uint256) public tokenPurchasePrice;
    mapping(address => uint256) public tokenPurchaseTimestamp;

    event Swap(address inToken, uint256 inAmount, address outToken, uint256 outAmount, uint256 inFeeAmount);
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

    function setMEVProtectionTime(uint256 interval) external onlyOwner {
        assetProtectionTime = interval;
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

    /**
     * @notice convert fees to arUSD
     */
    function convertFeesToUsd(address inToken, uint256 inAmount) external whenNotPaused {
        address feeCollectorAddress = IArableAddressRegistry(addressRegistry).getArableFeeCollector();
        require(msg.sender == feeCollectorAddress, "caller is not the fee collector");

        require(inToken != address(0x0), "inToken should be set");
        require(inAmount != 0, "In amount should not be ZERO");
        address manager = IArableAddressRegistry(addressRegistry).getArableManager();
        IArableManager managerContract = IArableManager(manager);
        address arUSD = managerContract.getSynthAddress(_arUSD);

        if (inToken == arUSD) {
            return;
        }

        address oracle = IArableAddressRegistry(addressRegistry).getArableOracle();
        IArableOracle oracleContract = IArableOracle(oracle);
        uint256 inTokenPrice = oracleContract.getPrice(inToken);
        require(inTokenPrice != 0, "inToken price should be set");

        // send tokens to the contract
        IERC20(inToken).transferFrom(msg.sender, address(this), inAmount);

        uint256 outAmount = (inTokenPrice * (inAmount)) / 1 ether;
        IArableSynth(inToken).burn(inAmount);
        IArableSynth(arUSD).mint(msg.sender, outAmount);
    }

    /**
     * @notice swap inAmount of inToken to outToken
     */
    function swapSynths(
        address inToken,
        uint256 inAmount,
        address outToken
    ) external nonReentrant whenNotPaused {
        require(inToken != address(0x0), "inToken should be set");
        require(outToken != address(0x0), "outToken should be set");
        require(inAmount != 0, "In amount should not be ZERO");

        address manager = IArableAddressRegistry(addressRegistry).getArableManager();
        IArableManager managerContract = IArableManager(manager);
        require(managerContract.isEnabledSynth(inToken), "inToken should be enabled synth");
        require(managerContract.isEnabledSynth(outToken), "outToken should be enabled synth");

        address oracle = IArableAddressRegistry(addressRegistry).getArableOracle();
        IArableOracle oracleContract = IArableOracle(oracle);
        uint256 inTokenPrice = oracleContract.getPrice(inToken);
        uint256 outTokenPrice = oracleContract.getPrice(outToken);

        require(inTokenPrice != 0, "inToken price should be set");
        require(outTokenPrice != 0, "outToken price should be set");

        // send tokens to the contract
        IERC20(inToken).transferFrom(msg.sender, address(this), inAmount);

        // pay swap fees
        uint256 fees = payFeesFor(inToken, inAmount, msg.sender, ArableFees.Model.SYNTHS_X);

        // if token purchase record in protection time is lower than the current sell price,
        // it set sell price of inToken to purchase price for MEV protection
        uint256 effectiveInTokenPrice = inTokenPrice;
        if (
            tokenPurchaseTimestamp[inToken] > 0 &&
            tokenPurchaseTimestamp[inToken] + assetProtectionTime >= block.timestamp &&
            tokenPurchasePrice[inToken] < inTokenPrice
        ) {
            effectiveInTokenPrice = tokenPurchasePrice[inToken];
            address collateral = IArableAddressRegistry(addressRegistry).getArableCollateral();
            IArableCollateral collateralContract = IArableCollateral(collateral);
            // debt is reduced when MEV protection mechanism is executed
            collateralContract.removeFromDebt((inTokenPrice-effectiveInTokenPrice) * (inAmount - fees) / 1 ether);
        }

        uint256 outAmount = (effectiveInTokenPrice * (inAmount - fees)) / outTokenPrice;

        IArableSynth(inToken).burn(inAmount - fees);
        IArableSynth(outToken).mint(msg.sender, outAmount);

        // if protection time passed or token price is lower than previous purchase price, update it.
        if (
            tokenPurchaseTimestamp[outToken] + assetProtectionTime <= block.timestamp ||
            tokenPurchasePrice[outToken] > outTokenPrice
        ) {
            tokenPurchasePrice[outToken] = outTokenPrice;
            tokenPurchaseTimestamp[outToken] = block.timestamp;
        }
        emit Swap(inToken, inAmount, outToken, outAmount, fees);
    }

    function payFeesFor(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) internal returns (uint256) {
        // collect fees for farm enter fee
        address feeCollectorAddress = IArableAddressRegistry(addressRegistry).getArableFeeCollector();
        IArableFeeCollector arableCollector = IArableFeeCollector(feeCollectorAddress);

        uint256 fees = arableCollector.calculateFees(asset_, amount_, account_, model_);
        IERC20(asset_).approve(feeCollectorAddress, fees);
        arableCollector.payFeesFor(asset_, amount_, account_, model_);

        return fees;
    }
}
