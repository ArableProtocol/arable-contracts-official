# MVP v1 spec

MVP v1 is designed to provide minimum concept for synthetic farming.

## Functional spec

- Only admin can create new synths
- Admin can register farms for synths
- Admin can set the oracle price and reward information - called by bot
- Page for generalized epoch based farming based on oracle
  A. Here, epoch will be a day and rewards are distributed per day
  B. Oracle provides reward info on a daily basis before daily reward distribution
- Page for generalized instant exchange for synths
- Page for synths testnet faucet for people who want to mint - once per address per day
- Page for supported synths and APY information per pool based on oracle

## Contract design

### arERC20 contract (ArableSynth)

Generalized ERC20 token contract for synths, mintable by admins, staking or exchange contract

### Root contract (ArableManager)

Synths registration contract

Functions

```
    registerToken(tokenName, tokenSymbol, tokenDecimal, tokenInitialSupply) onlyAdmin
    listToken() returns (address[])
    disableToken(token_address)
    enableToken(token_address)
```

### Oracle contract (ArableOracle)

Arable's internal oracle that provides price and reward APR info per staking_id.

Functions

```
    price(token) view returns(price uint256)
    reward(stake_id, reward_token) view returns(dailyRewardRate uint256)
    where dailyRewardRate = dailyRewardTokenCount/stakeTokenCount*100
    registerPrice(token, price) onlyAdmin
    registerReward(stake_id, reward_token, dailyRewardRate) onlyAdmin
```

### Staking contract

Generalized epoch basis staking contract (epoch = 1 day)

Functions

```
    Uint256 currentEpoch
    Uint256 rewardRateSum[staking_id][reward_token][epoch]
    updateRewardRateSum(staking_id, reward_token) - run by bot or anyone per epoch
    registerFarm(staking_id, staking_token) onlyAdmin
    disableStaking(staking_id) onlyAdmin
    enableStaking(staking_id) onlyAdmin
    stake(staking_id, amount)
    claimReward(staking_id, rewardToken)
    unstake(staking_id, amount)
    estimatedRewardInUsd(staking_id)
    getStakingIds(staker) view
    getAllStakingIds() view
```

### Exchange contract

Implement swap between two synths based on exchange rate on oracle

Functions

```
swap(in_token, in_amount, out_token)
```

### Collateral contract

Implement collateral deposit and arUSD mint

### Liquidation contract

Implement liquidation of unhealthy accounts
