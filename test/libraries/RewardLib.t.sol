// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import { UD2x18 } from "prb-math/UD2x18.sol";

import { Allocation, RewardLibWrapper } from "test/wrappers/RewardLibWrapper.sol";

contract RewardLibTest is Test {
  RewardLibWrapper public rewardLib;

  function setUp() external {
    rewardLib = new RewardLibWrapper();
  }

  function testFailRewardFraction_StartWithZeroTargetTime() external view {
    rewardLib.fractionalReward(0, 1 days, UD2x18.wrap(0), UD2x18.wrap(5e17));
  }

  function testRewardFraction_zeroElapsed() external {
    assertEq(
      UD2x18.unwrap(rewardLib.fractionalReward(0, 1 days, UD2x18.wrap(5e17), UD2x18.wrap(5e17))),
      0
    ); // 0
  }

  function testRewardFraction_fullElapsed() external {
    assertEq(
      UD2x18.unwrap(
        rewardLib.fractionalReward(1 days, 1 days, UD2x18.wrap(5e17), UD2x18.wrap(5e17))
      ),
      1e18
    ); // 1
  }

  function testRewardFraction_halfElapsed() external {
    assertEq(
      UD2x18.unwrap(
        rewardLib.fractionalReward(1 days / 2, 1 days, UD2x18.wrap(5e17), UD2x18.wrap(5e17))
      ),
      5e17
    ); // 0.5
  }

  function testReward_noRecipient() external {
    Allocation memory _allocation = Allocation(
      address(0), // no recipient
      UD2x18.wrap(5e17) // 0.5
    );
    uint256 _reserve = 1e18;
    assertGt(_reserve, 0);
    assertGt(UD2x18.unwrap(_allocation.rewardFraction), 0);
    assertEq(rewardLib.reward(_allocation, _reserve), 0);
  }

  function testReward_zeroReserve() external {
    Allocation memory _allocation = Allocation(
      address(this),
      UD2x18.wrap(5e17) // 0.5
    );
    uint256 _reserve = 0; // no reserve
    assertEq(rewardLib.reward(_allocation, _reserve), 0);
  }

  function testReward_zeroFraction() external {
    Allocation memory _allocation = Allocation(
      address(this),
      UD2x18.wrap(0) // 0
    );
    uint256 _reserve = 1e18;
    assertEq(rewardLib.reward(_allocation, _reserve), 0);
  }

  function testReward_fullFraction() external {
    Allocation memory _allocation = Allocation(
      address(this),
      UD2x18.wrap(1e18) // full portion (1.0)
    );
    uint256 _reserve = 1e18;
    assertEq(rewardLib.reward(_allocation, _reserve), _reserve);
  }

  function testReward_halfFraction() external {
    Allocation memory _allocation = Allocation(
      address(this),
      UD2x18.wrap(5e17) // half portion (0.5)
    );
    uint256 _reserve = 1e18;
    assertEq(rewardLib.reward(_allocation, _reserve), _reserve / 2);
  }

  function testRewards() external {
    Allocation[] memory _allocation = new Allocation[](3);
    _allocation[0] = Allocation(address(this), UD2x18.wrap(0)); // 0 reward (0 portion of 1e18), 1e18 reserve remains
    _allocation[1] = Allocation(address(this), UD2x18.wrap(75e16)); // 75e16 reward (0.75 portion of 1e18), 25e16 reserve remains
    _allocation[2] = Allocation(address(this), UD2x18.wrap(1e18)); // 25e16 reward (1.0 portion of 25e16), 0 reserve remains
    uint256[] memory _rewards = rewardLib.rewards(_allocation, 1e18);
    assertEq(_rewards[0], 0);
    assertEq(_rewards[1], 75e16);
    assertEq(_rewards[2], 25e16);
  }
}
