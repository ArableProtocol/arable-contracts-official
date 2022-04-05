// contracts/FeeCollector.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IArableSynth.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableFeeCollector.sol";

import "./libs/ArableFees.sol";

import "hardhat/console.sol";

/**
 * @author Ian Decentralize
 */
contract ArableFeeCollector is IArableFeeCollector, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public addressRegistry;

    // amount / FEE_BASE * base3
    uint256 internal constant FEE_BASE = 10000;

    // default model
    ArableFees.Model internal currentModel;

    // could return fees directly or return a contract with model.
    // to keep precision we use a base 3 number where 200 = 2.00 percent.
    // see also how to apply MANTISSA to smaller units.
    mapping(address => mapping(ArableFees.Model => uint256)) public feesPerAssetModel;

    // cumulated fees per asset model could also be pulled from another contract
    mapping(address => mapping(ArableFees.Model => uint256)) public cumulatedFeesPerAssetModel;

    // some account might have discount bonus, could come from another contract.
    // Idealy this would come from the registrant contract

    // TODO add a call to subscribtion to set the bonus
    mapping(address => mapping(address => uint256)) public accountBonusModel;

    event FeesPaid(address asset, ArableFees.Model model, uint256 fees);

    modifier onlyManager() {
        require(
            msg.sender == IArableAddressRegistry(addressRegistry).getArableManager(),
            "ArableFeeCollector: Manager Required!"
        );
        _;
    }

    constructor(address addressRegistry_, uint256 defaultFees_) {
        addressRegistry = addressRegistry_;
        // setting a default fee model
        feesPerAssetModel[address(0)][ArableFees.Model.DEFAULT] = defaultFees_;
    }

    /**
     * @dev This function will pull the funds from caller and must be approved using estimateFees
     * @param asset_ address of the asset
     * @param amount_ The amount Input
     * @param account_ The account calling
     * @param model_ The model for which the fees apply
     * @return fees
     */
    function calculateFees(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) external view override returns (uint256 fees) {
        return _calculateFees(asset_, amount_, account_, model_);
    }

    /**
     * @dev setAssetFeeModel is called within the transaction.(external)
     * @param asset_ address of the asset
     * @param fees_ The fees in base3
     * @param model_ The model
     */
    function setAssetFeeModel(
        address asset_,
        uint256 fees_,
        ArableFees.Model model_
    ) external override onlyManager {
        require(model_ < ArableFees.Model.MAX, "ArableFeeCollector: Model overflow");
        require(fees_ <= FEE_BASE, "ArableFeeCollector: Fee overflow");
        feesPerAssetModel[asset_][ArableFees.Model(model_)] = fees_;
    }

    /**
     * @dev This function will pull the funds from caller and must be approved using estimateFees
     * @param asset_ address of the asset
     * @param amount_ The amount Input
     * @param account_ The account calling
     * @param model_ The model for which the fees apply
     * @return collectorReceipt to return to the caller
     */
    function payFeesFor(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) external override returns (uint256[] memory collectorReceipt) {
        require(
            asset_ != address(0x0) && account_ != address(0x0),
            "ArableFeeCollector: asset_ and account_ should be set"
        );
        collectorReceipt = new uint256[](2);
        _setCurrentModel(asset_, ArableFees.Model(model_));
        uint256 fees = _calculateFees(asset_, amount_, account_, ArableFees.Model(model_));

        if (fees == 0) {
            collectorReceipt[0] = 0;
            collectorReceipt[1] = amount_;
        } else if (fees > 0) {
            // pull the fees.
            cumulatedFeesPerAssetModel[asset_][currentModel] += fees;
            collectorReceipt[0] = fees;
            // resolving any overflow possible issues
            if (fees >= amount_) {
                collectorReceipt[1] = fees - amount_;
            } else {
                collectorReceipt[1] = amount_ - fees;
            }

            require(
                IArableSynth(asset_).transferFrom(msg.sender, address(this), fees),
                "ArableFeeCollector: Collection Failed!"
            );
        }
        _setCurrentModel(asset_, ArableFees.Model(0));
        emit FeesPaid(asset_, ArableFees.Model(model_), fees);

        return collectorReceipt;
    }

    /**
     * @dev This function will pull the funds from caller and must be approved using estimateFees
     * @param asset_ address of the asset
     * @param amount_ The amount Input
     * @param account_ The account calling
     * @param model_ The model for which the fees apply
     * @return fees
     */
    function _calculateFees(
        address asset_,
        uint256 amount_,
        address account_,
        ArableFees.Model model_
    ) internal view returns (uint256 fees) {
        uint256 assetModelFees = feesPerAssetModel[asset_][ArableFees.Model(model_)];
        uint256 accountBonus = accountBonusModel[asset_][account_];

        if (assetModelFees >= accountBonus) {
            fees = (amount_ * (assetModelFees - accountBonus)) / FEE_BASE;
        } else {
            fees = (amount_ * (accountBonus - assetModelFees)) / FEE_BASE;
        }
    }

    /**
     * @dev Check if asset have a model.
     * unkown/default model is = 0.
     *
     * @param asset_ The asset
     * @param model_ The model
     */
    function _setCurrentModel(address asset_, ArableFees.Model model_) internal {
        if (feesPerAssetModel[asset_][model_] == uint256(ArableFees.Model.DEFAULT)) {
            currentModel = ArableFees.Model.DEFAULT;
        } else {
            currentModel = ArableFees.Model(model_);
        }
    }
}
