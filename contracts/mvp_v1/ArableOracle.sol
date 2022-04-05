// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./ArableSynth.sol";
import "./interfaces/IArableFarming.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableOracle.sol";
import "./interfaces/IArableManager.sol";

// Oracle for price and reward info
// TODO: for now, oracle is ownable for MVP v1 phase, should be converted to governance based one
contract ArableOracle is Ownable, IArableOracle, ReentrancyGuard {
    address public addressRegistry;

    mapping(address => uint256) public price;
    // since staking could have multiple reward token this is 2 dimensional mapping
    // dailyRewardRate[stakeId][rewardToken] = dailyRewardTokenCount/stakeTokenCount*10^18
    mapping(uint256 => mapping(address => uint256)) public dailyRewardRate;
    mapping(address => bool) public isAllowedProvider;

    // lastUpdate is to ensure oracle service is running
    uint256 public lastUpdate;

    // events
    event SetTokenPrice(address token, uint256 price, uint256 timestamp);
    event SetRewardRate(uint256 farmId, address rewardToken, uint256 rate, uint256 timestamp);

    modifier onlyAllowedProvider {
      require(isAllowedProvider[msg.sender], "Not an allowed oracle provider");
      _;
    }

    constructor(address addressRegistry_) {
        addressRegistry = addressRegistry_;
        isAllowedProvider[msg.sender] = true;
    }

    function setAllowedProvider(address provider_) external onlyOwner {
        isAllowedProvider[provider_] = true;
    }

    function unsetAllowedProvider(address provider_) external onlyOwner {
        isAllowedProvider[provider_] = false;
    }

    function registerPrice(address token_, uint256 price_) public onlyAllowedProvider {
        require(token_ != address(0x0), "Token should not be zero address");
        uint256 oldPrice = price[token_];
        price[token_] = price_;
        lastUpdate = block.timestamp;
        emit SetTokenPrice(token_, price_, block.timestamp);

        IArableAddressRegistry _addressRegistry = IArableAddressRegistry(addressRegistry);
        IArableManager manager = IArableManager(_addressRegistry.getArableManager());
        manager.onAssetPriceChange(token_, oldPrice, price_);
    }

    function registerRewardRate(
        uint256 farmId_,
        address token_,
        uint256 dailyRewardRate_
    ) public onlyAllowedProvider {
        require(token_ != address(0x0), "Reward token should not be zero address");
        address farming = IArableAddressRegistry(addressRegistry).getArableFarming();
        IArableFarming farmingContract = IArableFarming(farming);
        require(farmingContract.isRewardToken(farmId_, token_), "Not a reward token for the pool");
        dailyRewardRate[farmId_][token_] = dailyRewardRate_;
        lastUpdate = block.timestamp;

        emit SetRewardRate(farmId_, token_, dailyRewardRate_, block.timestamp);
    }

    function bulkPriceSet(address[] calldata tokens_, uint256[] calldata prices_) external onlyAllowedProvider {
        require(tokens_.length == prices_.length, "Please check you input data.");
        for(uint256 i=0; i < tokens_.length; i++) {
            registerPrice(tokens_[i], prices_[i]);
        }
    }

    function bulkRegisterRewardRate(
        uint256 farmId_, 
        address[] calldata rewardTokens_, 
        uint256[] calldata dailyRewardRates_) external onlyAllowedProvider {
        require(rewardTokens_.length == dailyRewardRates_.length, "Please check you input data.");
        for(uint256 i=0; i < rewardTokens_.length; i++) {
            registerRewardRate(farmId_, rewardTokens_[i], dailyRewardRates_[i]);
        }
    }

    function getPrice(address token) external view override returns (uint256) {
        return price[token];
    }

    function getDailyRewardRate(uint256 farmId, address token) external view override returns (uint256) {
        return dailyRewardRate[farmId][token];
    }
}
