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
/// @param closedAt The time at which the auction closed
/// @param drawId The draw id that the auction started
/// @param rngRequestId The id of the RNG request that was made
struct StartDrawAuction {
  address recipient;
  uint40 closedAt;
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

/// @notice Thrown when the zero address is passed as reward recipient
error RewardRecipientIsZero();

/// @notice Thrown when the RNG request wasn't made in the same block
error RngRequestNotInSameBlock();

/// @notice Thrown when the Draw has finalized and can no longer be awarded
error DrawHasFinalized();

/// @notice Thrown when the rng request has not yet completed
error RngRequestNotComplete();

/// @notice Thrown when the maximum number of start draw retries has been reached
error RetryLimitReached();

/// @notice Thrown when a retry attempt is made with a stale RNG request
error StaleRngRequest();

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

  /// @notice The target duration of the auctions (elapsed time at close of auction)
  uint48 public immutable auctionTargetTime;

  /// @notice The target time to complete the auction as a fraction of the auction duration
  /// @dev This just saves some calculations and is a duplicate of auctionTargetTime
  UD2x18 internal immutable _auctionTargetTimeFraction;

  /// @notice The maximum total rewards for both auctions for a single draw
  uint256 public immutable maxRewards;

  /// @notice The maximum number of times a start RNG request can be retried on failure.
  uint256 public immutable maxRetries;

  /// @notice The address of a vault to contribute remaining reserve on behalf of
  address public immutable vaultBeneficiary;

