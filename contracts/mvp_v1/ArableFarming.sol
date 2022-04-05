// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IArableOracle.sol";
import "./interfaces/IArableSynth.sol";
import "./interfaces/IArableFarming.sol";
import "./interfaces/IArableCollateral.sol";
import "./interfaces/IArableAddressRegistry.sol";

// Generalized epoch basis staking contract (epoch = 1 day)
contract ArableFarming is Ownable, IArableFarming, ReentrancyGuard {
    address public addressRegistry;
    uint256 public epochZeroTime;
    // TODO: on mainnet, this should be configured to 1 day
    uint256 public epochDuration = 8 hours;

    // rewardRateSum[farmId][rewardToken][epoch]: rewardRateSum from epoch0 to epoch for stakingFarm's rewardToken
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public rewardRateSum;
    // lastClaimEpoch[farmId][rewardToken][address]: last claimed epoch by address
    mapping(uint256 => mapping(address => mapping(address => uint256))) public lastClaimEpoch;
    // farm start epoch
    mapping(uint256 => uint256) public farmStartEpoch;
    mapping(uint256 => mapping(address => uint256)) public lastRewardRateSumEpoch;

    address[] public stakingTokens;
    mapping(uint256 => bool) public isDisabledFarm;

    // staking amount by farm and address
    mapping(uint256 => mapping(address => uint256)) public stakingAmount;

    // staking pools per address
    // user_address => staking_pools 
    mapping(address => uint256[]) public usedFarmingPools;
    // user_address => staking_pool => bool 
    mapping(address => mapping(uint256 => bool)) public isUsedFarmingPool;

    // reward tokens per staking pool, limit to 3 tokens to be simple
    mapping(uint256 => mapping(uint256 => address)) public rewardTokens;
    mapping(uint256 => uint256) public rewardTokenLengths;
    mapping(uint256 => mapping(address => bool)) public _isRewardToken;

    event RegisterStakingPool(uint256 farmId, address stakingToken);
    event Deposit(uint256 farmId, address stakingToken, uint256 amount);
    event Withdraw(uint256 farmId, address stakingToken, uint256 amount);
    event Claim(uint256 farmId, address rewardToken, uint256 amount);

    modifier onlyValidFarmId(uint256 farmId) {
        require(farmId < stakingTokens.length, "not a valid farm id");
        _;
    }

    constructor(address addressRegistry_) {
        addressRegistry = addressRegistry_;
        epochZeroTime = block.timestamp;
    }

    // create a new farm
    function registerFarm(address stakingToken) public override onlyOwner returns(uint256 farmId) {
        require(stakingToken != address(0x0), "stakingToken should be set");
        stakingTokens.push(stakingToken);
        farmId = stakingTokens.length - 1;
        emit RegisterStakingPool(farmId, stakingToken);
        return farmId;
    }

    function setRewardTokens(uint256 farmId, address[] memory _rewardTokens) public override
        onlyOwner onlyValidFarmId(farmId) {
        deleteRewardTokens(farmId);
        uint256 curEpoch = currentEpoch();
        farmStartEpoch[farmId] = curEpoch;
        for (uint256 i = 0; i < _rewardTokens.length; i ++) {
            address rewardToken = _rewardTokens[i];
            rewardTokens[farmId][i] = rewardToken;
            _isRewardToken[farmId][rewardToken] = true;
            uint256 lastEpoch = lastRewardRateSumEpoch[farmId][rewardToken];
            uint256 lastEpochRewardSum = rewardRateSum[farmId][rewardToken][lastEpoch];
            lastRewardRateSumEpoch[farmId][rewardToken] = curEpoch;
            rewardRateSum[farmId][rewardToken][curEpoch] = lastEpochRewardSum;
        }
        rewardTokenLengths[farmId] = _rewardTokens.length;
    }

    function bulkRegisterFarm(address[] calldata farmToken_) external onlyOwner {
        for(uint256 i = 0; i < farmToken_.length; i++) {
            registerFarm(farmToken_[i]);
        }
    }

    function bulkSetRewardTokens(uint256[] calldata farmIds, address[][] calldata rewardTokens_) external onlyOwner {
        require(farmIds.length == rewardTokens_.length, "Please check your input data.");
        for(uint256 i=0; i < farmIds.length; i++) {
            setRewardTokens(farmIds[i], rewardTokens_[i]);
        }
    }

    function currentEpoch() public view override returns (uint256) {
        return (block.timestamp - epochZeroTime) / epochDuration;
    }

    // run by bot or anyone per epoch
    function updateRewardRateSum(uint256 farmId, address rewardToken) external override 
        nonReentrant onlyValidFarmId(farmId) {
        uint256 lastEpoch = lastRewardRateSumEpoch[farmId][rewardToken];
        uint256 curEpoch = currentEpoch();
        require(curEpoch > lastEpoch, "Refresh already up-to-date");


        address oracle = IArableAddressRegistry(addressRegistry).getArableOracle();
        IArableOracle oracleContract = IArableOracle(oracle);
        uint256 dailyRewardRate = oracleContract.getDailyRewardRate(farmId, rewardToken);
        lastRewardRateSumEpoch[farmId][rewardToken] = curEpoch;
        uint256 lastEpochRewardSum = rewardRateSum[farmId][rewardToken][lastEpoch];

        // Note: ideally, this should run epoch basis and for loop depth should be 1
        // In case this isn't maintained for a while, this script should run several times
        // until it's synchronized with current epoch
        // This is due to prevent potential gas overflow issue
        uint256 windowEndEpoch = curEpoch;
        if (windowEndEpoch > lastEpoch + 5) {
            windowEndEpoch = lastEpoch + 5;
        }
        for (lastEpoch = lastEpoch + 1; lastEpoch <= windowEndEpoch; lastEpoch ++) {
            rewardRateSum[farmId][rewardToken][lastEpoch] = lastEpochRewardSum + dailyRewardRate;
        }
    }

    function deleteRewardTokens(uint256 farmId) public override onlyOwner onlyValidFarmId(farmId) {
        for (uint256 i = 0; i < rewardTokenLengths[farmId]; i ++) {
            _isRewardToken[farmId][rewardTokens[farmId][i]] = false;
        }
        rewardTokenLengths[farmId] = 0;
    }

    function setIsDisabledFarm(uint256 farmId, bool isDisabled) external override onlyOwner onlyValidFarmId(farmId) {
        isDisabledFarm[farmId] = isDisabled;
    }

    function stake(uint256 farmId, uint256 amount) external override nonReentrant onlyValidFarmId(farmId) {
        require(!isDisabledFarm[farmId], "the operation is not allowed on disabled farm");
        require(amount > 0, "should stake positive amount");
        uint256 tokenBalance = IERC20(stakingTokens[farmId]).balanceOf(msg.sender);
        require(tokenBalance >= amount, "not enough balance for staking");

        // claim all the rewards before staking
        _claimAllRewards(farmId);

        IERC20(stakingTokens[farmId]).transferFrom(msg.sender, address(this), amount);
        stakingAmount[farmId][msg.sender] += amount;

        // register usedFarmingPools
        if (isUsedFarmingPool[msg.sender][farmId] == false) {
            usedFarmingPools[msg.sender].push(farmId);
            isUsedFarmingPool[msg.sender][farmId] = true;
        }

        emit Deposit(farmId, stakingTokens[farmId], amount);
    }

    function unstake(uint256 farmId, uint256 amount) external override nonReentrant onlyValidFarmId(farmId) {
        require(!isDisabledFarm[farmId], "the operation is not allowed on disabled farm");
        require(amount > 0, "should unstake positive amount");

        // claim all the rewards before unstaking
        _claimAllRewards(farmId);

        // TODO: we might need to add unstake notice period 
        stakingAmount[farmId][msg.sender] -= amount;
        IERC20(stakingTokens[farmId]).transfer(msg.sender, amount);

        emit Withdraw(farmId, stakingTokens[farmId], amount);
    }

    function claimAllRewards(uint256 farmId) public override nonReentrant {
        for (uint256 i = 0; i < rewardTokenLengths[farmId]; i ++) {
            _claimReward(farmId, rewardTokens[farmId][i]);
        }
    }

    function claimReward(uint256 farmId, address rewardToken) public override nonReentrant {
        _claimReward(farmId, rewardToken);
    }

    function _claimAllRewards(uint256 farmId) internal onlyValidFarmId(farmId) {
        for (uint256 i = 0; i < rewardTokenLengths[farmId]; i ++) {
            _claimReward(farmId, rewardTokens[farmId][i]);
        }
    }

    function _claimReward(uint256 farmId, address rewardToken) internal onlyValidFarmId(farmId) {
        require(!isDisabledFarm[farmId], "the operation is not allowed on disabled farm");

        uint256 curEpoch = currentEpoch();
        uint256 claimAmount = estimatedReward(farmId, rewardToken, msg.sender);

        lastClaimEpoch[farmId][rewardToken][msg.sender] = curEpoch;
        IArableSynth(rewardToken).mint(msg.sender, claimAmount);

        // update totalDebt for reward claim event    
        IArableAddressRegistry _addressRegistry = IArableAddressRegistry(addressRegistry);
        IArableOracle oracle = IArableOracle(_addressRegistry.getArableOracle());
        IArableCollateral collateral = IArableCollateral(_addressRegistry.getArableCollateral());
        uint256 tokenPrice = oracle.getPrice(rewardToken);
        if (tokenPrice > 0) {
            collateral.addToDebt(claimAmount * tokenPrice / 1 ether);
        }

        emit Claim(farmId, rewardToken, claimAmount);

        // TODO: handle the case someone mint after pretty long time which could make big system debt changes
        // - Possibly set maximum amount of tokens to be able to claim for specific token
        // - Too big rewards for long time stake should be cut
    }

    function estimatedReward(uint256 farmId, address rewardToken, address user) public view override returns (uint256) {
        uint256 curEpoch = currentEpoch();
        uint256 claimedEpoch = lastClaimEpoch[farmId][rewardToken][user];
        if (claimedEpoch < farmStartEpoch[farmId]) {
            claimedEpoch = farmStartEpoch[farmId];
        }
        uint256 curRewardRateSum = rewardRateSum[farmId][rewardToken][curEpoch];
        uint256 lastRewardRateSum = rewardRateSum[farmId][rewardToken][claimedEpoch];
        uint256 stakingAmt = stakingAmount[farmId][user];
        uint256 claimAmount = (curRewardRateSum - lastRewardRateSum) * stakingAmt / 1 ether;
        return claimAmount;
    }

    function getRewardTokens(uint256 farmId)
        external
        view
        override
        returns (address[] memory)
    {
        address[] memory tokens = new address[](rewardTokenLengths[farmId]);
        for (uint256 i = 0; i < rewardTokenLengths[farmId]; i++) {
            tokens[i] = rewardTokens[farmId][i];
        }
        return tokens;
    }

    function isRewardToken(uint256 farmId, address rewardToken) external view override returns (bool) {
        return _isRewardToken[farmId][rewardToken];
    }
}
