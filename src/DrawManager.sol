// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PrizePool } from "pt-v5-prize-pool/PrizePool.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { UD2x18 } from "prb-math/UD2x18.sol";
import { UD60x18, convert, intoUD2x18 } from "prb-math/UD60x18.sol";
import { SafeCast } from "openzeppelin/utils/math/SafeCast.sol";

import { IRng } from "./interfaces/IRng.sol";
import { Allocation, RewardLib } from "./libraries/RewardLib.sol";

/// @notice A struct that stores the details of a Start Draw auction
/// @param recipient The recipient of the reward
/// @param startedAt The time at which the start draw was initiated
/// @param drawId The draw id that the auction started
/// @param rngRequestId The id of the RNG request that was made
struct StartDrawAuction {
  address recipient;
  uint40 startedAt;
  uint24 drawId;
  uint32 rngRequestId;
}

/// ================= Custom =================

/// @notice Thrown when the auction duration is zero.
error AuctionDurationZero();

/// @notice Thrown if the auction target time is zero.
error AuctionTargetTimeZero();

/// @notice Thrown if the auction target time exceeds the auction duration.
/// @param auctionTargetTime The auction target time to complete in seconds
/// @param auctionDuration The auction duration in seconds
error AuctionTargetTimeExceedsDuration(uint64 auctionTargetTime, uint64 auctionDuration);

/// @notice Thrown when the auction duration is greater than or equal to the sequence.
/// @param auctionDuration The auction duration in seconds
error AuctionDurationGTDrawPeriodSeconds(uint64 auctionDuration);

/// @notice Thrown when the first auction target reward fraction is greater than one.
error TargetRewardFractionGTOne();

/// @notice Thrown when the RNG address passed to the setter function is zero address.
error RngZeroAddress();

/// @notice Thrown if the next draw to award has not yet closed
error DrawHasNotClosed();

/// @notice Thrown if the start draw was already called
error AlreadyStartedDraw();

/// @notice Thrown if the elapsed time has exceeded the auction duration
error AuctionExpired();

/// @notice Emitted when the zero address is passed as reward recipient
error RewardRecipientIsZero();

/// @notice Emitted when the RNG request wasn't made in the same block
error RngRequestNotInSameBlock();

/// @notice Thrown when the Draw has finalized and can no longer be awarded
error DrawHasFinalized();

/// @notice Emitted when the rng request has not yet completed
error RngRequestNotComplete();