  /// @notice A stack of the last Start Draw Auction results
  StartDrawAuction[] internal _startDrawAuctions;
  
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
  event DrawFinished(
    address indexed sender,
    address indexed recipient,
    uint24 indexed drawId,
    uint48 elapsedTime,
    uint reward
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
  /// @param _maxRetries The maximum number of times a start RNG request can be retried on failure.
  /// @param _vaultBeneficiary The address of a vault to contribute remaining reserve on behalf of
  constructor(
    PrizePool _prizePool,
    IRng _rng,
    uint48 _auctionDuration,
    uint48 _auctionTargetTime,
    UD2x18 _firstStartDrawTargetFraction,
    UD2x18 _firstFinishDrawTargetFraction,
    uint256 _maxRewards,
    uint256 _maxRetries,
    address _vaultBeneficiary
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
    vaultBeneficiary = _vaultBeneficiary;

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
    maxRetries = _maxRetries;
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
    if (rng.requestedAtBlock(_rngRequestId) != block.number) revert RngRequestNotInSameBlock();
    
    StartDrawAuction memory lastRequest = getLastStartDrawAuction();
    uint auctionOpenedAt;
    
    if (lastRequest.drawId != drawId) { // if this request is for a new draw
      // auctioned opened at the close of the draw
      auctionOpenedAt = closesAt;
      // clear out the old ones
      while (_startDrawAuctions.length > 0) {
        _startDrawAuctions.pop();
      }
    } else { // the old request is for the same draw
      if (!rng.isRequestFailed(lastRequest.rngRequestId)) { // if the request failed
        revert AlreadyStartedDraw();
      } else if (_startDrawAuctions.length == maxRetries) { // if request has failed and we have retried too many times
        revert RetryLimitReached();
      } else if (_rngRequestId <= lastRequest.rngRequestId) { // if the request has failed, we haven't retried too many times, but the rng request has been used
        revert StaleRngRequest();
      } else {
        // auctioned opened at the close of the last auction
        // NOTE: is this accurate enough?
        auctionOpenedAt = lastRequest.closedAt;
      }
    }

    _startDrawAuctions.push(StartDrawAuction({
      recipient: _rewardRecipient,
      closedAt: uint40(block.timestamp),
      drawId: drawId,
      rngRequestId: _rngRequestId
    }));

    uint48 auctionElapsedTimeSeconds = _computeElapsedTime(block.timestamp, auctionOpenedAt);
    if (auctionElapsedTimeSeconds > auctionDuration) revert AuctionExpired();

    // NOTE: we pass zero in here because all auctions are in storage
    (uint[] memory rewards,) = _computeStartDrawRewards(closesAt, 0, _computeAvailableRewards()); // computeRewards(auctionElapsedTimeSeconds, 0, prizePool.reserve() + prizePool.pendingReserveContributions());

    emit DrawStarted(
      msg.sender,
      _rewardRecipient,
      drawId,
      auctionElapsedTimeSeconds,
      rewards[rewards.length - 2], // ignore the last one
      _rngRequestId
    );

    return drawId;
  }

  /// @notice Checks if the start draw can be called.
  /// @return True if start draw can be called, false otherwise
  function canStartDraw() public view returns (bool) {
    uint24 drawId = prizePool.getDrawIdToAward();
    uint48 closesAt = prizePool.drawClosesAt(drawId);
    StartDrawAuction memory lastStartDrawAuction = getLastStartDrawAuction();
    return (
      (
        // if we're on a new draw
        drawId != lastStartDrawAuction.drawId ||
        // OR we're on the same draw, but the request has failed and we haven't retried too many times
        (rng.isRequestFailed(lastStartDrawAuction.rngRequestId) && _startDrawAuctions.length < maxRetries)
      ) && // we haven't started it, or we have and the request has failed
      block.timestamp >= closesAt && // the draw has closed
      _computeElapsedTime(block.timestamp, closesAt) <= auctionDuration // the draw hasn't expired
    );
  }

  /// @notice Calculates the current reward for starting the draw. If start draw cannot be called, this will be zero.
  /// @return The current reward denominated in prize tokens of the target prize pool.
  function startDrawReward() public view returns (uint256) {
    if (!canStartDraw()) {
      return 0;
    }
    uint256 drawClosedAt = prizePool.drawClosesAt(prizePool.getDrawIdToAward());
    (uint256[] memory rewards,) = _computeStartDrawRewards(drawClosedAt, block.timestamp, _computeAvailableRewards());
    return rewards[rewards.length - 1];
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

    StartDrawAuction memory startDrawAuction = getLastStartDrawAuction();
    
    if (startDrawAuction.drawId != prizePool.getDrawIdToAward()) {
      revert DrawHasFinalized();
    }

    if (!rng.isRequestComplete(startDrawAuction.rngRequestId)) {
      revert RngRequestNotComplete();
    }

    if (_isAuctionExpired(startDrawAuction.closedAt)) {
      revert AuctionExpired();
    }
    
    StartDrawAuction memory lastAuction = getLastStartDrawAuction();
    uint256 availableRewards = _computeAvailableRewards();
    (uint256[] memory startDrawRewards, UD2x18[] memory startDrawFractions) = _computeStartDrawRewards(prizePool.drawClosesAt(lastAuction.drawId), 0, availableRewards);
    (uint256 _finishDrawReward, UD2x18 finishFraction) = _computeFinishDrawReward(lastAuction.closedAt, block.timestamp, availableRewards);
    uint256 randomNumber = rng.randomNumber(startDrawAuction.rngRequestId);
    uint24 drawId = prizePool.awardDraw(randomNumber);

    lastStartDrawFraction = startDrawFractions[startDrawFractions.length - 2];
    lastFinishDrawFraction = finishFraction;

    emit DrawFinished(
      msg.sender,
      _rewardRecipient,
      drawId,
      _computeElapsedTime(block.timestamp, lastAuction.closedAt),
      _finishDrawReward
    );

    for (uint i = 0; i < _startDrawAuctions.length; i++) {
      _reward(_startDrawAuctions[i].recipient, startDrawRewards[i]);
    }
    _reward(_rewardRecipient, _finishDrawReward);
    
    uint remainingReserve = prizePool.reserve();
    if (remainingReserve != 0) {
      _rewardReserve(remainingReserve);
    }

    return drawId;
  }

  function _rewardReserve(uint256 reserve) internal virtual {
      if (vaultBeneficiary != address(0)) {
        _reward(address(this), reserve);
        prizePool.withdrawRewards(address(prizePool), reserve);
        prizePool.contributePrizeTokens(vaultBeneficiary, reserve);
      }
  }

  /// @notice Determines whether finish draw can be called.
  /// @return True if the finish draw can be called, false otherwise.
  function canFinishDraw() public view returns (bool) {
    StartDrawAuction memory startDrawAuction = getLastStartDrawAuction();
    return (
      startDrawAuction.drawId == prizePool.getDrawIdToAward() && // We've started the current draw
      rng.isRequestComplete(startDrawAuction.rngRequestId) && // rng request is complete
      !_isAuctionExpired(startDrawAuction.closedAt) // the auction hasn't expired
    );
  }

  /// @notice Calculates the reward for calling finishDraw.
  /// @return reward The current reward denominated in prize tokens
  function finishDrawReward() public view returns (uint256 reward) {
    if (!canFinishDraw()) {
      return 0;
    }
    StartDrawAuction memory startDrawAuction = getLastStartDrawAuction();

    (reward,) = _computeFinishDrawReward(startDrawAuction.closedAt, block.timestamp, _computeAvailableRewards());
  }

  /// ================= State =================

  /// @notice The last auction results.
  /// @return result StartDrawAuctions struct from the last auction.
  function getLastStartDrawAuction() public view returns (StartDrawAuction memory result) {
    uint length = _startDrawAuctions.length;
    if (length > 0) {
      result = _startDrawAuctions[length-1];
    }
  }

  function getStartDrawAuctionCount() external view returns (uint) {
    return _startDrawAuctions.length;
  }

  function getStartDrawAuction(uint256 _index) external view returns (StartDrawAuction memory) {
    return _startDrawAuctions[_index];
  }

  function _computeFinishDrawReward(
    uint256 _auctionOpenedAt,
    uint256 _auctionAt,
    uint256 _availableRewards
  ) internal view returns (uint256 reward, UD2x18 fraction) {
    fraction = computeFinishDrawRewardFraction(_computeElapsedTime(_auctionAt, _auctionOpenedAt));
    reward = RewardLib.reward(fraction, _availableRewards);
  }

  function _computeStartDrawRewards(
    uint256 _firstAuctionOpenedAt,
    uint256 _lastAuctionAt,
    uint256 _availableRewards
  ) internal view returns (uint256[] memory rewards, UD2x18[] memory fractions) {
    uint length = _startDrawAuctions.length;
    rewards = new uint256[](length+1);
    fractions = new UD2x18[](length+1);
    uint256 previousStartTime = _firstAuctionOpenedAt;
    for (uint i = 0; i < rewards.length; i++) {
      uint closedAt = i < length ? _startDrawAuctions[i].closedAt : _lastAuctionAt;
      fractions[i] = computeStartDrawRewardFraction(_computeElapsedTime(closedAt, previousStartTime));
      rewards[i] = RewardLib.reward(fractions[i], _availableRewards);
      previousStartTime = closedAt;
    }
  }

  /// @notice Computes the start draw reward.
  /// @param _startDrawElapsedTime The elapsed time between draw close and startDraw()
  /// @param _totalReserve The total reserve available to allocate rewards from
  /// @return reward The computed reward for start draw
  // function computeStartDrawReward(uint48 _startDrawElapsedTime, uint256 _totalReserve) public view returns (uint256) {
  //   (uint256[] memory rewards,) = computeRewards(_startDrawElapsedTime, 0, _totalReserve);
  //   return rewards[0];
  // }

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
  /// @param closedAt The time at which the auction started
  /// @return True if the auction has expired, false otherwise
  function _isAuctionExpired(uint256 closedAt) internal view returns (bool) {
    return uint48(block.timestamp - closedAt) > auctionDuration;
  }

  /// @notice Allocates the reward to the recipient.
  /// @param _recipient The recipient of the reward
  /// @param _amount The amount of the reward
  function _reward(address _recipient, uint256 _amount) internal {
    if (_amount > 0) {
      prizePool.allocateRewardFromReserve(_recipient, SafeCast.toUint96(_amount));
    }
  }

  function _computeAvailableRewards() internal view returns (uint256) {
    uint totalReserve = prizePool.reserve() + prizePool.pendingReserveContributions();
    return totalReserve > maxRewards ? maxRewards : totalReserve;
  }

  /// @notice Calculates the elapsed time for the current RNG auction.
  /// @return The elapsed time since the start of the current RNG auction in seconds.
  function _computeElapsedTime(uint256 _timestamp, uint256 _prevTimestamp) internal pure returns (uint48) {
    return uint48(_prevTimestamp < _timestamp ? _timestamp - _prevTimestamp : 0);
  }

}
