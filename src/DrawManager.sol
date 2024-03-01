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

/**
 * @notice The results of a successful RNG auction.
 * @param recipient The recipient of the auction reward
 * @param rewardFraction The reward fraction that the user will receive
 * @param drawId The draw id that the auction belonged to
 * @param rngRequestId The id of the RNG request that was made
 * @dev   The `sequenceId` value should not be assumed to be the same as a prize pool drawId, but the sequence and offset should match the prize pool.
 */
struct StartRngRequestAuction {
  address recipient;
  uint40 startedAt;
  uint24 drawId;
  uint32 rngRequestId;
}

/* ============ Custom Errors ============ */

/// @notice Thrown when the auction duration is zero.
error AuctionDurationZero();

/// @notice Thrown if the auction target time is zero.
error AuctionTargetTimeZero();

/**
 * @notice Thrown if the auction target time exceeds the auction duration.
 * @param auctionTargetTime The auction target time to complete in seconds
 * @param auctionDuration The auction duration in seconds
 */
error AuctionTargetTimeExceedsDuration(uint64 auctionTargetTime, uint64 auctionDuration);

/**
 * @notice Thrown when the auction duration is greater than or equal to the sequence.
 * @param auctionDuration The auction duration in seconds
 */
error AuctionDurationGTDrawPeriodSeconds(uint64 auctionDuration);

/// @notice Thrown when the first auction target reward fraction is greater than one.
error TargetRewardFractionGTOne();

/// @notice Thrown when the RNG address passed to the setter function is zero address.
error RngZeroAddress();

/// @notice Thrown if the next sequence cannot yet be started
error DrawHasNotClosed();

/// @notice Thrown if the auction has already been started for the current draw
error AlreadyStartedDraw();

/// @notice Thrown if the time elapsed since the start of the auction is greater than the auction duration.
error AuctionExpired();

/// @notice Emitted when the zero address is passed as reward recipient
error RewardRecipientIsZero();

/// @notice Emitted when the Rng request wasn't made in the same block
error RngRequestNotInSameBlock();

/// @notice Emitted when the award draw is called after the start draw has expired
error DrawHasFinalized();

/// @notice Emitted when the rng request has not yet completed
error RngRequestNotComplete();

/**
 * @title PoolTogether V5 RngAuction
 * @author G9 Software Inc.
 * @notice The RngAuction allows anyone to request a new random number using the RNG service set.
 *         The auction incentivises RNG requests to be started in-sync with prize pool draw
 *         periods across all chains.
 */
