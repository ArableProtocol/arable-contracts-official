// SPDX-License-Identifier: MIT

/// @title Arable Liquidity Contract
/// @author Nithronium

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableCollateral.sol";
import "./interfaces/IArableSynth.sol";

contract ArableLiquidation is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    string private constant _arUSD = "arUSD";

    /**
     * @dev state variable for holding Address registry object
     *
     * @dev instead of using `collateralContract()` state variable,
     * the collateral contract could be re-declared each time it is
     * required, however to optimize gas, considering collateral
     * contract wouldn't be changing that often, I set a state variable
     */

    IArableAddressRegistry private _addressRegistry;

    /**
     * @dev state variables for holding liquidation rate and
     * immediate liquidation rate as well as liquidation delay
     *
     * @dev the `_liquidationRate` and `_immediateLiquidationRate`
     * are in decimals, for example use (3 * 10**17) for 0.3
     *
     * @dev liquidationDelay is in SECONDS and not miliseconds.
     */
    uint256 public _liquidationRate;
    uint256 public _immediateLiquidationRate;
    uint256 public _liquidationDelay;
    uint256 public _liquidationPenalty;

    struct LiquidationEntry {
        uint256 _liquidationId;
        uint256 _liquidationDeadline;
    }

    /**
     * @dev state variable for holding flagged liquidation counter
     */
    uint256 private _liquidationCounter;

    /**
     * @dev mapping of the flagged liquidation entries per address
     *
     * @dev an address can be flagged only once, think if we can
     * create multiple flags for the same address
     */
    mapping(address => LiquidationEntry) private _liquidationEntries;

    event LiquidationRateChanged(uint256 oldRate, uint256 newRate, uint256 blockNumber);
    event ImmediateLiquidationRateChanged(uint256 oldRate, uint256 newRate, uint256 blockNumber);
    event LiquidationDelayChanged(uint256 oldDelay, uint256 newDelay, uint256 blockNumber);
    event LiquidationPenaltyChanged(uint256 oldPanelty, uint256 newPanelty, uint256 blockNumber);
    event FlaggedForLiquidation(address user, uint256 liquidationId, uint256 liquidationDeadline);
    event RemoveFlagForLiquidation(address user, uint256 liquidationId);
    event Pause();
    event Unpause();

    function initialize(address addressRegistry, uint256 liquidationDelay_) external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __ReentrancyGuard_init();
        __Pausable_init_unchained();

        setAddressRegistry(addressRegistry);
        setImmediateLiquidationRate(2 ether); // 200%
        setLiquidationRate(1.5 ether); // 150%
        setLiquidationPenalty(1.1 ether); // 110%
        setLiquidationDelay(liquidationDelay_); // 1 day on testnet - 3 days for mainnet
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

    function collateralContract() internal view returns (IArableCollateral) {
        return IArableCollateral(_addressRegistry.getArableCollateral());
    }

    function getLiquidationCounter() external view returns (uint256) {
        return _liquidationCounter;
    }

    function getLiquidationEntry(address user) external view returns (LiquidationEntry memory) {
        return _liquidationEntries[user];
    }

    function removeFlagIfHealthy(address user) external whenNotPaused {
        if (isFlaggable(user) == false && isFlagged(user) == true) {
            _liquidationEntries[user]._liquidationDeadline = 0;
            emit RemoveFlagForLiquidation(user, _liquidationEntries[user]._liquidationId);
        }
    }

    function setAddressRegistry(address newAddressRegistry) public onlyOwner {
        require(newAddressRegistry != address(0), "Invalid address");

        _addressRegistry = IArableAddressRegistry(newAddressRegistry);
    }

    function setLiquidationRate(uint256 newRate) public onlyOwner {
        emit LiquidationRateChanged(_liquidationRate, newRate, block.number);
        _liquidationRate = newRate;
    }

    function setImmediateLiquidationRate(uint256 newRate) public onlyOwner {
        emit ImmediateLiquidationRateChanged(_immediateLiquidationRate, newRate, block.number);
        _immediateLiquidationRate = newRate;
    }

    function setLiquidationDelay(uint256 newDelay) public onlyOwner {
        emit LiquidationDelayChanged(_liquidationDelay, newDelay, block.number);
        _liquidationDelay = newDelay;
    }

    function setLiquidationPenalty(uint256 newPenalty) public onlyOwner {
        emit LiquidationDelayChanged(_liquidationPenalty, newPenalty, block.number);
        _liquidationPenalty = newPenalty;
    }

    /**
     * @notice modifier to check whether an account can be flagged or not
     *
     * @param user address of the user to be flagged
     */
    modifier onlyFlaggable(address user) {
        // Require debt is larger than current issuable to have safe flagging
        require(collateralContract().currentDebt(user) > collateralContract().maxIssuableArUSD(user), "Can't flag");
        // Require user is not flagged before
        require(_liquidationEntries[user]._liquidationDeadline == 0, "Already flagged");
        // Calculate if user passed the threshold to be flagged
        require(userRiskRate(user) >= _liquidationRate, "User has enough collateral");
        _;
    }

    function isFlaggable(address user) public view returns (bool) {
        // Require debt is larger than current issuable to have safe flagging
        if (collateralContract().currentDebt(user) <= collateralContract().maxIssuableArUSD(user)) {
            return false;
        }
        // Calculate if user passed the threshold to be flagged
        if (userRiskRate(user) < _liquidationRate) {
            return false;
        }
        return true;
    }

    function isFlagged(address user) public view returns (bool) {
        return _liquidationEntries[user]._liquidationDeadline != 0;
    }

    function userRiskRate(address user) public view returns (uint256) {
        return collateralContract().userRiskRate(user);
    }

    /**
     * @notice function to flag a user to be liquidated with delay
     * delay is taken from the state variable `_liquidationDelay`
     *
     * @dev an event should be thrown instead of return value
     *
     * @param user address of the user
     *
     * @return uint counter of the liquidation entry
     */
    function flagForLiquidation(address user) public onlyFlaggable(user) whenNotPaused returns (uint256) {
        _liquidationCounter += 1;
        _liquidationEntries[user]._liquidationId = _liquidationCounter;
        _liquidationEntries[user]._liquidationDeadline = block.timestamp + _liquidationDelay;
        emit FlaggedForLiquidation(
            user,
            _liquidationEntries[user]._liquidationId,
            _liquidationEntries[user]._liquidationDeadline
        );
        return _liquidationCounter;
    }

    /**
     * @notice function that actually liquidates the user
     *
     * @notice this function has 2 purposes, it either
     * immediately liquidates an account without delay if the
     * collateralization ratio have been very high (debt/max issuable arUSD)
     * and if the `userRiskRate_` is not very high,
     * function requires user to be flagged first
     *
     * @dev be aware of the decimal calculations
     *
     * @param user address of the user
     */
    function liquidate(address user) public nonReentrant whenNotPaused {
        // Get user's current debt
        uint256 userDebt_ = collateralContract().currentDebt(user);

        // TODO: adjust balance check function to work properly
        // TODO: don't hard code the arUSD and take it from variable to be safe
        IArableSynth arUSDContract_ = IArableSynth(
            IArableManager(_addressRegistry.getArableManager()).getSynthAddress(_arUSD)
        );
        // Check if beneficiary's balance is enough to liquidate the user
        require(arUSDContract_.balanceOf(msg.sender) >= userDebt_, "not enough arUSD to liquidate");

        // Calculate risk rate
        uint256 userRiskRate_ = userRiskRate(user);
        // Check threshold
        require(userRiskRate_ >= _liquidationRate, "User cant be liquidated");
        // Liquidate immediately if user is above the threshold
        if (userRiskRate_ >= _immediateLiquidationRate) {
            return _liquidate(user, msg.sender, userDebt_);
        } else {
            // Require user to be flagged first
            require(_liquidationEntries[user]._liquidationDeadline != 0, "User not flagged");
            // Check deadline
            require(_liquidationEntries[user]._liquidationDeadline < block.timestamp, "Deadline not arrived yet");
            _liquidate(user, msg.sender, userDebt_);
        }

        // Clear the user's flag status
        delete _liquidationEntries[user];
    }

    /**
     * @notice internal liquidation function
     *
     * @dev the liquidation actually happens on the collateral contract
     * this internal function handles final checks & burn of arUSD mechanism
     *
     * @param user address of the user to be liquidated
     * @param beneficiary address of the liquidator (who will receive rewards)
     * @param userDebt the debt of the user to be liquidated
     */
    function _liquidate(
        address user,
        address beneficiary,
        uint256 userDebt
    ) internal {
        IArableSynth arUSDContract_ = IArableSynth(
            IArableManager(_addressRegistry.getArableManager()).getSynthAddress(_arUSD)
        );

        arUSDContract_.burnFrom(beneficiary, userDebt);

        // Adjust liquidation amount with liquidation penalty
        // Notice decimal calculation
        uint256 liquidationAmount_ = (userDebt * _liquidationPenalty) / 1 ether;

        // Go to collateral to liquidate the user
        collateralContract()._liquidateCollateral(user, beneficiary, liquidationAmount_);
    }
}
