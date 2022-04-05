// SPDX-License-Identifier: MIT

/// @title Arable Liquidity Contract
/// @author Nithronium


pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableCollateral.sol";
import "./interfaces/IArableSynth.sol";
import "hardhat/console.sol";

contract ArableLiquidation is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    string constant private _arUSD = "arUSD";

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
        uint _liquidationId;
        uint _liquidationDeadline;
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

    event LiquidationRateChanged(uint oldRate, uint newRate, uint blockNumber);
    event ImmediateLiquidationRateChanged(uint oldRate, uint newRate, uint blockNumber);
    event LiquidationDelayChanged(uint oldDelay, uint newDelay, uint blockNumber);
    event LiquidationPenaltyChanged(uint oldPanelty, uint newPanelty, uint blockNumber);
    event FlaggedForLiquidation(address user, uint liquidationId, uint liquidationDeadline);
    event RemoveFlagForLiquidation(address user, uint liquidationId);

    constructor (address addressRegistry) {
        setAddressRegistry(addressRegistry);
        setImmediateLiquidationRate(2 ether); // 200%
        setLiquidationRate(1.5 ether); // 150%
        setLiquidationPenalty(1.1 ether); // 110%
        setLiquidationDelay(86400); // TODO: 1 day on testnet - update to 3 days for mainnet
    }

    function collateralContract() internal view returns (IArableCollateral){
        return IArableCollateral(_addressRegistry.getArableCollateral());
    }

    function getLiquidationCounter() external view returns (uint256) {
        return _liquidationCounter;
    }

    function getLiquidationEntry(address user) external view returns (LiquidationEntry memory) {
        return _liquidationEntries[user];
    }

    
    function setAddressRegistry(address newAddressRegistry) public onlyOwner() {
        _addressRegistry = IArableAddressRegistry(newAddressRegistry);
    }
    
    function setLiquidationRate(uint newRate) public onlyOwner() {
        emit LiquidationRateChanged(_liquidationRate, newRate, block.number);
        _liquidationRate = newRate;
    }

    function setImmediateLiquidationRate(uint newRate) public onlyOwner() {
        emit ImmediateLiquidationRateChanged(_immediateLiquidationRate, newRate, block.number);
        _immediateLiquidationRate = newRate;
    }

    function setLiquidationDelay(uint newDelay) public onlyOwner() {
        emit LiquidationDelayChanged(_liquidationDelay, newDelay, block.number);
        _liquidationDelay = newDelay;
    }

    function setLiquidationPenalty(uint newPenalty) public onlyOwner() {
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
        require(collateralContract().currentDebt(user) 
            > collateralContract().maxIssuableArUSD(user), "Can't flag");
        // Require user is not flagged before
        require(_liquidationEntries[user]._liquidationDeadline == 0, "Already flagged");
        // Calculate if user passed the threshold to be flagged
        require(userRiskRate(user) >= _liquidationRate, "User has enough collateral");
        _;
    }

    function isFlaggable(address user) public view returns (bool) {
        // Require debt is larger than current issuable to have safe flagging
        if(collateralContract().currentDebt(user) <= collateralContract().maxIssuableArUSD(user)) {
            return false;
        }
        // Calculate if user passed the threshold to be flagged
        if(userRiskRate(user) < _liquidationRate) {
            return false;
        }
        return true;
    }

    function isFlagged(address user) public view returns (bool) {
        return _liquidationEntries[user]._liquidationDeadline != 0;
    }

    /**
     * @notice function to return the user's risk rate
     * this function is used to calculate if user is flaggable or not
     *
     * @param user address of the user
     *
     * @return uint risk rate in decimals
     */
    function userRiskRate(address user) public view returns (uint) {
        // maxDebt: 1 currDebt: 2    =>   rate: 200%
        // maxDebt: 1 currDebt: 1    =>   rate: 100%
        // maxDebt: 1 currDebt: 0.5  =>   rate: 50%
        // maxDebt: 0 currDebt: 0    =>   rate: 0%
        // maxDebt: 0 currDebt: 1    =>   rate: 10000% - force-liquidatable

        uint256 maxDebt = collateralContract().maxIssuableArUSD(user);
        uint256 currDebt = collateralContract().currentDebt(user);
        if (maxDebt == 0 ) {
            // Note: this could happen in following cases
            // 1) an asset is disabled for collateral 
            // 2) collateral is fully liquidated
            // 3) user never added collateral
            if (currDebt == 0) {
                return 0;
            }
            return 100 ether; // 10000%
        }
        return currDebt * 1 ether / maxDebt;
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
    function flagForLiquidation(address user) public onlyFlaggable(user) returns (uint) {
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

     function removeFlagIfHealthy(address user) external {
        if (isFlaggable(user) == false && isFlagged(user) == true) {
            _liquidationEntries[user]._liquidationDeadline = 0;
            emit RemoveFlagForLiquidation(
                user, 
                _liquidationEntries[user]._liquidationId
            );
        }
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
    function liquidate(address user) public nonReentrant {
        // Get user's current debt
        uint userDebt_ = collateralContract().currentDebt(user);

        // TODO: adjust balance check function to work properly
        // TODO: don't hard code the arUSD and take it from variable to be safe
        IArableSynth arUSDContract_ = IArableSynth(
            IArableManager(_addressRegistry.getArableManager())
            .getSynthAddress(_arUSD));
        // Check if beneficiary's balance is enough to liquidate the user
        require(arUSDContract_.balanceOf(msg.sender) >= userDebt_, "not enough arUSD to liquidate");

        // Calculate risk rate
        uint userRiskRate_ = userRiskRate(user);
        // Check threshold
        require(userRiskRate_ >= _liquidationRate, "User cant be liquidated");
        // Liquidate immediately if user is above the threshold
        if(userRiskRate_ >= _immediateLiquidationRate) {
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
    function _liquidate(address user, address beneficiary, uint userDebt) internal {
        IArableSynth arUSDContract_ = IArableSynth(
            IArableManager(_addressRegistry.getArableManager())
            .getSynthAddress(_arUSD));

        arUSDContract_.burnFrom(beneficiary, userDebt);

        // Adjust liquidation amount with liquidation penalty
        // Notice decimal calculation
        uint liquidationAmount_ = userDebt * _liquidationPenalty / 1 ether;

        // Go to collateral to liquidate the user
        collateralContract()._liquidateCollateral(user, beneficiary, liquidationAmount_);
    }
}