contract DrawManager {
  using SafeERC20 for IERC20;

  /* ============ Variables ============ */

  PrizePool public immutable prizePool;

  IRng public immutable rng;

  /// @notice Duration of the auction in seconds
  /// @dev This must always be less than the sequence period since the auction needs to complete each period.
  uint64 public immutable auctionDuration;

  /// @notice The target time to complete the auction in seconds
  uint64 public immutable auctionTargetTime;

  /// @notice The target time to complete the auction as a fraction of the auction duration
  UD2x18 internal immutable _auctionTargetTimeFraction;

  /// @notice The maximum total rewards for both auctions for a single draw
  uint256 public immutable maxRewards;

  /// @notice The address to allocate any remaining reserve from each draw.
  address public immutable remainingRewardsRecipient;

  /// @notice The last auction result
  StartRngRequestAuction internal _lastStartRngRequestAuction;
  
  UD2x18 public lastStartRngRequestFraction;
  UD2x18 public lastAwardDrawFraction;

  /* ============ Events ============ */

  /**
   * @notice Emitted when the auction is completed.
   * @param sender The address that triggered the rng auction
   * @param recipient The recipient of the auction reward
   * @param drawId The draw id that this request is for
   * @param rngRequestId The RNGInterface request ID
   * @param elapsedTime The amount of time that the auction ran for in seconds
   */
  event RngAuctionCompleted(
    address indexed sender,
    address indexed recipient,
    uint24 drawId,
    uint32 rngRequestId,
    uint64 elapsedTime
  );

  /**
   * @notice Emitted when the draw is awarded
   * @param drawId The draw id
   * @param startRecipient The recipient of the start rng auction reward
   * @param startReward The reward for the start rng auction
   * @param awardRecipient The recipient of the award draw auction reward
   * @param awardReward The reward for the award draw auction
   * @param remainingReserve The remaining reserve after the rewards have been allocated
   */
  event DrawAwarded(
    uint24 indexed drawId,
    address indexed startRecipient,
    uint startReward,
    address indexed awardRecipient,
    uint awardReward,
    uint remainingReserve
  );

  /* ============ Constructor ============ */

  /**
   * @notice Deploy the RngAuction smart contract.
   * @param _prizePool Address of the Prize Pool
   * @param _rng Address of the RNG service
   * @param _auctionDuration Auction duration in seconds
   * @param _auctionTargetTime Target time to complete the auction in seconds
   * @param _firstStartRngRequestTargetFraction The expected reward fraction for the first start rng auction (to help fine-tune the system)
   * @param _firstAwardDrawTargetFraction The expected reward fraction for the first award draw auction (to help fine-tune the system)
   * @param _maxRewards The maximum amount of rewards that can be allocated to the auction
   * @param _remainingRewardsRecipient The address to send any remaining rewards to
   */
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

    lastStartRngRequestFraction = _firstStartRngRequestTargetFraction;
    lastAwardDrawFraction = _firstAwardDrawTargetFraction;
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

  /* ============ External Functions ============ */

  /**
   * @notice  Starts the RNG Request, ends the current auction, and stores the reward fraction to
   *          be allocated to the recipient.
   * @dev     Will revert if the current auction has already been completed or expired.
   * @dev     If the RNG service expects the fee to already be in possession, the caller should not
   *          call this function directly and should instead call a helper function that transfers
   *          the funds to the RNG service before calling this function.
   * @dev     If there is a pending RNG service (see _nextRng), it will be swapped in before the
   *          auction is completed.
   * @param _rewardRecipient Address that will be allocated the auction reward for starting the RNG request.
   * The recipient can withdraw the rewards from the Prize Pools that use the random number once all
   * subsequent auctions are complete.
   */
  function startDraw(address _rewardRecipient, uint32 _rngRequestId) external {
    if (_rewardRecipient == address(0)) revert RewardRecipientIsZero();
    uint24 drawId = prizePool.getDrawIdToAward(); 
    if (prizePool.drawClosesAt(drawId) > block.timestamp) revert DrawHasNotClosed();
    StartRngRequestAuction memory lastRequest = _lastStartRngRequestAuction;
    if (lastRequest.drawId == drawId) revert AlreadyStartedDraw();
    if (rng.requestedAtBlock(_rngRequestId) != block.number) revert RngRequestNotInSameBlock();

    uint64 _auctionElapsedTimeSeconds = elapsedTimeSinceDrawClosed();
    if (_auctionElapsedTimeSeconds > auctionDuration) revert AuctionExpired();


    _lastStartRngRequestAuction = StartRngRequestAuction({
      recipient: _rewardRecipient,
      startedAt: uint40(block.timestamp),
      drawId: drawId,
      rngRequestId: _rngRequestId
    });

    emit RngAuctionCompleted(
      msg.sender,
      _rewardRecipient,
      drawId,
      _rngRequestId,
      _auctionElapsedTimeSeconds
    );
  }

  /**
   * @notice Checks if the auction is still open and if it can be completed.
   * @dev The auction is open if RNG has not been requested yet this sequence and the
   * auction has not expired.
   * @return True if the auction is open and can be completed, false otherwise.
   */
  function canStartDraw() public view returns (bool) {
    uint24 drawId = prizePool.getDrawIdToAward();
    uint48 closesAt = prizePool.drawClosesAt(drawId);
    return (
      drawId != _lastStartRngRequestAuction.drawId && // we haven't already started it
      block.timestamp >= closesAt && // the draw has closed
      _elapsedTimeSinceDrawClosed(block.timestamp, closesAt) <= auctionDuration // the draw hasn't expired
    );
  }

  /**
   * @notice Calculates the reward fraction for the current auction if it were to be completed at this time.
   * @dev Uses the last sold fraction as the target price for this auction.
   * @return The current reward fraction as a UD2x18 value
   */
  function startDrawFee() public view returns (uint256) {
    if (!canStartDraw()) {
      return 0;
    }
    (uint256[] memory rewards,) = _computeRewards(prizePool.getDrawIdToAward(), block.timestamp);
    return rewards[0];
  }

  /// @notice Called to complete the Draw on the prize pool.
  /// @param _rewardRecipient The recipient of the relay auction reward (the recipient can withdraw the rewards from the Prize Pool once the auction is complete)
  /// @return The closed draw ID
  function awardDraw(address _rewardRecipient)
    external
    returns (uint24)
  {
    if (_rewardRecipient == address(0)) {
      revert RewardRecipientIsZero();
    }

    StartRngRequestAuction memory requestAuction = _lastStartRngRequestAuction;
    
    if (requestAuction.drawId != prizePool.getDrawIdToAward()) {
      revert DrawHasFinalized();
    }

    if (!rng.isRequestComplete(_lastStartRngRequestAuction.rngRequestId)) {
      revert RngRequestNotComplete();
    }

    if (_hasAuctionExpired(requestAuction.startedAt)) {
      revert AuctionExpired();
    }

    (uint256[] memory rewards, uint256 remainingReserve) = _computeRewards(requestAuction.drawId, requestAuction.startedAt);

    uint256 randomNumber = rng.randomNumber(requestAuction.rngRequestId);

    uint24 drawId = prizePool.awardDraw(randomNumber);

    emit DrawAwarded(drawId, requestAuction.recipient, rewards[0], _rewardRecipient, rewards[1], remainingReserve);

    _reward(_lastStartRngRequestAuction.recipient, rewards[0]);
    _reward(_rewardRecipient, rewards[1]);
    if (remainingRewardsRecipient != address(0)) {
      _reward(remainingRewardsRecipient, remainingReserve);
    }

    return drawId;
  }

  /**
   * @notice Checks if the auction is still open and if it can be completed.
   * @dev The auction is open if RNG has not been requested yet this sequence and the
   * auction has not expired.
   * @return True if the auction is open and can be completed, false otherwise.
   */
  function canAwardDraw() public view returns (bool) {
    StartRngRequestAuction memory requestAuction = _lastStartRngRequestAuction;
    return (
      requestAuction.drawId == prizePool.getDrawIdToAward() && // We've started the current draw
      rng.isRequestComplete(requestAuction.rngRequestId) && // rng request is complete
      !_hasAuctionExpired(requestAuction.startedAt) // the auction hasn't expired
    );
  }

  /**
   * @notice Calculates the reward fraction for the current auction if it were to be completed at this time.
   * @dev Uses the last sold fraction as the target price for this auction.
   * @return The current reward fraction as a UD2x18 value
   */
  function awardDrawFee() public view returns (uint256) {
    if (!canAwardDraw()) {
      return 0;
    }
    StartRngRequestAuction memory requestAuction = _lastStartRngRequestAuction;
    (uint256[] memory rewards,) = _computeRewards(requestAuction.drawId, requestAuction.startedAt);
    return rewards[1];
  }

  /* ============ State Functions ============ */

  function computeRewards(UD2x18[] memory _rewardFractions, uint256 _reserve) external pure returns (uint256[] memory rewardAmounts) {
    (rewardAmounts,) = RewardLib.rewards(_rewardFractions, _reserve);
  }

  /**
   * @notice The last auction results.
   * @return StartRngRequestAuctions struct from the last auction.
   */
  function getLastAuction() external view returns (StartRngRequestAuction memory) {
    return _lastStartRngRequestAuction;
  }

  /* ============ Internal Functions ============ */

  function _hasAuctionExpired(uint256 startedAt) internal view returns (bool) {
    return uint64(block.timestamp - startedAt) > auctionDuration;
  }

  function _reward(address _recipient, uint256 _amount) internal {
    if (_amount > 0) {
      prizePool.allocateRewardFromReserve(_recipient, SafeCast.toUint96(_amount));
    }
  }

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

  function _computeAwardDrawRewardFraction(uint _startRngRequestOccurredAt) internal view returns (UD2x18) {
    uint64 elapsedTime = uint64(block.timestamp - _startRngRequestOccurredAt);
    return RewardLib.fractionalReward(
        elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastAwardDrawFraction
      );
  }

  function _computeStartRngRequestRewardFraction(uint64 _elapsedTime) internal view returns (UD2x18) {
    return RewardLib.fractionalReward(
        _elapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        lastStartRngRequestFraction
      );
  }

  /**
   * @notice Calculates the elapsed time for the current RNG auction.
   * @return The elapsed time since the start of the current RNG auction in seconds.
   */
  function elapsedTimeSinceDrawClosed() public view returns (uint64) {
    return _elapsedTimeSinceDrawClosed(block.timestamp, prizePool.drawClosesAt(prizePool.getDrawIdToAward()));
  }

  /**
   * @notice Calculates the elapsed time for the current RNG auction.
   * @return The elapsed time since the start of the current RNG auction in seconds.
   */
  function _elapsedTimeSinceDrawClosed(uint256 _timestamp, uint256 _drawClosedAt) public pure returns (uint64) {
    return uint64(_drawClosedAt < _timestamp ? _timestamp - _drawClosedAt : 0);
  }

}
