// contracts/FeeCollector.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/IArableSynth.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableFeeCollector.sol";
import "./interfaces/IArableCollateral.sol";
import "./interfaces/IArableExchange.sol";

import "./libs/ArableFees.sol";

/**
 * @author Ian Decentralize
 */
contract ArableFeeCollector is
    Initializable,
    OwnableUpgradeable,
    IArableFeeCollector,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    address public addressRegistry;

    uint256 public epochStartBlock;
    uint256 public epochStartTime;
    uint256 public epochDuration;
    uint256 public epochNumber;

    address[] public rewardTokens;
    mapping(address => bool) public _isRewardToken;

    mapping(address => bool) public isAllowedProvider;
    // lastRewardsIncreaseEpoch[address][rewardToken]
    mapping(address => mapping(address => uint256)) public lastRewardsIncreaseEpoch;
    // claimableRewards[address][rewardToken]
    mapping(address => mapping(address => uint256)) public claimableRewards;
    // claimedRewards[address][rewardToken]
    mapping(address => mapping(address => uint256)) public claimedRewards;
    // totalClaimed[rewardToken]
    mapping(address => uint256) public totalClaimed;
    // totalDistributed[rewardToken]
    mapping(address => uint256) public totalDistributed;

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

    // TODO: add a call to subscription to set the bonus - pay ACRE for subscription
    mapping(address => mapping(address => uint256)) public accountBonusModel;

    event FeesPaid(address asset, ArableFees.Model model, uint256 fees);
    event IncreaseMinterRewards(address minter, address rewardToken, uint256 amount);
    event Claim(address minter, address rewardToken, uint256 amount);
    event EpochStart(uint256 epochNumber, uint256 epochStartBlock, uint256 epochStartTime);
    event SetEpochTokenRewards(uint256 epochNumber, address rewardToken, uint256 amount);
    event SetRewardTokens(address[] rewardTokens);
    event Pause();
    event Unpause();

    modifier onlyManager() {
        require(
            msg.sender == IArableAddressRegistry(addressRegistry).getArableManager(),
            "ArableFeeCollector: Manager Required!"
        );
        _;
    }

    modifier onlyAllowedProvider() {
        require(isAllowedProvider[msg.sender], "Not an allowed fee info provider");
        _;
    }

    function initialize(
        address addressRegistry_,
        uint256 defaultFees_,
        uint256 epochDuration_
    ) external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __ReentrancyGuard_init();
        __Pausable_init_unchained();

        require(addressRegistry_ != address(0), "Invalid addressRegistry_");

        addressRegistry = addressRegistry_;
        // setting a default fee model
        feesPerAssetModel[address(0)][ArableFees.Model.DEFAULT] = defaultFees_;

        isAllowedProvider[msg.sender] = true;
        epochStartBlock = block.number;
        epochStartTime = block.timestamp;
        epochNumber = 1;
        epochDuration = epochDuration_;
        epochNumber = 0;
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
    ) external override onlyManager whenNotPaused {
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
    ) external override whenNotPaused returns (uint256[] memory collectorReceipt) {
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

            // convert fees to arUSD
            address exchange = IArableAddressRegistry(addressRegistry).getArableExchange();
            IERC20(asset_).approve(exchange, fees);
            IArableExchange(exchange).convertFeesToUsd(asset_, fees);
        }
        _setCurrentModel(asset_, ArableFees.Model(0));
        emit FeesPaid(asset_, ArableFees.Model(model_), fees);

        return collectorReceipt;
    }

    function setAllowedProvider(address provider_) external onlyOwner {
        require(provider_ != address(0), "Invalid provider_");

        isAllowedProvider[provider_] = true;
    }

    function unsetAllowedProvider(address provider_) external onlyOwner {
        require(provider_ != address(0), "Invalid provider_");

        isAllowedProvider[provider_] = false;
    }

    function setAllowedProviders(address[] calldata providers_) external onlyOwner {
        for (uint256 index = 0; index <= providers_.length; index++) {
            require(providers_[index] != address(0), "Invalid providers_");

            isAllowedProvider[providers_[index]] = true;
        }
    }

    function unsetAllowedProviders(address[] calldata providers_) external onlyOwner {
        for (uint256 index = 0; index <= providers_.length; index++) {
            require(providers_[index] != address(0), "Invalid providers_");

            isAllowedProvider[providers_[index]] = false;
        }
    }

    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    function getRewardTokensCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    // by validators
    function increaseMinterRewards(
        address minter,
        address rewardToken,
        uint256 amount
    ) external override onlyAllowedProvider nonReentrant whenNotPaused {
        require(_isRewardToken[rewardToken], "Not a reward token");
        require(lastRewardsIncreaseEpoch[minter][rewardToken] < epochNumber, "Already increased reward for the epoch");

        claimableRewards[minter][rewardToken] += amount;
        totalDistributed[rewardToken] += amount;
        lastRewardsIncreaseEpoch[minter][rewardToken] = epochNumber;
        emit IncreaseMinterRewards(minter, rewardToken, amount);
    }

    function bulkIncreaseMinterRewards(
        address rewardToken,
        address[] calldata minters,
        uint256[] calldata amounts
    ) external override onlyAllowedProvider nonReentrant whenNotPaused {
        require(_isRewardToken[rewardToken], "Not a reward token");
        require(minters.length == amounts.length, "Minters and amounts length should be equal");

        for (uint256 i = 0; i < minters.length; i++) {
            address minter = minters[i];
            uint256 amount = amounts[i];
            if (lastRewardsIncreaseEpoch[minter][rewardToken] >= epochNumber) {
                continue;
            }

            claimableRewards[minter][rewardToken] += amount;
            totalDistributed[rewardToken] += amount;
            lastRewardsIncreaseEpoch[minter][rewardToken] = epochNumber;
            emit IncreaseMinterRewards(minter, rewardToken, amount);
        }
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
        address defaultAsset = address(0);
        ArableFees.Model defaultModel = ArableFees.Model.DEFAULT;
        uint256 assetModelFees = feesPerAssetModel[defaultAsset][defaultModel];
        if (feesPerAssetModel[defaultAsset][model_] != 0) {
            assetModelFees = feesPerAssetModel[address(0)][model_];
        }
        if (feesPerAssetModel[asset_][model_] != 0) {
            assetModelFees = feesPerAssetModel[asset_][model_];
        }

        uint256 accountBonus = accountBonusModel[defaultAsset][account_];
        if (accountBonusModel[asset_][account_] != 0) {
            accountBonus = accountBonusModel[asset_][account_];
        }

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

    function setRewardTokens(address[] memory _rewardTokens) public override onlyOwner {
        deleteRewardTokens();
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address rewardToken = _rewardTokens[i];
            require(rewardToken != address(0), "Invalid rewardTokens");

            rewardTokens.push(rewardToken);
            require(!_isRewardToken[rewardToken], "duplicated token");
            _isRewardToken[rewardToken] = true;
        }
        emit SetRewardTokens(_rewardTokens);
    }

    function deleteRewardTokens() public override onlyOwner {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _isRewardToken[rewardTokens[i]] = false;
        }
        while (rewardTokens.length > 0) {
            rewardTokens.pop();
        }
    }

    // by validators
    function startNewEpoch() public override onlyAllowedProvider whenNotPaused {
        require(block.timestamp > epochStartTime + epochDuration, "not enough time passed for epoch");
        epochStartBlock = block.number;
        epochStartTime = block.timestamp;
        epochNumber = epochNumber + 1;

        emit EpochStart(epochNumber, epochStartBlock, epochStartTime);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            emit SetEpochTokenRewards(epochNumber, rewardToken, getTotalDistributableRewards(rewardToken));
        }
    }

    function claimReward(address rewardToken) public override nonReentrant whenNotPaused {
        _claimReward(msg.sender, rewardToken);
    }

    function _claimReward(address minter, address rewardToken) internal {
        require(_isRewardToken[rewardToken], "Not a reward token");
        require(claimableRewards[minter][rewardToken] > claimedRewards[minter][rewardToken], "empty rewards");
        address collateral = IArableAddressRegistry(addressRegistry).getArableCollateral();
        IArableCollateral collateralContract = IArableCollateral(collateral);
        require(collateralContract.userRiskRate(minter) <= 1 ether, "risk rate should be lower than 100%");

        uint256 claimAmount = claimableRewards[minter][rewardToken] - claimedRewards[minter][rewardToken];
        claimedRewards[minter][rewardToken] += claimAmount;
        totalClaimed[rewardToken] += claimAmount;
        IArableSynth(rewardToken).transfer(minter, claimAmount);
        emit Claim(msg.sender, rewardToken, claimAmount);
    }

    function estimatedReward(address minter, address rewardToken) public view override returns (uint256) {
        return claimableRewards[minter][rewardToken] - claimedRewards[minter][rewardToken];
    }

    function getTotalDistributableRewards(address rewardToken) public view override returns (uint256) {
        return IERC20(rewardToken).balanceOf(address(this)) + totalClaimed[rewardToken] - totalDistributed[rewardToken];
    }
}
