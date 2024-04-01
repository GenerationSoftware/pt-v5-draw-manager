// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console2.sol";

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
error AuctionTargetTimeExceedsDuration(uint48 auctionTargetTime, uint48 auctionDuration);

/// @notice Thrown when the auction duration is greater than or equal to the sequence.
/// @param auctionDuration The auction duration in seconds
error AuctionDurationGTDrawPeriodSeconds(uint48 auctionDuration);

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
  uint48 public immutable auctionDuration;

  /// @notice The target time to complete the auction in seconds.
  /// @dev This is the time at which the reward will equal the last reward fraction
  uint48 public immutable auctionTargetTime;

  /// @notice The target time to complete the auction as a fraction of the auction duration
  /// @dev This just saves some calculations and is a duplicate of auctionTargetTime
  UD2x18 internal immutable _auctionTargetTimeFraction;

  /// @notice The maximum total rewards for both auctions for a single draw
  uint256 public immutable maxRewards;

  /// @notice The address of the staking vault to contribute remaining reserve on behalf of
  address public immutable stakingVault;

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
  /// @param elapsedTime The amount of time that had elapsed when start draw was called
  /// @param reward The reward for the start draw auction
  /// @param rngRequestId The RNGInterface request ID
  event DrawStarted(
    address indexed sender,
    address indexed recipient,
    uint24 indexed drawId,
    uint48 elapsedTime,
    uint reward,
    uint32 rngRequestId
  );

  /// @notice Emitted when the finish draw is called
  /// @param sender The address that triggered the finish draw auction
  /// @param recipient The recipient of the finish draw auction reward
  /// @param drawId The draw id
  /// @param elapsedTime The amount of time that had elapsed between start draw and finish draw
  /// @param reward The reward for the finish draw auction
  /// @param remainingReserve The remaining reserve after the rewards have been allocated
  event DrawFinished(
    address indexed sender,
    address indexed recipient,
    uint24 indexed drawId,
    uint48 elapsedTime,
    uint reward,
    uint remainingReserve
  );

  /// ================= Constructor =================

  /// @notice Deploy the RngAuction smart contract.
  /// @param _prizePool Address of the Prize Pool
  /// @param _rng Address of the RNG service
  /// @param _auctionDuration Auction duration in seconds
  /// @param _auctionTargetTime Target time to complete the auction in seconds
  /// @param _firstStartDrawTargetFraction The expected reward fraction for the first start rng auction (to help fine-tune the system)
  /// @param _firstFinishDrawTargetFraction The expected reward fraction for the first finish draw auction (to help fine-tune the system)
  /// @param _maxRewards The maximum amount of rewards that can be allocated to the auction
  /// @param _stakingVault The address of the staking vault to contribute remaining reserve on behalf of
  constructor(
    PrizePool _prizePool,
    IRng _rng,
    uint48 _auctionDuration,
    uint48 _auctionTargetTime,
    UD2x18 _firstStartDrawTargetFraction,
    UD2x18 _firstFinishDrawTargetFraction,
    uint256 _maxRewards,
    address _stakingVault
  ) {
    if (_auctionTargetTime > _auctionDuration) {
      revert AuctionTargetTimeExceedsDuration(
        _auctionTargetTime,
        _auctionDuration
      );
    }

    if (_auctionDuration > _prizePool.drawPeriodSeconds())
      revert AuctionDurationGTDrawPeriodSeconds(
        _auctionDuration
      );

    if (_firstStartDrawTargetFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();
    if (_firstFinishDrawTargetFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();

    lastStartDrawFraction = _firstStartDrawTargetFraction;
    lastFinishDrawFraction = _firstFinishDrawTargetFraction;
    stakingVault = _stakingVault;

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
    uint48 closesAt = prizePool.drawClosesAt(drawId);
    if (closesAt > block.timestamp) revert DrawHasNotClosed();
    StartDrawAuction memory lastRequest = _lastStartDrawAuction;
    if (lastRequest.drawId == drawId) revert AlreadyStartedDraw();
    if (rng.requestedAtBlock(_rngRequestId) != block.number) revert RngRequestNotInSameBlock();

    uint48 auctionElapsedTimeSeconds = _elapsedTimeSinceDrawClosed(block.timestamp, closesAt);
    if (auctionElapsedTimeSeconds > auctionDuration) revert AuctionExpired();

    _lastStartDrawAuction = StartDrawAuction({
      recipient: _rewardRecipient,
      startedAt: uint40(block.timestamp),
      drawId: drawId,
      rngRequestId: _rngRequestId
    });

    (uint[] memory rewards,) = computeRewards(auctionElapsedTimeSeconds, 0, prizePool.reserve() + prizePool.pendingReserveContributions());

    emit DrawStarted(
      msg.sender,
      _rewardRecipient,
      drawId,
      auctionElapsedTimeSeconds,
      rewards[0],
      _rngRequestId
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

    StartDrawAuction memory startDrawAuction = _lastStartDrawAuction;
    
    if (startDrawAuction.drawId != prizePool.getDrawIdToAward()) {
      revert DrawHasFinalized();
    }

    if (!rng.isRequestComplete(_lastStartDrawAuction.rngRequestId)) {
      revert RngRequestNotComplete();
    }

    if (_hasAuctionExpired(startDrawAuction.startedAt)) {
      revert AuctionExpired();
    }

    uint totalReserve = prizePool.reserve() + prizePool.pendingReserveContributions();
    uint48 closesAt = prizePool.drawClosesAt(startDrawAuction.drawId);    
    uint48 startDrawElapsedTime = _elapsedTimeSinceDrawClosed(startDrawAuction.startedAt, closesAt);
    uint48 finishDrawElapsedTime = uint48(block.timestamp - startDrawAuction.startedAt);

    (uint256[] memory rewards, uint256 remainingReserve) = computeRewards(startDrawElapsedTime, finishDrawElapsedTime, totalReserve);

    uint256 randomNumber = rng.randomNumber(startDrawAuction.rngRequestId);

    uint24 drawId = prizePool.awardDraw(randomNumber);

    emit DrawFinished(
      msg.sender,
      _rewardRecipient,
      drawId,
      finishDrawElapsedTime,
      rewards[1],
      remainingReserve
    );

    _reward(_lastStartDrawAuction.recipient, rewards[0]);
    _reward(_rewardRecipient, rewards[1]);
    if (stakingVault != address(0) && remainingReserve != 0) {
      _reward(address(this), remainingReserve);
      prizePool.withdrawRewards(address(prizePool), remainingReserve);
      prizePool.contributePrizeTokens(stakingVault, remainingReserve);
    }

    return drawId;
  }

  /// @notice Determines whether finish draw can be called.
  /// @return True if the finish draw can be called, false otherwise.
  function canFinishDraw() public view returns (bool) {
    StartDrawAuction memory startDrawAuction = _lastStartDrawAuction;
    return (
      startDrawAuction.drawId == prizePool.getDrawIdToAward() && // We've started the current draw
      rng.isRequestComplete(startDrawAuction.rngRequestId) && // rng request is complete
      !_hasAuctionExpired(startDrawAuction.startedAt) // the auction hasn't expired
    );
  }

  /// @notice Calculates the reward for calling finishDraw.
  /// @return The current reward denominated in prize tokens
  function finishDrawReward() public view returns (uint256) {
    if (!canFinishDraw()) {
      return 0;
    }
    StartDrawAuction memory startDrawAuction = _lastStartDrawAuction;
    (uint256[] memory rewards,) = _computeRewards(startDrawAuction.drawId, startDrawAuction.startedAt);
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
  function getLastStartDrawAuction() external view returns (StartDrawAuction memory) {
    return _lastStartDrawAuction;
  }

  /// @notice Computes the start draw and finish draw rewards.
  /// @param _startDrawElapsedTime The elapsed time between draw close and startDraw()
  /// @param _finishDrawElapsedTime The elapsed time between startDraw() and finishDraw()
  /// @param _totalReserve The total reserve available to allocate rewards from
  /// @return rewards The computed rewards for the start and finish draw auctions
  /// @return remainingReserve The remaining reserve after the rewards have been allocated
  function computeRewards(uint48 _startDrawElapsedTime, uint48 _finishDrawElapsedTime, uint256 _totalReserve) public view returns (uint256[] memory rewards, uint256 remainingReserve) {
    UD2x18[] memory rewardFractions = new UD2x18[](2);
    uint rewardPool = _totalReserve > maxRewards ? maxRewards : _totalReserve;
    rewardFractions[0] = computeStartDrawRewardFraction(_startDrawElapsedTime);
    rewardFractions[1] = computeFinishDrawRewardFraction(_finishDrawElapsedTime);

    uint totalRewards;
    (rewards, totalRewards) = RewardLib.rewards(
      rewardFractions,
      rewardPool
    );
    remainingReserve = _totalReserve - totalRewards;
  }

  /// @notice Computes the start draw reward.
  /// @param _startDrawElapsedTime The elapsed time between draw close and startDraw()
  /// @param _totalReserve The total reserve available to allocate rewards from
  /// @return reward The computed reward for start draw
  function computeStartDrawReward(uint48 _startDrawElapsedTime, uint256 _totalReserve) public view returns (uint256) {
    (uint256[] memory rewards,) = computeRewards(_startDrawElapsedTime, 0, _totalReserve);
    return rewards[0];
  }

  /// @notice Computes the reward fraction for the start draw auction.
  /// @param _elapsedTime The elapsed time since the draw closed in seconds
  /// @return The computed reward fraction for the start draw auction
  function computeStartDrawRewardFraction(uint48 _elapsedTime) public view returns (UD2x18) {
    return RewardLib.fractionalReward(
        _elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastStartDrawFraction
      );
  }

  /// @notice Computes the reward fraction for the finish draw auction.
  /// @param _elapsedTime The time that has elapsed since the start draw auction in seconds
  /// @return The computed reward fraction for the finish draw auction
  function computeFinishDrawRewardFraction(uint48 _elapsedTime) public view returns (UD2x18) {
    return RewardLib.fractionalReward(
        _elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastFinishDrawFraction
      );
  }

  /// ================= Internal =================

  /// @notice Checks if the auction has expired.
  /// @param startedAt The time at which the auction started
  /// @return True if the auction has expired, false otherwise
  function _hasAuctionExpired(uint256 startedAt) internal view returns (bool) {
    return uint48(block.timestamp - startedAt) > auctionDuration;
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
  /// @param _drawId The draw id to compute rewards for
  /// @param _startDrawOccurredAt The time at which the start rng request occurred. Must be in the past.
  /// @return rewards The computed rewards for the start and finish draw auctions
  /// @return remainingReserve The remaining reserve after the rewards have been allocated
  function _computeRewards(uint24 _drawId, uint256 _startDrawOccurredAt) internal view returns (uint256[] memory rewards, uint256 remainingReserve) {
    uint totalReserve = prizePool.reserve() + prizePool.pendingReserveContributions();
    uint48 closesAt = prizePool.drawClosesAt(_drawId);    
    uint48 startDrawElapsedTime = _elapsedTimeSinceDrawClosed(_startDrawOccurredAt, closesAt);
    uint48 finishDrawElapsedTime = uint48(block.timestamp - _startDrawOccurredAt);

    return computeRewards(startDrawElapsedTime, finishDrawElapsedTime, totalReserve);
  }

  /// @notice Calculates the elapsed time for the current RNG auction.
  /// @return The elapsed time since the start of the current RNG auction in seconds.
  function _elapsedTimeSinceDrawClosed(uint256 _timestamp, uint256 _drawClosedAt) internal pure returns (uint48) {
    return uint48(_drawClosedAt < _timestamp ? _timestamp - _drawClosedAt : 0);
  }

}