/// @title PoolTogether V5 DrawManager
/// @author G9 Software Inc.
/// @notice The DrawManager contract is a permissionless RNG incentive layer for a Prize Pool.
contract DrawManager {
  using SafeERC20 for IERC20;

  /// ================= Variables =================

  /// @notice The prize pool that this DrawManager is bound to
  /// @dev This contract should be the draw manager of the prize pool.
  PrizePool public immutable prizePool;

  /// @notice The random number generator that this DrawManager uses to generate random numbers
  IRng public immutable rng;

  /// @notice Duration of the auction in seconds
  uint64 public immutable auctionDuration;

  /// @notice The target time to complete the auction in seconds.
  /// @dev This is the time at which the reward will equal the last reward fraction
  uint64 public immutable auctionTargetTime;

  /// @notice The target time to complete the auction as a fraction of the auction duration
  /// @dev This just saves some calculations and is a duplicate of auctionTargetTime
  UD2x18 internal immutable _auctionTargetTimeFraction;

  /// @notice The maximum total rewards for both auctions for a single draw
  uint256 public immutable maxRewards;

  /// @notice The address to allocate any remaining reserve from each draw.
  address public immutable remainingRewardsRecipient;

  /// @notice The last Start Draw auction result
  StartDrawAuction internal _lastStartDrawAuction;
  
  /// @notice The last reward fraction used for the start rng auction
  UD2x18 public lastStartDrawFraction;

  /// @notice The last reward fraction used for the finish draw auction
  UD2x18 public lastFinishDrawFraction;

  /// ================= Events =================

  /// @notice Emitted when start draw is called.
  /// @param sender The address that triggered the rng auction
  /// @param recipient The recipient of the auction reward
  /// @param drawId The draw id that this request is for
  /// @param rngRequestId The RNGInterface request ID
  /// @param elapsedTime The amount of time that had elapsed when start draw was called
  event DrawStarted(
    address indexed sender,
    address indexed recipient,
    uint24 drawId,
    uint32 rngRequestId,
    uint64 elapsedTime
  );

  /// @notice Emitted when the finish draw is called
  /// @param drawId The draw id
  /// @param startRecipient The recipient of the start rng auction reward
  /// @param startReward The reward for the start rng auction
  /// @param awardRecipient The recipient of the finish draw auction reward
  /// @param awardReward The reward for the finish draw auction
  /// @param remainingReserve The remaining reserve after the rewards have been allocated
  event DrawFinished(
    uint24 indexed drawId,
    address indexed startRecipient,
    uint startReward,
    address indexed awardRecipient,
    uint awardReward,
    uint remainingReserve
  );

  /// ================= Constructor =================

  /// @notice Deploy the RngAuction smart contract.
  /// @param _prizePool Address of the Prize Pool
  /// @param _rng Address of the RNG service
  /// @param _auctionDuration Auction duration in seconds
  /// @param _auctionTargetTime Target time to complete the auction in seconds
  /// @param _firstStartRngRequestTargetFraction The expected reward fraction for the first start rng auction (to help fine-tune the system)
  /// @param _firstAwardDrawTargetFraction The expected reward fraction for the first finish draw auction (to help fine-tune the system)
  /// @param _maxRewards The maximum amount of rewards that can be allocated to the auction
  /// @param _remainingRewardsRecipient The address to send any remaining rewards to
  constructor(
    PrizePool _prizePool,
    IRng _rng,
    uint64 _auctionDuration,
    uint64 _auctionTargetTime,
    UD2x18 _firstStartRngRequestTargetFraction,
    UD2x18 _firstAwardDrawTargetFraction,
    uint256 _maxRewards,
    address _remainingRewardsRecipient
  ) {
    if (_auctionTargetTime > _auctionDuration) {
      revert AuctionTargetTimeExceedsDuration(
        uint64(_auctionTargetTime),
        uint64(_auctionDuration)
      );
    }

    if (_auctionDuration > _prizePool.drawPeriodSeconds())
      revert AuctionDurationGTDrawPeriodSeconds(
        uint64(_auctionDuration)
      );

    if (_firstStartRngRequestTargetFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();
    if (_firstAwardDrawTargetFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();

    lastStartDrawFraction = _firstStartRngRequestTargetFraction;
    lastFinishDrawFraction = _firstAwardDrawTargetFraction;
    remainingRewardsRecipient = _remainingRewardsRecipient;

    auctionDuration = _auctionDuration;
    auctionTargetTime = _auctionTargetTime;
    _auctionTargetTimeFraction = (
      intoUD2x18(
        convert(uint256(_auctionTargetTime)).div(convert(uint256(_auctionDuration)))
      )
    );

    prizePool = _prizePool;
    rng = _rng;
    maxRewards = _maxRewards;
  }

  /// ================= External =================

  /// @notice  Completes the start draw auction. 
  /// @dev     Will revert if recipient is zero, the draw id to award has not closed, if start draw was already called for this draw, or if the rng is invalid.
  /// @param _rewardRecipient Address that will be allocated the reward for starting the RNG request. This reward can be withdrawn from the Prize Pool after it is successfully awarded.
  /// @param _rngRequestId The RNG request ID to use for randomness. This request must be made in the same block as this call.
  /// @return The draw id for which start draw was called.
  function startDraw(address _rewardRecipient, uint32 _rngRequestId) external returns (uint24) {
    if (_rewardRecipient == address(0)) revert RewardRecipientIsZero();
    uint24 drawId = prizePool.getDrawIdToAward(); 
    if (prizePool.drawClosesAt(drawId) > block.timestamp) revert DrawHasNotClosed();
    StartDrawAuction memory lastRequest = _lastStartDrawAuction;
    if (lastRequest.drawId == drawId) revert AlreadyStartedDraw();
    if (rng.requestedAtBlock(_rngRequestId) != block.number) revert RngRequestNotInSameBlock();

    uint64 _auctionElapsedTimeSeconds = elapsedTimeSinceDrawClosed();
    if (_auctionElapsedTimeSeconds > auctionDuration) revert AuctionExpired();


    _lastStartDrawAuction = StartDrawAuction({
      recipient: _rewardRecipient,
      startedAt: uint40(block.timestamp),
      drawId: drawId,
      rngRequestId: _rngRequestId
    });

    emit DrawStarted(
      msg.sender,
      _rewardRecipient,
      drawId,
      _rngRequestId,
      _auctionElapsedTimeSeconds
    );

    return drawId;
  }

  /// @notice Checks if the start draw can be called.
  /// @return True if start draw can be called, false otherwise
  function canStartDraw() public view returns (bool) {
    uint24 drawId = prizePool.getDrawIdToAward();
    uint48 closesAt = prizePool.drawClosesAt(drawId);
    return (
      drawId != _lastStartDrawAuction.drawId && // we haven't already started it
      block.timestamp >= closesAt && // the draw has closed
      _elapsedTimeSinceDrawClosed(block.timestamp, closesAt) <= auctionDuration // the draw hasn't expired
    );
  }

  /// @notice Calculates the current reward for starting the draw. If start draw cannot be called, this will be zero.
  /// @return The current reward denominated in prize tokens of the target prize pool.
  function startDrawReward() public view returns (uint256) {
    if (!canStartDraw()) {
      return 0;
    }
    (uint256[] memory rewards,) = _computeRewards(prizePool.getDrawIdToAward(), block.timestamp);
    return rewards[0];
  }

  /// @notice Called to award the prize pool and pay out rewards.
  /// @param _rewardRecipient The recipient of the finish draw reward.
  /// @return The awarded draw ID
  function finishDraw(address _rewardRecipient)
    external
    returns (uint24)
  {
    if (_rewardRecipient == address(0)) {
      revert RewardRecipientIsZero();
    }

    StartDrawAuction memory requestAuction = _lastStartDrawAuction;
    
    if (requestAuction.drawId != prizePool.getDrawIdToAward()) {
      revert DrawHasFinalized();
    }

    if (!rng.isRequestComplete(_lastStartDrawAuction.rngRequestId)) {
      revert RngRequestNotComplete();
    }

    if (_hasAuctionExpired(requestAuction.startedAt)) {
      revert AuctionExpired();
    }

    (uint256[] memory rewards, uint256 remainingReserve) = _computeRewards(requestAuction.drawId, requestAuction.startedAt);

    uint256 randomNumber = rng.randomNumber(requestAuction.rngRequestId);

    uint24 drawId = prizePool.awardDraw(randomNumber);

    emit DrawFinished(drawId, requestAuction.recipient, rewards[0], _rewardRecipient, rewards[1], remainingReserve);

    _reward(_lastStartDrawAuction.recipient, rewards[0]);
    _reward(_rewardRecipient, rewards[1]);
    if (remainingRewardsRecipient != address(0)) {
      _reward(remainingRewardsRecipient, remainingReserve);
    }

    return drawId;
  }

  /// @notice Determines whether finish draw can be called.
  /// @return True if the finish draw can be called, false otherwise.
  function canAwardDraw() public view returns (bool) {
    StartDrawAuction memory requestAuction = _lastStartDrawAuction;
    return (
      requestAuction.drawId == prizePool.getDrawIdToAward() && // We've started the current draw
      rng.isRequestComplete(requestAuction.rngRequestId) && // rng request is complete
      !_hasAuctionExpired(requestAuction.startedAt) // the auction hasn't expired
    );
  }

  /// @notice Calculates the reward for calling finishDraw.
  /// @return The current reward denominated in prize tokens
  function finishDrawReward() public view returns (uint256) {
    if (!canAwardDraw()) {
      return 0;
    }
    StartDrawAuction memory requestAuction = _lastStartDrawAuction;
    (uint256[] memory rewards,) = _computeRewards(requestAuction.drawId, requestAuction.startedAt);
    return rewards[1];
  }

  /// ================= State =================

  /// @notice Computes the reward amounts for each reward fraction given the available reserve.
  /// @param _rewardFractions The reward fractions to compute rewards for.
  /// @param _reserve The available reserve to allocate rewards from.
  /// @return rewardAmounts The computed reward amounts for each reward fraction.
  function computeRewards(UD2x18[] memory _rewardFractions, uint256 _reserve) external pure returns (uint256[] memory rewardAmounts) {
    (rewardAmounts,) = RewardLib.rewards(_rewardFractions, _reserve);
  }

  /// @notice The last auction results.
  /// @return StartDrawAuctions struct from the last auction.
  function getLastAuction() external view returns (StartDrawAuction memory) {
    return _lastStartDrawAuction;
  }

  /// ================= Internal =================

  /// @notice Checks if the auction has expired.
  /// @param startedAt The time at which the auction started
  /// @return True if the auction has expired, false otherwise
  function _hasAuctionExpired(uint256 startedAt) internal view returns (bool) {
    return uint64(block.timestamp - startedAt) > auctionDuration;
  }

  /// @notice Allocates the reward to the recipient.
  /// @param _recipient The recipient of the reward
  /// @param _amount The amount of the reward
  function _reward(address _recipient, uint256 _amount) internal {
    if (_amount > 0) {
      prizePool.allocateRewardFromReserve(_recipient, SafeCast.toUint96(_amount));
    }
  }

  /// @notice Computes the rewards for the start and finish draw auctions.
  /// @param drawId The draw id to compute rewards for
  /// @param startRngRequestOccurredAt The time at which the start rng request occurred. Must be in the past.
  /// @return rewards The computed rewards for the start and finish draw auctions
  /// @return remainingReserve The remaining reserve after the rewards have been allocated
  function _computeRewards(uint24 drawId, uint256 startRngRequestOccurredAt) internal view returns (uint256[] memory rewards, uint256 remainingReserve) {
    uint totalReserve = prizePool.reserve() + prizePool.pendingReserveContributions();
    uint rewardPool = totalReserve > maxRewards ? maxRewards : totalReserve;
    uint64 closesAt = prizePool.drawClosesAt(drawId);    
    uint64 startRngRequestElapsedTime = _elapsedTimeSinceDrawClosed(startRngRequestOccurredAt, closesAt);

    UD2x18[] memory rewardFractions = new UD2x18[](2);
    rewardFractions[0] = _computeStartRngRequestRewardFraction(startRngRequestElapsedTime);
    rewardFractions[1] = _computeAwardDrawRewardFraction(startRngRequestOccurredAt);

    uint totalRewards;
    (rewards, totalRewards) = RewardLib.rewards(
      rewardFractions,
      rewardPool
    );
    remainingReserve = totalReserve - totalRewards;
  }

  /// @notice Computes the reward fraction for the finish draw auction.
  /// @param _startRngRequestOccurredAt The time at which the start rng request occurred
  /// @return The computed reward fraction for the finish draw auction
  function _computeAwardDrawRewardFraction(uint _startRngRequestOccurredAt) internal view returns (UD2x18) {
    uint64 elapsedTime = uint64(block.timestamp - _startRngRequestOccurredAt);
    return RewardLib.fractionalReward(
        elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastFinishDrawFraction
      );
  }

  /// @notice Computes the reward fraction for the start draw auction.
  /// @param _elapsedTime The elapsed time since the draw closed in seconds
  /// @return The computed reward fraction for the start draw auction
  function _computeStartRngRequestRewardFraction(uint64 _elapsedTime) internal view returns (UD2x18) {
    return RewardLib.fractionalReward(
        _elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastStartDrawFraction
      );
  }

  /// @notice Calculates the elapsed time for the current RNG auction.
  /// @return The elapsed time since the start of the current RNG auction in seconds.
  function elapsedTimeSinceDrawClosed() public view returns (uint64) {
    return _elapsedTimeSinceDrawClosed(block.timestamp, prizePool.drawClosesAt(prizePool.getDrawIdToAward()));
  }

  /// @notice Calculates the elapsed time for the current RNG auction.
  /// @return The elapsed time since the start of the current RNG auction in seconds.
  function _elapsedTimeSinceDrawClosed(uint256 _timestamp, uint256 _drawClosedAt) public pure returns (uint64) {
    return uint64(_drawClosedAt < _timestamp ? _timestamp - _drawClosedAt : 0);
  }

}
