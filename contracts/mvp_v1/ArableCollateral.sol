// SPDX-License-Identifier: MIT

/// @title Arable Collateral Contract
/// @author Nithronium

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableOracle.sol";
import "./interfaces/IArableLiquidation.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableSynth.sol";
import "./interfaces/IERC20Extented.sol";

contract ArableCollateral is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /**
     * @dev state variable for holding Address registry object
     */
    IArableAddressRegistry private _addressRegistry;

    string private constant _arUSD = "arUSD";

    // *** COLLATERAL VARIABLES AND STRUCTS *** //

    /**
     * @notice struct to keep individual asset data
     *
     */
    struct CollateralAssetData {
        bool isEnabled;
        uint256 allowedRate;
        uint256 index;
    }

    /**
     * @notice state variables for collateral data
     */
    address[] public _supportedCollaterals;
    mapping(address => CollateralAssetData) public _collateralAssetData;

    /**
     * @notice this is used for determining user's deposited token amount
     *
     * @dev mapping of user address => token address => token balance
     */
    mapping(address => mapping(address => uint256)) public _individualCollateral;

    // *** DEBT VARIABLES AND STRUCTS *** //

    /**
     * @notice total debt of the system in terms of USD
     *
     * @dev value will be in 18 decimals (10**18 for $10)
     */
    uint256 public _totalDebt;

    /**
     * @notice total debt factor of the system
     *
     * @dev increases with each {mint} function
     * and decreases with each {burn} function
     */
    uint256 public _totalDebtFactor;

    /**
     * @notice mapping of individual debt factor
     *
     * @dev current debt rate = _totalDebt * _debtFactor / _totalDebtFactor
     * and _totalDebt / _totalDebtFactor is the scale ratio of debt
     */
    mapping(address => uint256) public _debtFactor;

    event SupportedCollateralAdded(
        address indexed token,
        uint256 allowedRate,
        uint256 index,
        address admin,
        uint256 blockNumber
    );
    event SupportedCollateralRemoved(address indexed token, uint256 index, address admin, uint256 blockNumber);
    event CollateralAllowedRateChanged(
        address indexed token,
        uint256 previousAllowedRate,
        uint256 newAllowedRate,
        uint256 index,
        address admin,
        uint256 blockNumber
    );

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount, uint256 blockNumber);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 blockNumber);
    event Mint(address indexed user, uint256 amount, uint256 blockNumber);
    event Burn(address indexed user, uint256 amount, uint256 blockNumber);
    event Liquidate(address indexed user, address indexed beneficiary, uint256 amount, uint256 blockNumber);

    event UserDebtFactorIncrease(address indexed user, uint256 amount, uint256 blockNumber);
    event UserDebtFactorDecrease(address indexed user, uint256 amount, uint256 blockNumber);
    event TotalDebtUpdate(uint256 newTotalDebt, uint256 timestamp);

    event Pause();
    event Unpause();

    modifier onlyAddress(bytes32 id) {
        require(msg.sender == _addressRegistry.getAddress(id), "Contract mismatch");
        _;
    }

    /**
     * @notice modifier to allow only supported collateral to be deposited
     */
    modifier onlySupportedCollateral(address token) {
        require(_collateralAssetData[token].isEnabled, "Collateral: Token not supported");
        _;
    }

    /**
     * @notice modifier to allow only Debt Manager to add or remove debt
     * @dev {addToDebt} & {removeFromDebt} functions are used
     */
    modifier onlyDebtManager(address sender) {
        require(
            sender == _addressRegistry.getArableManager() || sender == _addressRegistry.getArableFarming(),
            "not authorized"
        );
        _;
    }

    function initialize(address addressRegistry) external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __ReentrancyGuard_init();
        __Pausable_init_unchained();

        setAddressRegistry(addressRegistry);
    }

    function setAddressRegistry(address newAddressRegistry) public onlyOwner {
        _addressRegistry = IArableAddressRegistry(newAddressRegistry);
    }

    // ** EXTERNAL DEBT FUNCTIONS ** //
    function addToDebt(uint256 amount) external onlyDebtManager(msg.sender) returns (bool) {
        _totalDebt += amount;
        emit TotalDebtUpdate(_totalDebt, block.timestamp);
        return true;
    }

    function removeFromDebt(uint256 amount) external onlyDebtManager(msg.sender) returns (bool) {
        require(_totalDebt >= amount, "totalDebt should be bigger than amount");
        _totalDebt -= amount;
        emit TotalDebtUpdate(_totalDebt, block.timestamp);
        return true;
    }

    // ** EXTERNAL ASSET FUNCTIONS ** //

    function addSupportedCollateral(address token, uint256 allowedRate) public onlyOwner returns (bool) {
        require(_collateralAssetData[token].isEnabled == false, "collateral already supported");
        require(_collateralAssetData[token].index == 0, "collateral is already indexed");
        require(allowedRate >= 1 ether, "ratio should be more than 1");
        _collateralAssetData[token].isEnabled = true;
        _collateralAssetData[token].allowedRate = allowedRate;
        _collateralAssetData[token].index = _supportedCollaterals.length;
        _supportedCollaterals.push(token);
        emit SupportedCollateralAdded(token, allowedRate, _collateralAssetData[token].index, msg.sender, block.number);
        return true;
    }

    function removeSupportedCollateral(address token) public onlyOwner returns (bool) {
        require(_collateralAssetData[token].isEnabled == true, "collateral already disabled");
        address lastToken = _supportedCollaterals[_supportedCollaterals.length - 1];
        _collateralAssetData[lastToken].index = _collateralAssetData[token].index;
        _supportedCollaterals[_collateralAssetData[token].index] = lastToken;
        _supportedCollaterals.pop();
        emit SupportedCollateralRemoved(token, _collateralAssetData[token].index, msg.sender, block.number);
        _collateralAssetData[token].isEnabled = false;
        _collateralAssetData[token].index = 0;
        return true;
    }

    function changeAllowedRate(address token, uint256 newAllowedRate) public onlyOwner returns (bool) {
        require(_collateralAssetData[token].isEnabled == true, "collateral not supported");
        require(newAllowedRate >= 1 ether, "ratio should not be less than 1");

        emit CollateralAllowedRateChanged(
            token,
            _collateralAssetData[token].allowedRate,
            newAllowedRate,
            _collateralAssetData[token].index,
            msg.sender,
            block.number
        );
        _collateralAssetData[token].allowedRate = newAllowedRate;
        return true;
    }

    // ** COLLATERAL OPERATIONS ** //

    /**
     * @notice allows deposit of collateral by user
     *
     * @param token contract address of the token
     * @param amount amount of tokens to be deposited
     *
     * Emits a {CollateralDeposited} event.
     *
     * @return bool
     *
     * @dev amount in atomic units
     */
    function depositCollateral(address token, uint256 amount)
        public
        onlySupportedCollateral(token)
        nonReentrant
        returns (bool)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _addCollateral(msg.sender, token, amount);
        IArableLiquidation liquidation = IArableLiquidation(_addressRegistry.getArableLiquidation());
        liquidation.removeFlagIfHealthy(msg.sender);
        return true;
    }

    /**
     * @notice allows withdrawal of collateral by user
     *
     * @param token contract address of the token
     * @param amount amount of tokens to be withdrawn
     *
     * Emits a {CollateralWithdrawn} event.
     *
     * @return bool
     *
     * @dev amount in atomic units
     */
    function withdrawCollateral(address token, uint256 amount)
        public
        onlySupportedCollateral(token)
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        // Checks if user has previously deposited the collateral
        require(_userCollateralBalance(msg.sender, token) >= amount, "Collateral: not enough tokens");

        require(
            maxWithdrawableTokenVal(msg.sender, token) >= calculateTokenValue(token, amount),
            "Collateral: not enough collateral"
        );

        _removeCollateral(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        return true;
    }

    /**
     * @notice internal function to increment user's collateral amount
     *
     * @param user address of the user
     * @param token address of the token contract
     * @param amount amount of tokens
     */
    function _addCollateral(
        address user,
        address token,
        uint256 amount
    ) internal {
        _individualCollateral[user][token] += amount;
        emit CollateralDeposited(user, token, amount, block.number);
    }

    /**
     * @notice internal function to decrement user's collateral amount
     *
     * @param user address of the user
     * @param token address of the token contract
     * @param amount amount of tokens
     */
    function _removeCollateral(
        address user,
        address token,
        uint256 amount
    ) internal {
        require(_individualCollateral[user][token] >= amount, "user token collateral should be bigger than amount");
        _individualCollateral[user][token] -= amount;
        emit CollateralWithdrawn(user, token, amount, block.number);
    }

    /**
     * @notice external liquidation collateral that is called from liquidation
     * contract only
     *
     * @dev be careful with accessControl `onlyAddress`
     *
     *
     * @param user address of the user to be liquidated
     * @param beneficiary address of the liquidator
     * @param liqAmount amount to be liquidated in terms of collateral
     *
     * Emits a {Liquidate} event.
     * Emits a {CollateralDeposited} event.
     * Emits a {CollateralWithdrawn} event.
     *
     */

    function _liquidateCollateral(
        address user,
        address beneficiary,
        uint256 liqAmount
    ) external onlyAddress("ARABLE_LIQUIDATION") nonReentrant {
        // Get user balance
        uint256 userBalance_ = calculateCollateralValue(user);
        _removeDebtFromUser(user, currentDebt(user));
        emit Liquidate(user, beneficiary, liqAmount, block.number);

        // Calculate decimal collateralization rate
        uint256 collateralizationRate_ = (liqAmount * 1 ether) / userBalance_;

        // Check if collateral balance is bigger than liquidation amount
        // require(collateralizationRate_ <= 1 ether, "Can NOT liquidate more than what user has");
        // Note: this case happens when a user's debt * liquidationPenalty is bigger than collateral
        // - but for good protocol maintenance, these positions should be removed

        // Liquidate from all collaterals for proportional amounts
        for (uint256 i = 0; i < _supportedCollaterals.length; i++) {
            // Check if user has balance of that type of collateral
            address collateral = _supportedCollaterals[i];
            uint256 collateralBalance_ = _userCollateralBalance(user, collateral);

            if (collateralBalance_ > 0) {
                // Calculate the proportional amount to be removed from user's collateral balance
                uint256 toBeRemoved_ = (collateralBalance_ * collateralizationRate_) / 1 ether;
                if (toBeRemoved_ > collateralBalance_) {
                    toBeRemoved_ = collateralBalance_;
                }

                // Remove from the user + add it to beneficiary
                _removeCollateral(user, _supportedCollaterals[i], toBeRemoved_);

                // withdraw collateral token after liquidation
                IERC20(collateral).safeTransfer(beneficiary, toBeRemoved_);
            }
        }
    }

    function getSupportedCollaterals() external view returns (address[] memory) {
        return _supportedCollaterals;
    }

    function getSupportedCollateralsCount() external view returns (uint256) {
        return _supportedCollaterals.length;
    }

    function getTotalDebt() external view returns (uint256) {
        return _totalDebt;
    }

    /**
     * @notice function to return the user's risk rate
     * this function is used to calculate if user is flaggable or not
     *
     * @param user address of the user
     *
     * @return uint256 risk rate in decimals
     */
    function userRiskRate(address user) public view returns (uint256) {
        // maxDebt: 1 currDebt: 2    =>   rate: 200%
        // maxDebt: 1 currDebt: 1    =>   rate: 100%
        // maxDebt: 1 currDebt: 0.5  =>   rate: 50%
        // maxDebt: 0 currDebt: 0    =>   rate: 0%
        // maxDebt: 0 currDebt: 1    =>   rate: 10000% - force-liquidatable

        uint256 maxDebt = maxIssuableArUSD(user);
        uint256 currDebt = currentDebt(user);
        if (maxDebt == 0) {
            // Note: this could happen in following cases
            // 1) an asset is disabled for collateral
            // 2) collateral is fully liquidated
            // 3) user never added collateral
            if (currDebt == 0) {
                return 0;
            }
            return 100 ether; // 10000%
        }
        return (currDebt * 1 ether) / maxDebt;
    }

    /**
     * @notice calculates maximum issuable arUSD by the user
     *
     * @param user address of the user
     *
     * @return uint
     *
     * @dev could be gas optimized by checking whether if clause is
     * consuming too much gas or not
     */
    function maxIssuableArUSD(address user) public view returns (uint256) {
        uint256 maxIssuable = 0;

        // Loop through all supported collaterals
        for (uint256 i = 0; i < _supportedCollaterals.length; i++) {
            if (_userCollateralBalance(user, _supportedCollaterals[i]) > 0) {
                uint256 allowedRate = _collateralAssetData[_supportedCollaterals[i]].allowedRate;
                if (allowedRate > 0) {
                    uint256 collateralValue = _calculateSingleCollateralValue(user, _supportedCollaterals[i]);
                    // Multiply by (10**18) to allow decimal calculation on `allowedRate`
                    maxIssuable += (collateralValue * 1 ether) / allowedRate;
                }
            }
        }
        return maxIssuable;
    }

    /**
     * @notice returns user's current debt in USD
     *
     * @param user user's wallet address
     *
     * @return uint debt amount
     */
    function currentDebt(address user) public view returns (uint256) {
        if (_totalDebtFactor == 0) {
            return 0;
        }
        return (_totalDebt * _debtFactor[user]) / _totalDebtFactor;
    }

    /**
     * @notice view function to return user's collateral value in USD
     *
     * @param user user's wallet
     *
     * @return uint collateral amount
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        uint256 calculatedValue_ = 0;
        for (uint256 i = 0; i < _supportedCollaterals.length; i++) {
            if (_userCollateralBalance(user, _supportedCollaterals[i]) > 0) {
                calculatedValue_ += _calculateSingleCollateralValue(user, _supportedCollaterals[i]);
            }
        }
        return calculatedValue_;
    }

    /**
     * @notice function that returns user's individual collateral amount
     *
     * @param user address of the user
     * @param token contract address of the token to query
     *
     * @return uint amount of tokens collateralized
     */
    function _userCollateralBalance(address user, address token) public view returns (uint256) {
        return _individualCollateral[user][token];
    }

    /**
     * @notice calculates single collateral value in USD
     *
     * @dev divide by (10**18) because of decimal calculation
     *
     * @param user address of the user
     * @param token contract address of the token
     *
     * @return uint value in USD
     */
    function _calculateSingleCollateralValue(address user, address token) internal view returns (uint256) {
        IArableOracle oracle = IArableOracle(_addressRegistry.getArableOracle());
        uint256 tokenPrice = oracle.getPrice(token);

        // convert to normalized collateral balance with 18 decimals and return usd value
        uint256 decimals = IERC20Extented(token).decimals();
        uint256 normalizedCollateralBalance = (_userCollateralBalance(user, token) * 1 ether) / (10**decimals);
        return (normalizedCollateralBalance * tokenPrice) / 1 ether;
    }

    function maxWithdrawableTokenVal(address user, address token) public view returns (uint256) {
        uint256 maxDebt = maxIssuableArUSD(user);
        uint256 curDebt = currentDebt(user);
        if (maxDebt <= curDebt) {
            return 0;
        }
        return (_collateralAssetData[token].allowedRate * (maxDebt - curDebt)) / 1 ether;
    }

    function maxWithdrawableTokenAmount(address user, address token) public view returns (uint256) {
        IArableOracle oracle = IArableOracle(_addressRegistry.getArableOracle());
        uint256 tokenPrice = oracle.getPrice(token);
        if (tokenPrice == 0) {
            return 0;
        }
        uint256 userTokenDeposit = _userCollateralBalance(user, token);
        uint256 maxWithdrawable = (maxWithdrawableTokenVal(user, token) * 1 ether) / tokenPrice;
        if (userTokenDeposit < maxWithdrawable) {
            return userTokenDeposit;
        }
        return maxWithdrawable;
    }

    function calculateTokenValue(address token, uint256 amount) internal view returns (uint256) {
        IArableOracle oracle = IArableOracle(_addressRegistry.getArableOracle());
        uint256 tokenPrice = oracle.getPrice(token);
        return (amount * tokenPrice) / 1 ether;
    }

    // ** STAKE & MINT FUNCTIONS ** //

    /**
     * @notice mints requested amount of arUSD
     *
     * @param amount amount of arUSD to be minted
     *
     * Emits a {Mint} event.
     *
     * @return bool - to enable calls from other contracts
     */
    function mint(uint256 amount) public nonReentrant whenNotPaused returns (bool) {
        require(maxIssuableArUSD(msg.sender) >= currentDebt(msg.sender) + amount, "Not enough collateral");
        _addDebtFromUser(msg.sender, amount);
        emit Mint(msg.sender, amount, block.number);
        IArableSynth(IArableManager(_addressRegistry.getArableManager()).getSynthAddress(_arUSD)).mint(
            msg.sender,
            amount
        );
        return true;
    }

    /**
     * @notice burns arUSD to free collateral & remove debt
     *
     * @param amount amount of arUSD to be burned
     *
     * @return bool - to enable calls from other contracts
     */
    function burn(address beneficiary, uint256 amount) public nonReentrant whenNotPaused returns (bool) {
        require(currentDebt(beneficiary) >= amount, "Can't burn more than debt");
        // burn tokens from msg.sender
        IArableSynth(IArableManager(_addressRegistry.getArableManager()).getSynthAddress(_arUSD)).burnFrom(
            msg.sender,
            amount
        );
        // remove debt from beneficiary
        _removeDebtFromUser(beneficiary, amount);
        emit Burn(msg.sender, amount, block.number);

        IArableLiquidation liquidation = IArableLiquidation(_addressRegistry.getArableLiquidation());
        liquidation.removeFlagIfHealthy(msg.sender);
        return true;
    }

    /**
     * @notice internal function to increment user's and total debt
     *
     * @dev if collateral contract's address is added as debt manager
     * to the address registery, total debt increment function could be used
     * instead of _totalDebt += amount
     *
     * @param user address of the user
     * @param amount amount of arUSD to be added as debt
     */
    function _addDebtFromUser(address user, uint256 amount) internal {
        _incrementDebtRate(user, calculateDebtFactor(amount));
        _totalDebt += amount;
        emit TotalDebtUpdate(_totalDebt, block.timestamp);
    }

    /**
     * @notice internal function to decrease user's and total debt
     *
     * @dev if collateral contract's address is added as debt manager
     * to the address registery, total debt decrease function could be used
     * instead of _totalDebt -= amount
     *
     * @param user address of the user
     * @param amount amount of arUSD to be removed from debt
     */
    function _removeDebtFromUser(address user, uint256 amount) internal {
        _decrementDebtRate(user, calculateDebtFactor(amount));
        require(_totalDebt >= amount, "totalDebt should be bigger than amount");
        _totalDebt -= amount;
        emit TotalDebtUpdate(_totalDebt, block.timestamp);
    }

    /**
     * @notice view function to calculate debt factor with given amount
     *
     * @param amount amount of arUSD
     *
     * @return uint returns the debt factor
     */
    function calculateDebtFactor(uint256 amount) public view returns (uint256) {
        if (_totalDebtFactor == 0 || _totalDebt == 0) {
            return amount;
        }
        return (_totalDebtFactor * amount) / _totalDebt;
    }

    /**
     * @notice internal function to increment debt rate
     *
     * @param user address of the user
     * @param amount calculated debt factor
     */
    function _incrementDebtRate(address user, uint256 amount) internal {
        _debtFactor[user] += amount;
        _totalDebtFactor += amount;
        emit UserDebtFactorIncrease(user, amount, block.number);
    }

    /**
     * @notice internal function to decrement debt rate
     *
     * @param user address of the user
     * @param amount calculated debt factor
     */
    function _decrementDebtRate(address user, uint256 amount) internal {
        _debtFactor[user] -= amount;
        _totalDebtFactor -= amount;
        emit UserDebtFactorDecrease(user, amount, block.number);
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
}
