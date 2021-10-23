//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract DelegatedStaking is Ownable, Initializable  {
    uint256 constant divider = 10**18; // 18 decimals used for scaling the rates
    uint128 validatorCoolDown; // how many epochs until validator unstaking is unlocked
    uint128 delegatorCoolDown; // how many epochs until delegator unstaking is unlocked
    uint128 maxCapMultiplier;
    uint128 validatorMinStakedRequired; // minimum # of tokens validator is required to have staked
    uint128 allocatedTokensPerEpoch; // # of tokens per epoch to be distributed
    uint128 rewardsLocked; // # of tokens the owner sent to the contract
    uint128 endEpoch; // the epoch when the contract will be out of allocated reward tokens
    uint128 totalGlobalShares; // global shares
    uint128 lastUpdateEpoch; // block # when the global exchange rate was updated last
    uint128 globalExchangeRate;
    uint128 validatorsN; // number of validators, used to get validator ids
    mapping(uint128 => Validator) validators; // id -> validator instance
    IERC20 CQT;

    struct Staking {
        uint128 staked; // initial CQT amount staked
        uint128 shares; // # of validator shares that delegate owns
    }
    struct Unstaking {
        uint128 coolDownEnd; // epoch when unstaking can be redeemed
        uint128 amount;
    }
    struct Validator {
        address _address;
        address operator;
        uint128 commissionRate; // validator commission rate
        uint128 disabledEpoch; // epoch when validator got disabled, if set to 0, validator is enabled
        uint128 globalShares; // total number of global shares under a validator
        uint128 lastUpdateGlobalRate; // global exchange rate when the validator was updated the last time
        uint128 totalShares; // total number of validator shares
        uint128 delegated; // total number of tokens originally staked/delegated to the validator, this does not include interest
        uint128 exchangeRate; // validator exchange rate
        uint128 commissionAvailableToRedeem; // # of CQTs paid to the validator
        mapping(address => Staking) stakings;
        mapping(address => Unstaking[]) unstakings;
    }
    event RewardTokensDeposited(uint128 amount);
    event ValidatorAdded(uint128 indexed id, address indexed validator, address indexed operator);
    event ValidatorDisabled(uint128 indexed id);
    event Staked(uint128 indexed validatorId, address delegator, uint128 amount);
    event Unstaked(uint128 indexed validatorId, address indexed delegator, uint128 amount);
    event RecoveredUnstake(uint128 indexed validatorId, address indexed delegator, uint128 amount, uint128 unstakingId);
    event UnstakeRedeemed(uint128 indexed validatorId, address indexed delegator, uint128 amount);
    event RewardRedeemed(uint128 indexed validatorId, address indexed beneficiary, uint128 amount);
    event CommissionRewardRedeemed(uint128 indexed validatorId, address indexed beneficiary, uint128 amount);
    event AllocatedTokensTaken(uint128 amount);
    event MaxCapMultiplierChanged(uint128 amount);
    event TransferredUnstake(uint128 indexed oldValidatorId, uint128 indexed newValidatorId, address indexed delegator, uint128 amount, uint128 unstakingId);
    event EmissionRateChanged(uint128 newRate);
    event ValidatorCommissionRateChanged(uint128 indexed validatorId, uint128 newRate);
    event ValidatorMinStakedRequiredChanged(uint128 amount);
    event Initialized(uint128 minStakedRequired, uint128 validatorCoolDown, uint128 delegatorCoolDown, uint128 maxCapMultiplier, uint128 allocatedTokensPerEpoch, uint128 globalExchangeRate);

    // this is used to have the contract upgradeable
    function initialize(uint128 minStakedRequired) public initializer {
        validatorMinStakedRequired = minStakedRequired;
        validatorCoolDown = 180*6646; // ~ 6 months
        delegatorCoolDown = 28*6646; // ~ 28 days
        maxCapMultiplier = 10;
        allocatedTokensPerEpoch = 1*10**18; // should never be 0
        globalExchangeRate = 10**18; // 1 to 1
        CQT = IERC20(0xD417144312DbF50465b1C641d016962017Ef6240);
        emit Initialized(minStakedRequired, validatorCoolDown, delegatorCoolDown, maxCapMultiplier, allocatedTokensPerEpoch, globalExchangeRate);
    }
    // used to transfer CQT from delegators, validators and the owner to the contract
    function _transferToContract(address from, uint128 amount) internal {
        require(CQT.balanceOf(from) >= amount, "The sender does not have enough CQT balance to transfer");
        uint balanceBeforeTransfer = CQT.balanceOf(address(this));
        CQT.transferFrom(from, address(this), amount);
        assert(CQT.balanceOf(address(this)) == balanceBeforeTransfer + amount);
    }

    // used to transfer CQT from contract, for rewards redemption or transferring out unstaked
    function _transferFromContract(address to, uint128 amount) internal {
        require(CQT.balanceOf(address(this)) >= amount, "The contract does not have enough CQT balance to transfer");
        uint balanceBeforeTransfer = CQT.balanceOf(to);
        CQT.transfer(to, amount);
        assert(CQT.balanceOf(to) == balanceBeforeTransfer + amount);
    }

    // transfer CQT from the owner to the contract for rewards allocation, must change end epoch
    function depositRewardTokens(uint128 amount) public onlyOwner {
        require(amount >= allocatedTokensPerEpoch, "Amount must cover at least 1 epoch");
        if (endEpoch != 0)
            endEpoch += amount / allocatedTokensPerEpoch;
        else
            rewardsLocked += amount;
        _transferToContract(msg.sender, amount);
        emit RewardTokensDeposited(amount);
    }

    // transfer reward CQT from the contract to the owner, must change end epoch and not allow transfer from the past
    function takeOutRewardTokens(uint128 amount) public onlyOwner {
        require(amount > 0, "Amount is 0");
        if (endEpoch != 0){
            uint128 currentEpoch = uint128(block.number);
            uint128 epochs = amount / allocatedTokensPerEpoch;
            require(endEpoch - epochs > currentEpoch, "Cannot takeout rewards from past");
            endEpoch = endEpoch - epochs;
        }
        else{
            require(rewardsLocked >= amount, "Amount is greater than available");
            rewardsLocked -= amount;
        }
        _transferFromContract(msg.sender, amount);
        emit AllocatedTokensTaken(amount);
    }

    // update global exchange rate
    function _updateGlobalExchangeRate() internal {
        uint128 currentBlock = uint128(block.number);
        // if the program ended, set update epoch to the end epoch
        uint128 currentEpoch = currentBlock < endEpoch? currentBlock : endEpoch;
        if (currentEpoch != lastUpdateEpoch){
            // when no one has staked anything, do not update the rate
            if(totalGlobalShares > 0)
            {
                globalExchangeRate += uint128(uint256(allocatedTokensPerEpoch) * divider * uint256(currentEpoch - lastUpdateEpoch)/uint256(totalGlobalShares)) ;
            }
            lastUpdateEpoch = currentEpoch;
        }
    }

    // update validator exchange rate
    function _updateValidator(Validator storage v) internal {
        // if validator is disabled, we do not update it since it was updated during disabling transaction
        if(v.disabledEpoch == 0){
            if (v.totalShares == 0){
                // when validator stakes the first time, the exchange rate must be equal to the current global exchange rate
                v.exchangeRate = globalExchangeRate;
            }
            else {
                // the growth of global exchange rate since the validator was updated the last time
                uint128 rateDifference = globalExchangeRate - v.lastUpdateGlobalRate;
                // tokens given to the validator and its delegators since last update
                uint128 tokensGivenToValidator = _sharesToTokens(v.globalShares, rateDifference);
                // commission paid out of the tokens
                uint128 commissionPaid = uint128(uint256(tokensGivenToValidator) * uint256(v.commissionRate) /  divider);
                // increase validator exchange rate by distributing the leftover tokens through the validator shares
                v.exchangeRate += uint128(uint256(tokensGivenToValidator - commissionPaid) * divider / v.totalShares);
                // give commission tokens to the validator
                v.commissionAvailableToRedeem += commissionPaid;
            }
            // set the last update global rate to the current one
            v.lastUpdateGlobalRate = globalExchangeRate;
        }
    }
    // used to convert global shares or validator shares to CQT
    function _sharesToTokens(uint128 sharesN, uint128 rate) internal view returns(uint128){
        return uint128(uint256(sharesN) * uint256(rate) / divider);
    }
    // used to convert CQT to global shares or validator shares
    function _tokensToShares(uint128 amount, uint128 rate) internal view returns(uint128){
        return uint128(uint256(amount) * divider / uint256(rate));
    }

    function stake(uint128 validatorId, uint128 amount) public {
        _stake(validatorId, amount, true);
    }
    // need to update global exchange rate, validator data and then delegator instance
    // withTransfer set to false when delegators recover unstake, because the tokens are already in the contract
    function _stake(uint128 validatorId, uint128 amount, bool withTransfer) internal {
        require(amount >= divider, "Amount must be at least 1 token");
        require(validatorId < validatorsN, "Invalid validator");
        require(validators[validatorId].disabledEpoch == 0, "Validator is disabled");
        // if this is the first stake, then set the end epoch
        if (endEpoch == 0){
            endEpoch = uint128(block.number) + rewardsLocked / allocatedTokensPerEpoch;
            rewardsLocked = 0; // no longer used and saves a bit of gas
        }
        require(endEpoch > block.number, "Program ended");

        _updateGlobalExchangeRate();
        Validator storage v = validators[validatorId];
        _updateValidator(v);
        // if staker is validator who self delegates
        if (msg.sender == v._address){
            require(amount + v.stakings[msg.sender].staked >= validatorMinStakedRequired, "Amount is less than minimum staked required");
        }
        else {
            // otherwise need to check for max cap
            uint128 validatorStaked = v.stakings[v._address].staked;
            uint128 validatorMaxCap = validatorStaked * maxCapMultiplier;
            uint128 newDelegated = v.delegated - validatorStaked + amount;
            require(newDelegated <= validatorMaxCap, "Validator max capacity exceeded");
        }
        // it is set to true when there is a stake
        // it is set to false when we recover delegation from unstaking
        if (withTransfer)
            _transferToContract(msg.sender, amount);
        Staking storage s = v.stakings[msg.sender];

        // update global shares #
        uint128 globalSharesToAdd = _tokensToShares(amount, globalExchangeRate);
        totalGlobalShares += globalSharesToAdd;
        v.globalShares += globalSharesToAdd;

        // update validator shares #
        uint128 newDelegatorSharesN = _tokensToShares(amount, v.exchangeRate);
        v.totalShares += newDelegatorSharesN;
        s.shares += newDelegatorSharesN;
        v.delegated += amount;
        s.staked += amount;
        emit Staked(validatorId, msg.sender, amount);
    }

    // need to update global exchange rate, validator data and then delegator instance
    function unstake(uint128 validatorId, uint128 amount) public {
        require(validatorId < validatorsN, "Invalid validator");
        Validator storage v = validators[validatorId];
        Staking storage s = v.stakings[msg.sender];
        require(s.staked >= amount, "Staked is less than amount provided");
        bool isValidator = msg.sender == v._address;
        _updateGlobalExchangeRate();
        _updateValidator(v);
        // only update if the validator is enabled, otherwise the global shares were already excluded during disableValidator call and the rest does not matter anymore
        uint128 validatorSharesRemove = _tokensToShares(amount, v.exchangeRate);
        require(validatorSharesRemove > 0, "Unstake amount is too small");
        if (v.disabledEpoch == 0){
            // if validator is enabled and the program has not ended -> check for unstaking beyond max cap or min stake required
            if (isValidator && endEpoch > block.number){
                uint128 newValidatorStaked = s.staked - amount;
                uint128 newValidatorMaxCap = newValidatorStaked * maxCapMultiplier;
                uint128 delegated = v.delegated - s.staked;
                require(delegated <= newValidatorMaxCap, "Cannot unstake beyond max cap");
                require(newValidatorStaked >= validatorMinStakedRequired, "Cannot unstake beyond minimum staked required");
            }

            // update global shares #
            uint128 globalSharesRemove = _tokensToShares(amount, globalExchangeRate);
            require(globalSharesRemove > 0, "Unstake amount is too small");
            totalGlobalShares -= globalSharesRemove;
            v.globalShares -= globalSharesRemove;

            // update validator shares #
            v.totalShares -= validatorSharesRemove;
            v.delegated -= amount;
        }
        s.shares -= validatorSharesRemove;
        s.staked -= amount;

        // create unstaking instance
        uint128 coolDownEnd = v.disabledEpoch != 0 ? v.disabledEpoch : uint128(block.number);
        coolDownEnd += (isValidator ? validatorCoolDown : delegatorCoolDown);
        v.unstakings[msg.sender].push(Unstaking( coolDownEnd, amount));
        emit Unstaked(validatorId, msg.sender, amount);
    }

    // restake unstaked tokens
    function recoverUnstaking(uint128 amount, uint128 validatorId, uint128 unstakingId) public{
        Unstaking storage us = validators[validatorId].unstakings[msg.sender][unstakingId];
        require(us.amount >= amount, "Unstaking has less tokens");
        _stake(validatorId, amount, false);
        us.amount -= amount;
        // set cool down end to 0 to release gas if new unstaking amount is 0
        if(us.amount == 0)
            us.coolDownEnd = 0;
        emit RecoveredUnstake(validatorId, msg.sender, amount, unstakingId);
    }

    // redeem all available rewards
    function redeemAllRewards( uint128 validatorId, address beneficiary) public {
        require(beneficiary!=address(0x0), "Invalid beneficiary");
        _updateGlobalExchangeRate();
        _updateValidator(validators[validatorId]);
        Validator storage v = validators[validatorId];
        Staking storage s = v.stakings[msg.sender];
        uint128 rewards = _sharesToTokens(s.shares, v.exchangeRate) - s.staked;
        require(rewards > 0, "Nothing to redeem");

        // update validator shares #
        // this only includes rewards earned, no need to include commission to validator shares
        uint128 validatorSharesRemove = _tokensToShares(rewards, v.exchangeRate);
        s.shares -= validatorSharesRemove;
        v.totalShares -= validatorSharesRemove;

        emit RewardRedeemed(validatorId, beneficiary, rewards);

        if(msg.sender == v._address){
            rewards += v.commissionAvailableToRedeem;
            emit CommissionRewardRedeemed(validatorId, beneficiary, v.commissionAvailableToRedeem);
            v.commissionAvailableToRedeem = 0;
        }
        _transferFromContract(beneficiary, rewards);

        // update global shares #
        // this includes commission and rewards earned
        // only update if the validator is enabled, otherwise the shares were already excluded during disableValidator call
        if (v.disabledEpoch == 0){
           uint128 globalSharesRemove = _tokensToShares(rewards, globalExchangeRate);
            totalGlobalShares -= globalSharesRemove;
            v.globalShares -= globalSharesRemove;
        }
    }

    // if validator calls redeem rewards, first tokens paid from commissions will be redeemed and then regular rewards
    function redeemRewards( uint128 validatorId, address beneficiary, uint128 amount) public {
        require(beneficiary!=address(0x0), "Invalid beneficiary");
        require(amount != 0, "Cannot redeem 0 tokens");
        _updateGlobalExchangeRate();
        Validator storage v = validators[validatorId];
        _updateValidator(v);
        Staking storage s = v.stakings[msg.sender];

        uint128 rewards = _sharesToTokens(s.shares, v.exchangeRate) - s.staked;
        if(msg.sender == v._address){
            require(rewards + v.commissionAvailableToRedeem >= amount, "Cannot redeem more than available");
            // first redeem rewards from commission
            uint128 commissionLeftOver = amount < v.commissionAvailableToRedeem ? v.commissionAvailableToRedeem - amount : 0;
            // if there is more, redeem  it from regular rewards
            if (commissionLeftOver == 0){
                uint128 validatorSharesRemove = _tokensToShares(amount - v.commissionAvailableToRedeem, v.exchangeRate);
                s.shares -= validatorSharesRemove;
                v.totalShares -= validatorSharesRemove;
            }
            v.commissionAvailableToRedeem = commissionLeftOver;
        }
        else {
            require(rewards >= amount, "Cannot redeem more than available");
            uint128 validatorSharesRemove = _tokensToShares(amount, v.exchangeRate);
            s.shares -= validatorSharesRemove;
            v.totalShares -= validatorSharesRemove;
        }
        _transferFromContract(beneficiary, amount);

        // update global shares #
        // this includes commission and rewards earned
        // only update if the validator is enabled, otherwise the shares were already excluded during disableValidator call
        if (v.disabledEpoch == 0){
            uint128 globalSharesRemove = _tokensToShares(amount, globalExchangeRate);
            totalGlobalShares -= globalSharesRemove;
            v.globalShares -= globalSharesRemove;
        }
        emit RewardRedeemed(validatorId, beneficiary, amount);
    }

    // add new validator instance
    function addValidator(address validator, address operator, uint128 commissionRate) public onlyOwner {
        require(commissionRate < divider, "Rate must be less than 100%");
        uint128 N = validatorsN;
        validators[N]._address = validator;
        validators[N].operator = operator;
        validators[N].commissionRate = commissionRate;
        emit ValidatorAdded(N, validator, operator);
        validatorsN += 1;
    }

    // can only be called by the owner or the validator, disabling will allow validator to fully unstake
    // validator instance can only be disabled once and can never be reenabled
    function disableValidator(uint128 validatorId) public {
        Validator storage v = validators[validatorId];
        require(v.disabledEpoch == 0, "Validator is already disabled");
        require(v._address == msg.sender || msg.sender == owner(), "Caller is not the owner or the validator");
        _updateGlobalExchangeRate();
        _updateValidator(v);
        v.disabledEpoch = uint128(block.number) < endEpoch? uint128(block.number) : endEpoch;
        totalGlobalShares -= v.globalShares;
        emit ValidatorDisabled(validatorId);
    }

    // change emission rate, should reset end epoch
    function setAllocatedTokensPerEpoch(uint128 amount) public onlyOwner {
        require(amount > 0, "Amount is 0");
        if (endEpoch != 0){
            _updateGlobalExchangeRate();
            // get number of epochs from now to the end epoch
            uint128 epochs = endEpoch > uint128(block.number) ? endEpoch - uint128(block.number) : 0;
            // calculate how much rewards would be distributed with the old emission rate
            uint128 futureRewards = allocatedTokensPerEpoch * epochs;
            // calculate how many epochs will be covered
            uint128 addEpochs = futureRewards/amount;
            require(addEpochs != 0, "This amount will end the program");
            endEpoch = uint128(block.number) + addEpochs;
        }
        allocatedTokensPerEpoch = amount;
        emit EmissionRateChanged(amount);
    }

    // we assume that we will never set it to less than what is staked already
    function setMaxCapMultiplier(uint128 amount) public onlyOwner {
        require(amount > 0, "Must be greater than 0");
        maxCapMultiplier = amount;
        emit MaxCapMultiplierChanged(amount);
    }

    // only owner can change commission rate
    function setValidatorCommissionRate(uint128 amount, uint128 validatorId) public onlyOwner {
        require(amount < divider, "Rate must be less than 100%");
        _updateGlobalExchangeRate();
        _updateValidator(validators[validatorId]);
        validators[validatorId].commissionRate = amount;
        emit ValidatorCommissionRateChanged(validatorId, amount);
    }

    // we are assuming there will never be a case when the owner sets the value to something extremely big and if that happens accidentally, we will just recall the function
    function setValidatorMinStakedRequired(uint128 amount) public onlyOwner {
        validatorMinStakedRequired = amount;
        emit ValidatorMinStakedRequiredChanged(amount);
    }

    // if a validator gets disabled, delegators can redelegate their tokens to another validator
    // first they need to unstake
    function redelegateUnstaked(uint128 amount, uint128 oldValidatorId, uint128 newValidatorId, uint128 unstakingId) public {
        require(validators[oldValidatorId].disabledEpoch != 0, "Can only transfer unstaked from disabled validator");
        require(validators[oldValidatorId]._address != msg.sender, "Only delegators can redelegate tokens");
        Unstaking storage us = validators[oldValidatorId].unstakings[msg.sender][unstakingId];
        require(us.amount >= amount, "Unstaking has less tokens");
        _stake(newValidatorId, amount, false);
        us.amount -= amount;
        // set cool down end to 0 to release gas if new unstaking amount is 0
        if(us.amount == 0)
            us.coolDownEnd = 0;
        emit TransferredUnstake(oldValidatorId, newValidatorId, msg.sender, amount, unstakingId);
    }

    // transfer out unlocked unstaked tokens back to the delegator
    function transferUnstakedOut(uint128 amount, uint128 validatorId, uint128 unstakingId) public {
        Unstaking storage us = validators[validatorId].unstakings[msg.sender][unstakingId];
        require( uint128(block.number) > us.coolDownEnd, "Cooldown period has not ended" );
        require(us.amount >= amount, "Amount is too high");
        _transferFromContract(msg.sender, amount);
        us.amount -= amount;
        // set cool down end to 0 to release gas if new unstaking amount is 0
        if (us.amount == 0)
            us.coolDownEnd = 0;
        emit UnstakeRedeemed(validatorId, msg.sender, amount);
    }

    // returns details of each validator
    // array index is id
    function getValidatorsDetails() public view returns (uint128[] memory commissionRates, uint128[] memory delegated) {
        commissionRates = new uint128[](validatorsN);
        delegated = new uint128[](validatorsN);
        for (uint128 i = 0; i < validatorsN; ++i){
            Validator storage v = validators[i];
            commissionRates[i] = v.commissionRate;
            delegated[i] = v.delegated - v.stakings[v._address].staked;
        }
        return (commissionRates, delegated);
    }

    // this follows the same logic as _updateGlobalExchangeRate and _updateValidator
    // array index is id of validator
    function getDelegatorDetails(address delegator) public view returns( uint128[] memory delegated,  uint128[] memory rewardsAvailable, uint128[] memory commissionRewards) {
       delegated = new uint128[](validatorsN);
       rewardsAvailable = new uint128[](validatorsN);
       commissionRewards = new uint128[](validatorsN);
       uint256 currentEpoch = block.number < endEpoch? block.number: endEpoch;
       uint128 newGlobalExchangeRate = uint128((uint256(allocatedTokensPerEpoch) * divider/totalGlobalShares)*(currentEpoch - lastUpdateEpoch)) + globalExchangeRate;
       Validator storage v;
       Staking storage s;
        for (uint128 i = 0; i < validatorsN; ++i){
            v = validators[i];
            s = v.stakings[delegator];
            delegated[i] = s.staked;
            if (v.disabledEpoch == 0){
                uint128 newTokensGiven = _sharesToTokens(v.globalShares, newGlobalExchangeRate - v.lastUpdateGlobalRate);
                uint128 commissionPaid = uint128(uint256(newTokensGiven) * uint256(v.commissionRate) /  divider);
                uint128 rateIncrease = uint128(uint256(newTokensGiven - commissionPaid) * divider / v.totalShares);
                rewardsAvailable[i] = _sharesToTokens(s.shares, v.exchangeRate + rateIncrease) - s.staked;
                if(delegator == v._address)
                    commissionRewards[i] = v.commissionAvailableToRedeem + commissionPaid;
            }
            else {
                rewardsAvailable[i] = _sharesToTokens(s.shares, v.exchangeRate) - s.staked;
                if(delegator == v._address)
                    commissionRewards[i] = v.commissionAvailableToRedeem;
            }
        }
        return (delegated, rewardsAvailable, commissionRewards);
    }

    function getMetadata() public view returns(uint128,  uint128, uint128, uint128, uint128 ){
        uint128 totalStaked = uint128(uint256(totalGlobalShares) * uint256(globalExchangeRate) / divider);
        return (allocatedTokensPerEpoch, endEpoch, maxCapMultiplier, totalStaked, validatorsN);
    }
}