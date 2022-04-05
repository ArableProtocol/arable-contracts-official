// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IArableOracle.sol";
import "./interfaces/IArableSynth.sol";
import "./interfaces/IArableManager.sol";
import "./interfaces/IArableAddressRegistry.sol";
import "./interfaces/IArableFeeCollector.sol";
import "./libs/ArableFees.sol";

// Implement swap between two synths based on exchange rate on oracle
contract ArableExchange is Ownable, ReentrancyGuard {
    address public addressRegistry;

    constructor(address addressRegistry_) {
        addressRegistry = addressRegistry_;
    }

    function swapSynths(address inToken, uint256 inAmount, address outToken) external nonReentrant {
        require(inToken != address(0x0), "inToken should be set");
        require(outToken != address(0x0), "outToken should be set");
        require(inAmount != 0, "In amount should not be ZERO");

        address manager = IArableAddressRegistry(addressRegistry).getArableManager();
        IArableManager managerContract = IArableManager(manager);
        require(managerContract.isSynth(inToken), "inToken should be synth");
        require(managerContract.isSynth(outToken), "outToken should be synth");
        require(!managerContract.isSynthDisabled(inToken), "inToken should be enabled");
        require(!managerContract.isSynthDisabled(outToken), "outToken should be enabled");

        address oracle = IArableAddressRegistry(addressRegistry).getArableOracle();
        IArableOracle oracleContract = IArableOracle(oracle);
        uint256 inTokenPrice = oracleContract.getPrice(inToken);
        uint256 outTokenPrice = oracleContract.getPrice(outToken);

        require(inTokenPrice != 0, "inToken price should be set");
        require(outTokenPrice != 0, "outToken price should be set");

        IERC20(inToken).transferFrom(msg.sender, address(this), inAmount);
        
        address feeCollectorAddress = IArableAddressRegistry(addressRegistry).getArableFeeCollector();
        IArableFeeCollector arableCollector = IArableFeeCollector(feeCollectorAddress);
        
        uint256 fees = arableCollector.calculateFees(inToken, inAmount, msg.sender, ArableFees.Model.SYNTHS_X);
        IERC20(inToken).approve(feeCollectorAddress,fees);
        arableCollector.payFeesFor(inToken, inAmount, msg.sender, ArableFees.Model.SYNTHS_X); 

        uint256 outAmount = inTokenPrice * (inAmount-fees) / outTokenPrice;
        IArableSynth(inToken).burn(inAmount-fees);
        IArableSynth(outToken).mint(msg.sender, outAmount);
    }
}
