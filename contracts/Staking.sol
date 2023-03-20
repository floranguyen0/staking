// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./lib/ABDKMath64x64.sol";

contract Staking is Ownable {
    // PRIVATE VARIABLES

    // staking periods in days
    uint64 private immutable _periodForMinimumRate;
    uint64 private immutable _stakingPeriod1;
    uint64 private immutable _stakingPeriod2;
    uint64 private immutable _stakingPeriod3;

    // rewards rates correspond with staking periods, calculate as compound interest per day
    // users receive (rate * staked amount / (10**18)) tokens per staking day
    uint64 private immutable _minimumRate;
    uint64 private immutable _rewardsRate1;
    uint64 private immutable _rewardsRate2;
    uint64 private immutable _rewardsRate3;

    // tokens used for staking and rewards
    IERC20 private immutable _token;

    uint128 private _idCounter;

    // EVENTS

    event Stake(
        address indexed user,
        uint256 indexed id,
        uint256 indexed stakedAmount,
        uint256 stakingPeriod,
        uint256 startTime
    );

    event Withdraw(
        address indexed user,
        uint256 indexed id,
        uint256 stakedAmount,
        uint256 indexed withdrawAmount,
        uint256 stakingPeriod,
        uint256 startTime,
        uint256 endTime
    );

    // MODIFIERS

    modifier stakingPeriodEnded(uint256 id) {
        uint256 startTime = _userStakingInfo[_msgSender()][id].startTime;
        uint256 stakingPeriod = _userStakingInfo[_msgSender()][id]
            .stakingPeriod;
        uint256 timePassed = block.timestamp - startTime;

        require(
            timePassed >= stakingPeriod,
            "The current staking period has not ended"
        );
        _;
    }

    modifier validId(uint256 id) {
        require(
            _userStakingInfo[_msgSender()][id].stakedAmount > 0,
            "Invalid id"
        );
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }

    // assume 1 month = 30 days, 1 year = 365 days. Leap seconds cannot be predicted,
    // an exact calendar library has to be updated by an external oracle.
    modifier validStakingPeriod(uint256 stakingPeriod) {
        require(
            stakingPeriod == _stakingPeriod1 ||
                stakingPeriod == _stakingPeriod2 ||
                stakingPeriod == _stakingPeriod3,
            "Invalid staking period"
        );
        _;
    }

    // STRUCT, MAPPING

    struct StakingInfo {
        uint256 id;
        uint256 stakedAmount;
        uint256 stakingPeriod;
        uint256 startTime;
    }

    mapping(address => StakingInfo[]) private _userStakingInfo;

    // CONSTRUCTOR

    constructor(
        uint64 periodForMinimumRate_,
        uint64 stakingPeriod1_,
        uint64 stakingPeriod2_,
        uint64 stakingPeriod3_,
        uint64 minimumRate_,
        uint64 rewardsRate1_,
        uint64 rewardsRate2_,
        uint64 rewardsRate3_,
        IERC20 token_
    ) {
        require(
            address(token_) != address(0),
            "Token address cannot be the zero address"
        );
        _periodForMinimumRate = periodForMinimumRate_;
        _stakingPeriod1 = stakingPeriod1_;
        _stakingPeriod2 = stakingPeriod2_;
        _stakingPeriod3 = stakingPeriod3_;
        _minimumRate = minimumRate_;
        _rewardsRate1 = rewardsRate1_;
        _rewardsRate2 = rewardsRate2_;
        _rewardsRate3 = rewardsRate3_;
        _token = token_;
    }

    // STATE-CHANGING PUBLIC FUNCTIONS

    function withdrawableAmount(
        uint256 id
    ) public view virtual validId(id) stakingPeriodEnded(id) returns (uint256) {
        return _withdrawableAmount(id);
    }

    function stake(
        uint256 amount,
        uint256 stakingPeriod
    ) public virtual validAmount(amount) validStakingPeriod(stakingPeriod) {
        _stake(amount, stakingPeriod);
    }

    function stakeBatch(
        uint256[] calldata amounts,
        uint256[] calldata stakingPeriods
    ) public virtual {
        require(
            amounts.length == stakingPeriods.length,
            "Amounts and staking periods length mismatch"
        );

        for (uint256 i = 0; i < amounts.length; ) {
            stake(amounts[i], stakingPeriods[i]);
            unchecked {
                ++i;
            }
        }
    }

    function extendStakingPeriod(
        uint256 id,
        uint256 stakingPeriod
    )
        public
        virtual
        validId(id)
        stakingPeriodEnded(id)
        validStakingPeriod(stakingPeriod)
    {
        _extendStakingPeriod(id, stakingPeriod);
    }

    function withdrawAll(
        uint256 id
    ) public virtual validId(id) stakingPeriodEnded(id) {
        _withdrawAll(id);
    }

    function withdraw(
        uint256 id,
        uint256 withdrawAmount
    )
        public
        virtual
        validId(id)
        validAmount(withdrawAmount)
        stakingPeriodEnded(id)
    {
        _withdraw(withdrawAmount, id);
    }

    function withdrawBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) public virtual {
        require(
            amounts.length == ids.length,
            "Amounts and ids length mismatch"
        );

        for (uint256 i = 0; i < ids.length; ) {
            withdraw(amounts[i], ids[0]);
            unchecked {
                ++i;
            }
        }
    }

    function adminWithdraw(uint256 amount) public virtual onlyOwner {
        _token.transfer(owner(), amount);
    }

    // PUBLIC VIEW FUNCTIONS

    function minimumRate() public view virtual returns (uint256) {
        return _minimumRate;
    }

    function rewardsRate1() public view virtual returns (uint256) {
        return _rewardsRate1;
    }

    function rewardsRate2() public view virtual returns (uint256) {
        return _rewardsRate2;
    }

    function rewardsRate3() public view virtual returns (uint256) {
        return _rewardsRate3;
    }

    function token() public view virtual returns (IERC20) {
        return _token;
    }

    function idCounter() public view virtual returns (uint256) {
        return _idCounter;
    }

    function getUserStakingInfo(
        address user
    ) public view virtual returns (StakingInfo[] memory) {
        return _userStakingInfo[user];
    }

    // INTERNAL FUNCTIONS

    function _stake(uint256 amount, uint256 stakingPeriod) internal {
        uint256 counter = _idCounter;

        _token.transferFrom(msg.sender, address(this), amount);
        _userStakingInfo[msg.sender].push(
            StakingInfo(counter, amount, stakingPeriod, block.timestamp)
        );
        unchecked {
            ++_idCounter;
        }
        emit Stake(msg.sender, counter, amount, block.timestamp, stakingPeriod);
    }

    function _extendStakingPeriod(uint256 id, uint256 stakingPeriod) internal {
        uint256 amount = _withdrawableAmount(id);

        delete _userStakingInfo[_msgSender()][id];
        _stake(amount, stakingPeriod);
    }

    function _withdrawAll(uint256 id) internal {
        StakingInfo storage stakingInfo = _userStakingInfo[msg.sender][id];
        uint256 withdrawableAmount_ = _withdrawableAmount(id);

        delete _userStakingInfo[msg.sender][id];
        _token.transfer(msg.sender, withdrawableAmount_);

        emit Withdraw(
            msg.sender,
            id,
            stakingInfo.stakedAmount,
            withdrawableAmount_,
            stakingInfo.stakingPeriod,
            stakingInfo.startTime,
            block.timestamp
        );
    }

    function _withdraw(uint256 id, uint256 withdrawAmount) internal {
        StakingInfo storage stakingInfo = _userStakingInfo[msg.sender][id];
        uint256 withdrawableAmount_ = _withdrawableAmount(id);

        uint256 stakedAmount = stakingInfo.stakedAmount;
        uint256 stakingPeriod = stakingInfo.stakingPeriod;
        uint256 startTime = stakingInfo.startTime;

        require(
            withdrawAmount <= withdrawableAmount_,
            "Withdraw amount exceeds the withdrawable amount"
        );

        if (withdrawAmount < withdrawableAmount_) {
            uint256 tokensStakedAtMinimumRate = withdrawableAmount_ -
                withdrawAmount;
            _stake(tokensStakedAtMinimumRate, _periodForMinimumRate);
        }

        delete _userStakingInfo[msg.sender][id];
        _token.transfer(msg.sender, withdrawAmount);

        emit Withdraw(
            msg.sender,
            id,
            stakedAmount,
            withdrawAmount,
            stakingPeriod,
            startTime,
            block.timestamp
        );
    }

    function _withdrawableAmount(uint256 id) internal view returns (uint256) {
        StakingInfo storage stakingInfo = _userStakingInfo[_msgSender()][id];

        uint256 stakingPeriod = stakingInfo.stakingPeriod;
        uint256 timePassed = block.timestamp - stakingInfo.startTime;

        uint256 amountWhenStakingPeriodEnds = calculateCompound(
            _rewardsRate(stakingPeriod),
            stakingInfo.stakedAmount,
            stakingPeriod
        );

        // Start staking tokens at a minimal rate when users don't withdraw all tokens
        // 1 day after the staking period ends.
        if (timePassed / 1 days >= stakingPeriod + 1) {
            uint256 minimalRatePeriod = timePassed / 1 days - stakingPeriod;

            uint256 finalAmount = calculateCompound(
                _minimumRate,
                amountWhenStakingPeriodEnds,
                minimalRatePeriod
            );

            return finalAmount;
        }
        return amountWhenStakingPeriodEnds;
    }

    function _rewardsRate(
        uint256 stakingPeriod
    ) internal view returns (uint256 rate) {
        if (stakingPeriod == _stakingPeriod1) {
            rate = _rewardsRate1;
        } else if (stakingPeriod == _stakingPeriod2) {
            rate = _rewardsRate2;
        } else {
            rate = _rewardsRate3;
        }
        revert("Invalid staking period");
    }

    // ratio is the staking rewards rate
    // principle is the staked amount
    // n is staking days
    function calculateCompound(
        uint256 ratio,
        uint256 principal,
        uint256 n
    ) public pure returns (uint256) {
        return
            ABDKMath64x64.mulu(
                ABDKMath64x64.pow(
                    ABDKMath64x64.add(
                        ABDKMath64x64.fromUInt(1),
                        ABDKMath64x64.divu(ratio, 10 ** 18)
                    ),
                    n
                ),
                principal
            );
    }
}
