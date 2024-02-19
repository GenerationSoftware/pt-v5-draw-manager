// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PrizePool } from "pt-v5-prize-pool/PrizePool.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { UD2x18 } from "prb-math/UD2x18.sol";
import { UD60x18, convert, intoUD2x18 } from "prb-math/UD60x18.sol";

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
 * @param sequencePeriod The sequence period in seconds
 */
error AuctionDurationGTSequencePeriod(uint64 auctionDuration, uint64 sequencePeriod);

/// @notice Thrown when the first auction target reward fraction is greater than one.
error TargetRewardFractionGTOne();

/// @notice Thrown when the RNG address passed to the setter function is zero address.
error RngZeroAddress();

/// @notice Thrown if the next sequence cannot yet be started
error CannotStartRngRequest();

/// @notice Thrown if the time elapsed since the start of the auction is greater than the auction duration.
error AuctionExpired();

/// @notice Emitted when the zero address is passed as reward recipient
error RewardRecipientIsZero();

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

  uint256 public immutable maxRewards;

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
   * @param rngRequestId The RNGInterface request ID
   * @param elapsedTime The amount of time that the auction ran for in seconds
   * @param rewardFraction The fraction of the available rewards to be allocated to the recipient
   */
  event RngAuctionCompleted(
    address indexed sender,
    address indexed recipient,
    uint32 rngRequestId,
    uint64 elapsedTime,
    UD2x18 rewardFraction
  );

  /* ============ Constructor ============ */

  /**
   * @notice Deploy the RngAuction smart contract.
   * @param _prizePool Address of the Prize Pool
   * @param _rng Address of the RNG service
   * @param auctionDurationSeconds_ Auction duration in seconds
   * @param auctionTargetTime_ Target time to complete the auction in seconds
   * @param _lastStartRngRequestFraction The expected reward fraction for the first start rng auction (to help fine-tune the system)
   * @param _lastAwardDrawFraction The expected reward fraction for the first award draw auction (to help fine-tune the system)
   * @param _maxRewards The maximum amount of rewards that can be allocated to the auction
   * @param _remainingRewardsRecipient The address to send any remaining rewards to
   */
  constructor(
    PrizePool _prizePool,
    IRng _rng,
    uint64 auctionDurationSeconds_,
    uint64 auctionTargetTime_,
    UD2x18 _lastStartRngRequestFraction,
    UD2x18 _lastAwardDrawFraction,
    uint256 _maxRewards,
    address _remainingRewardsRecipient
  ) {
    if (auctionTargetTime_ > auctionDurationSeconds_) {
      revert AuctionTargetTimeExceedsDuration(
        uint64(auctionTargetTime_),
        uint64(auctionDurationSeconds_)
      );
    }

    if (auctionDurationSeconds_ > sequencePeriod_)
      revert AuctionDurationGTSequencePeriod(
        uint64(auctionDurationSeconds_),
        uint64(sequencePeriod_)
      );

    if (_lastStartRngRequestFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();
    if (_lastAwardDrawFraction.unwrap() > 1e18) revert TargetRewardFractionGTOne();

    lastStartRngRequestFraction = _lastStartRngRequestFraction;
    lastAwardDrawFraction = _lastAwardDrawFraction;

    auctionDuration = auctionDurationSeconds_;
    auctionTargetTime = auctionTargetTime_;
    _auctionTargetTimeFraction = (
      intoUD2x18(
        convert(uint256(auctionTargetTime_)).div(convert(uint256(auctionDurationSeconds_)))
      )
    );

    _firstAuctionTargetRewardFraction = firstAuctionTargetRewardFraction_;

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
  function claimStartDraw(address _rewardRecipient, uint32 _rngRequestId) external {
    if (_rewardRecipient == address(0)) revert RewardRecipientIsZero();
    if (!_isNewDrawToAward()) revert CannotStartRngRequest();
    if (!rng.requestedAtBlock(_rngRequestId) == block.number) revert InvalidRngRequest();

    uint64 _auctionElapsedTimeSeconds = elapsedTimeSinceDrawClosed();
    if (_auctionElapsedTimeSeconds > auctionDuration) revert AuctionExpired();

    uint24 drawId = prizePool.getDrawIdToAward(); 

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
      _auctionElapsedTimeSeconds,
      rewardFraction
    );
  }

  /**
   * @notice Checks if the auction is still open and if it can be completed.
   * @dev The auction is open if RNG has not been requested yet this sequence and the
   * auction has not expired.
   * @return True if the auction is open and can be completed, false otherwise.
   */
  function canStartDraw() external view returns (bool) {
    return _isNewDrawToAward() && elapsedTimeSinceDrawClosed() <= auctionDuration;
  }

  /**
   * @notice Calculates the reward fraction for the current auction if it were to be completed at this time.
   * @dev Uses the last sold fraction as the target price for this auction.
   * @return The current reward fraction as a UD2x18 value
   */
  function startDrawFee() public view returns (uint256) {
    if (!canClaimStartDraw()) {
      return 0;
    }
    (uint256[] memory rewards,) = _computeRewards();
    return rewards[0];
  }

  /// @notice Called to complete the Draw on the prize pool.
  /// @param _rewardRecipient The recipient of the relay auction reward (the recipient can withdraw the rewards from the Prize Pool once the auction is complete)
  /// @return The closed draw ID
  function claimAwardDraw(address _rewardRecipient)
    external
    returns (uint24)
  {
    if (_rewardRecipient == address(0)) {
      revert RewardRecipientIsZeroAddress();
    }

    (uint256[] memory rewards, uint256 remainingReserve) = _computeRewards();

    uint32 drawId = _prizePool.awardDraw(_randomNumber);

    emit DrawAwarded(drawId);

    _reward(_lastStartRngRequestAuction.recipient, rewards[0]);
    _reward(_rewardRecipient, rewards[1]);
    _reward(remainingRewardsRecipient, remainingReserve);

    return drawId;
  }

  /**
   * @notice Checks if the auction is still open and if it can be completed.
   * @dev The auction is open if RNG has not been requested yet this sequence and the
   * auction has not expired.
   * @return True if the auction is open and can be completed, false otherwise.
   */
  function canAwardDraw() external view returns (bool) {
    uint24 drawId = prizePool.getDrawIdToAward();
    return (
      prizePool.getDrawClosedAt(drawId) < block.timestamp && // current draw to award is ready to go
      _lastStartRngRequestAuction.drawId == drawId && // we've made the rng request for this draw
      rng.isRequestComplete(_lastStartRngRequestAuction.rngRequestId) // rng request is complete
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
    (uint256[] memory rewards,) = _computeRewards();
    return rewards[1];
  }

  /* ============ State Functions ============ */

  function _reward(uint24 _drawId, address _recipient, uint256 _amount) internal {
    if (_amount > 0) {
      _prizePool.allocateRewardFromReserve(_recipient, _amount);
    }
    emit AuctionRewardAllocated(_sequenceId, _recipient, _amount);
  }

  function _computeRewards() internal view returns (uint256[] memory rewards, uint256 remainingReserve) {
    uint totalReserve = prizePool.reserve() + prizePool.pendingReserveContributions();
    uint rewardPool = totalReserve > maxRewards ? maxRewards : totalReserve;
    uint totalRewards;
    (rewards, totalRewards) = RewardLib.computeRewards(
      [
        _currentStartRngRequestRewardFraction(),
        _computeAwardDrawRewardFraction()
      ],
      rewardPool
    );
    remainingReserve = totalReserve - totalRewards;
  }

  function _computeAwardDrawRewardFraction() internal view returns (UD2x18) {
    RewardLib.fractionalReward(
        block.timestamp - _lastStartRngRequestAuction.startedAt,
        auctionDuration,
        _auctionTargetTimeFraction,
        _lastAwardDrawFraction
      );
  }

  function _currentStartRngRequestRewardFraction() internal view returns (UD2x18) {
    RewardLib.fractionalReward(
        elapsedTimeSinceDrawClosed(),
        auctionDuration,
        _auctionTargetTimeFraction,
        _lastStartRngRequestFraction
      );
  }

  function computeRewards(UD2x18[] memory _rewardFractions, uint256 _reserve) internal view returns (uint256[] memory) {
    return RewardLib.rewards(_rewardFractions, _reserve);
  }

  /**
   * @notice The last auction results.
   * @return StartRngRequestAuctions struct from the last auction.
   */
  function getLastAuction() external view returns (StartRngRequestAuction memory) {
    return _lastStartRngRequestAuction;
  }

  function getStartRngRequestRewardFraction() external view returns (UD2x18) {
    return _lastStartRngRequestAuction.rewardFraction;
  }

  /// @notice Computes the reward fraction for the given auction elapsed time.
  /// @param __auctionElapsedTime The elapsed time of the auction in seconds
  /// @return The reward fraction as a UD2x18 value
  function computeRewardFraction(uint64 __auctionElapsedTime) internal view returns (UD2x18) {
    return _computeRewardFraction(__auctionElapsedTime);
  }

  /* ============ Internal Functions ============ */

  /**
   * @notice Calculates the elapsed time for the current RNG auction.
   * @return The elapsed time since the start of the current RNG auction in seconds.
   */
  function elapsedTimeSinceDrawClosed() public view returns (uint64) {
    uint256 _drawClosedAt = _drawIdToAwardClosesAt();
    return _drawClosedAt < block.timestamp ? block.timestamp - _drawClosedAt : 0;
  }

  function _drawIdToAwardClosesAt() internal view returns (uint256) {
    return prizePool.getDrawClosedAt(prizePool.getDrawIdToAward());
  }

  /**
   * @notice Calculates the reward fraction for the current auction based on the given elapsed time.
   * @param __auctionElapsedTime The elapsed time of the auction in seconds
   * @dev Uses the last sold fraction as the target price for this auction.
   * @return The current reward fraction as a UD2x18 value
   */
  function _computeRewardFraction(uint64 __auctionElapsedTime) internal view returns (UD2x18) {
    return
      RewardLib.fractionalReward(
        __auctionElapsedTime,
        auctionDuration,
        _auctionTargetTimeFraction,
        _lastStartRngRequestAuction.sequenceId == 0
          ? _firstAuctionTargetRewardFraction
          : _lastStartRngRequestAuction.rewardFraction
      );
  }

  /**
   * @notice Determines if there is a new draw to award
   * @dev The auction is complete when the RNG has been requested for the current sequence, therefore
   * the next sequence can be started if the current sequenceId is different from the last
   * auction's sequenceId.
   * @return True if the next sequence can be started, false otherwise.
   */
  function _isNewDrawToAward() internal view returns (bool) {
    return _lastStartRngRequestAuction.drawId != prizePool.getDrawIdToAward();
  }
}
