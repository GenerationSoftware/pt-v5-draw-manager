// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import { PrizePool } from "pt-v5-prize-pool/PrizePool.sol";
import { UD2x18 } from "prb-math/UD2x18.sol";
import { UD60x18, convert } from "prb-math/UD60x18.sol";

import { IRng } from "../src/interfaces/IRng.sol";

import {
    DrawManager,
    StartRngRequestAuction,
    AuctionExpired,
    AuctionTargetTimeExceedsDuration,
    AuctionDurationGTDrawPeriodSeconds,
    RewardRecipientIsZero,
    DrawHasNotClosed,
    RngRequestNotComplete,
    AlreadyStartedDraw,
    DrawHasFinalized,
    RngRequestNotInSameBlock,
    TargetRewardFractionGTOne
} from "../src/DrawManager.sol";

contract DrawManagerTest is Test {
    event RngAuctionCompleted(
        address indexed sender,
        address indexed recipient,
        uint24 drawId,
        uint32 rngRequestId,
        uint64 elapsedTime
    );

    event DrawAwarded(
        uint24 indexed drawId,
        address indexed startRecipient,
        uint startReward,
        address indexed awardRecipient,
        uint awardReward,
        uint remainingReserve
    );

    
    DrawManager drawManager;

    PrizePool prizePool = PrizePool(makeAddr("prizePool"));
    IRng rng = IRng(makeAddr("rng"));
    uint64 auctionDuration = 6 hours;
    uint64 auctionTargetTime = 1 hours;
    UD2x18 lastStartRngRequestFraction = UD2x18.wrap(0.1e18);
    UD2x18 lastAwardDrawFraction = UD2x18.wrap(0.2e18);
    uint256 maxRewards = 10e18;
    address remainingRewardsRecipient = address(this);

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");

    function setUp() public {
        // ensure bad mock calls revert
        vm.etch(address(prizePool), "prizePool");
        vm.etch(address(rng), "rng");
        vm.roll(111);
        mockDrawPeriodSeconds(auctionDuration * 4);
        mockDrawClosingTime(1 days);
        newDrawManager();
    }

    function testConstructor() public {
        assertEq(address(drawManager.prizePool()), address(prizePool), "prize pool");
        assertEq(address(drawManager.rng()), address(rng), "rng");
        assertEq(drawManager.auctionDuration(), auctionDuration, "auction duration");
        assertEq(drawManager.lastStartRngRequestFraction().unwrap(), lastStartRngRequestFraction.unwrap(), "last start rng request fraction");
        assertEq(drawManager.lastAwardDrawFraction().unwrap(), lastAwardDrawFraction.unwrap(), "last award draw fraction");
        assertEq(drawManager.maxRewards(), maxRewards, "max rewards");
        assertEq(drawManager.remainingRewardsRecipient(), remainingRewardsRecipient, "remaining rewards recipient");
    }

    function testConstructor_AuctionTargetTimeExceedsDuration() public {
        auctionTargetTime = auctionDuration + 1;
        vm.expectRevert(abi.encodeWithSelector(AuctionTargetTimeExceedsDuration.selector, auctionTargetTime, auctionDuration));
        newDrawManager();
    }

    function testConstructor_AuctionDurationGTDrawPeriodSeconds() public {
        mockDrawPeriodSeconds(auctionDuration / 2);
        vm.expectRevert(abi.encodeWithSelector(AuctionDurationGTDrawPeriodSeconds.selector, auctionDuration));
        newDrawManager();
    }

    function testConstructor_startRngRequest_TargetRewardFractionGTOne() public {
        lastStartRngRequestFraction = UD2x18.wrap(1.1e18);
        vm.expectRevert(abi.encodeWithSelector(TargetRewardFractionGTOne.selector));
        newDrawManager();
    }

    function testConstructor_awardDraw_TargetRewardFractionGTOne() public {
        lastAwardDrawFraction = UD2x18.wrap(1.1e18);
        vm.expectRevert(abi.encodeWithSelector(TargetRewardFractionGTOne.selector));
        newDrawManager();
    }

    function testCanStartDraw() public {
        vm.warp(1 days + auctionDuration / 2);
        assertTrue(drawManager.canStartDraw(), "can start draw");
    }

    function testCanStartDraw_auctionExpired() public {
        vm.warp(2 days);
        assertFalse(drawManager.canStartDraw(), "cannot start draw");
    }

    function testCanStartDraw_drawHasNotClosed() public {
        vm.warp(1 days - 1 hours);
        assertFalse(drawManager.canStartDraw(), "cannot start draw");
    }

    function teststartDrawReward() public {
        vm.warp(1 days);
        mockReserve(1e18, 0);
        // zero is not possible here; not sure why
        assertEq(drawManager.startDrawReward(), 28, "start draw fee");
    }

    function teststartDrawReward_cannotStart() public {
        vm.warp(2 days);
        assertEq(drawManager.startDrawReward(), 0, "start draw fee");
    }

    function teststartDrawReward_atTarget() public {
        vm.warp(1 days + auctionTargetTime);
        mockReserve(2e18, 0);
        assertEq(drawManager.startDrawReward(), 0.2e18, "start draw fee");
    }

    function teststartDrawReward_afterTarget() public {
        vm.warp(1 days + auctionTargetTime + (auctionDuration - auctionTargetTime) / 2);
        mockReserve(2e18, 0);
        assertEq(drawManager.startDrawReward(), 649999999999999996, "start draw fee");
    }

    function testStartDraw() public {
        startFirstDraw();

        StartRngRequestAuction memory auction = drawManager.getLastAuction();

        assertEq(auction.recipient, alice, "recipient");
        assertEq(auction.drawId, 1, "draw id");
        assertEq(auction.startedAt, block.timestamp, "started at");
        assertEq(auction.rngRequestId, 99, "rng request id");
    }

    function testStartDraw_RewardRecipientIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(RewardRecipientIsZero.selector));
        drawManager.startDraw(address(0), 99);
    }

    function testStartDraw_DrawHasNotClosed() public {
        mockDrawIdToAward(1);
        mockDrawClosingTime(2 days);
        vm.expectRevert(abi.encodeWithSelector(DrawHasNotClosed.selector));
        drawManager.startDraw(alice, 99);
    }

    function testStartDraw_AlreadyStartedDraw() public {
        startFirstDraw();

        vm.expectRevert(abi.encodeWithSelector(AlreadyStartedDraw.selector));
        drawManager.startDraw(alice, 99);
    }

    function testStartDraw_RngRequestNotInSameBlock() public {
        vm.warp(1 days);
        mockReserve(1e18, 0);
        mockRng(99, 0x1234);
        mockRequestedAtBlock(99, block.number - 1);

        vm.expectRevert(abi.encodeWithSelector(RngRequestNotInSameBlock.selector));
        drawManager.startDraw(alice, 99);
    }

    function testStartDraw_AuctionExpired() public {
        vm.warp(1 days + auctionDuration + 1);
        mockReserve(1e18, 0);
        mockRng(99, 0x1234);
        vm.expectRevert(abi.encodeWithSelector(AuctionExpired.selector));
        drawManager.startDraw(alice, 99);
    }

    function testCanAwardDraw() public {
        startFirstDraw();
        vm.warp(1 days + auctionTargetTime);
        assertTrue(drawManager.canAwardDraw(), "can award draw");
    }

    function testCanAwardDraw_rngNotComplete() public {
        startFirstDraw();
        mockRngComplete(99, false);
        vm.warp(1 days + auctionTargetTime);
        assertFalse(drawManager.canAwardDraw(), "can award draw");
    }

    function testCanAwardDraw_notCurrentDraw() public {
        startFirstDraw();
        vm.warp(2 days); // not strictly needed, but makes the test more clear
        mockDrawIdToAwardAndClosingTime(2, 2 days);
        assertFalse(drawManager.canAwardDraw(), "can no longer award draw");
    }

    function testCanAwardDraw_auctionElapsed() public {
        startFirstDraw();
        vm.warp(1 days + auctionDuration + 1); // not strictly needed, but makes the test more clear
        assertFalse(drawManager.canAwardDraw(), "auction has expired");
    }

    function testAwardDrawFee_zero() public {
        startFirstDraw();
        vm.warp(1 days);
        // not quite zero...tricky math gremlins here
        assertEq(drawManager.finishDrawReward(), 19, "award draw fee");
    }

    function testAwardDrawFee_targetTime() public {
        startFirstDraw();
        vm.warp(1 days + auctionTargetTime);
        assertEq(drawManager.finishDrawReward(), 199999999999999994, "award draw fee");
    }

    function testAwardDrawFee_nextDraw() public {
        startFirstDraw();
        // current draw id to award is now 2
        mockDrawIdToAward(2);
        assertEq(drawManager.finishDrawReward(), 0, "award draw fee");
    }

    function testAwardDrawFee_afterAuctionEnded() public {
        startFirstDraw();
        vm.warp(1 days + auctionDuration * 2);
        assertEq(drawManager.finishDrawReward(), 0, "award draw fee");
    }

    function testAwardDraw() public {
        startFirstDraw();
        vm.warp(1 days + auctionTargetTime);

        mockAwardDraw(0x1234);
        vm.expectEmit(true, true, true, true);
        emit DrawAwarded(
            1,
            alice,
            28,
            bob,
            199999999999999994,
            1e18 - 199999999999999994 - 28
        );
        drawManager.finishDraw(bob);
    }

    function testAwardDraw_zeroRewards() public {
        startFirstDraw();
        mockReserve(0, 0);
        vm.warp(1 days + auctionTargetTime);

        mockAwardDraw(0x1234);
        vm.expectEmit(true, true, true, true);
        emit DrawAwarded(
            1,
            alice,
            0,
            bob,
            0,
            0
        );
        drawManager.finishDraw(bob);
    }

    function testAwardDraw_DrawHasFinalized() public {
        startFirstDraw();
        vm.warp(2 days);
        mockDrawIdToAward(2);
        vm.expectRevert(abi.encodeWithSelector(DrawHasFinalized.selector));
        drawManager.finishDraw(bob);
    }

    function testAwardDraw_RngRequestNotComplete() public {
        startFirstDraw();
        mockRngComplete(99, false);
        vm.expectRevert(abi.encodeWithSelector(RngRequestNotComplete.selector));
        drawManager.finishDraw(bob);
    }

    function testAwardDraw_AuctionExpired() public {
        startFirstDraw();
        vm.warp(1 days + auctionDuration + 1);
        vm.expectRevert(abi.encodeWithSelector(AuctionExpired.selector));
        drawManager.finishDraw(bob);
    }

    function testAwardDraw_RewardRecipientIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(RewardRecipientIsZero.selector));
        drawManager.finishDraw(address(0));
    }

    function testComputeRewards() public {
        UD2x18[] memory rewardFractions = new UD2x18[](2);
        rewardFractions[0] = UD2x18.wrap(0.5e18);
        rewardFractions[1] = UD2x18.wrap(0.4e18);
        uint256[] memory rewards = drawManager.computeRewards(rewardFractions, 100e18);
        assertEq(rewards[0], 50e18, "first reward");
        assertEq(rewards[1], 20e18, "second reward");
    }

    function startFirstDraw() public {
        vm.warp(1 days);
        mockReserve(1e18, 0);
        mockRng(99, 0x1234);
        vm.expectEmit(true, true, true, true);
        emit RngAuctionCompleted(address(this), alice, 1, 99, 0);
        drawManager.startDraw(alice, 99);
    }

    function mockAwardDraw(uint randomNumber) public {
        uint24 drawIdToAward = prizePool.getDrawIdToAward();
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.awardDraw.selector, randomNumber), abi.encode(drawIdToAward));
    }

    function mockAllocateRewardFromReserve(address recipient, uint amount) public {
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.allocateRewardFromReserve.selector, recipient, amount), abi.encode());
    }

    function mockRequestedAtBlock(uint32 rngRequestId, uint256 blockNumber) public {
        vm.mockCall(address(rng), abi.encodeWithSelector(rng.requestedAtBlock.selector, rngRequestId), abi.encode(blockNumber));
    }

    function mockRng(uint32 rngRequestId, uint256 randomness) public {
        mockRequestedAtBlock(rngRequestId, block.number);
        vm.mockCall(address(rng), abi.encodeWithSelector(rng.randomNumber.selector, rngRequestId), abi.encode(randomness));
        mockRngComplete(rngRequestId, true);
    }

    function mockRngComplete(uint32 rngRequestId, bool isComplete) public {
        vm.mockCall(address(rng), abi.encodeWithSelector(rng.isRequestComplete.selector, rngRequestId), abi.encode(isComplete));
    }

    function mockDrawPeriodSeconds(uint256 amount) public {
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.drawPeriodSeconds.selector), abi.encode(amount));
    }

    function mockDrawClosingTime(uint256 closingAt) public {
        mockDrawIdToAwardAndClosingTime(1, closingAt);
    }

    function mockDrawIdToAward(uint24 drawId) public {
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.getDrawIdToAward.selector), abi.encode(drawId));
    }

    function mockDrawIdToAwardAndClosingTime(uint24 drawId, uint256 closingAt) public {
        mockDrawIdToAward(drawId);
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.drawClosesAt.selector, drawId), abi.encode(closingAt));
    }

    function mockReserve(uint reserve, uint pendingReserve) public {
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.reserve.selector), abi.encode(reserve));
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.pendingReserveContributions.selector), abi.encode(pendingReserve));
    }

    function newDrawManager() public {
        drawManager = new DrawManager(
            prizePool,
            rng,
            auctionDuration,
            auctionTargetTime,
            lastStartRngRequestFraction,
            lastAwardDrawFraction,
            maxRewards,
            remainingRewardsRecipient
        );
    }
}