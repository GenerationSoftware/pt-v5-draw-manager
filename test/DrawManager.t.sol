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
    AuctionTargetTimeExceedsDuration,
    AuctionDurationGTDrawPeriodSeconds,
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

    function testStartDrawFee() public {
        vm.warp(1 days);
        mockReserve(1e18, 0);
        // zero is not possible here; not sure why
        assertEq(drawManager.startDrawFee(), 28, "start draw fee");
    }

    function testStartDrawFee_cannotStart() public {
        vm.warp(2 days);
        assertEq(drawManager.startDrawFee(), 0, "start draw fee");
    }

    function testStartDrawFee_atTarget() public {
        vm.warp(1 days + auctionTargetTime);
        mockReserve(2e18, 0);
        assertEq(drawManager.startDrawFee(), 0.2e18, "start draw fee");
    }

    function testStartDrawFee_afterTarget() public {
        vm.warp(1 days + auctionTargetTime + (auctionDuration - auctionTargetTime) / 2);
        mockReserve(2e18, 0);
        assertEq(drawManager.startDrawFee(), 649999999999999996, "start draw fee");
    }

    function testStartDraw() public {
        startFirstDraw();

        StartRngRequestAuction memory auction = drawManager.getLastAuction();

        assertEq(auction.recipient, alice, "recipient");
        assertEq(auction.drawId, 1, "draw id");
        assertEq(auction.startedAt, block.timestamp, "started at");
        assertEq(auction.rngRequestId, 99, "rng request id");
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

    function testAwardDrawFee_zero() public {
        startFirstDraw();
        vm.warp(1 days);
        // not quite zero...tricky math gremlins here
        assertEq(drawManager.awardDrawFee(), 19, "award draw fee");
    }

    function testAwardDrawFee_targetTime() public {
        startFirstDraw();
        vm.warp(1 days + auctionTargetTime);
        assertEq(drawManager.awardDrawFee(), 199999999999999994, "award draw fee");
    }

    function testAwardDrawFee_overtime() public {
        startFirstDraw();
        vm.warp(2 days); // not strictly needed, but makes the test more clear
        mockDrawIdToAwardAndClosingTime(2, 2 days);
        assertEq(drawManager.awardDrawFee(), 0, "award draw fee");
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
        drawManager.awardDraw(bob);
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

    function mockRng(uint32 rngRequestId, uint256 randomness) public {
        vm.mockCall(address(rng), abi.encodeWithSelector(rng.requestedAtBlock.selector, rngRequestId), abi.encode(block.number));
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

    function mockDrawIdToAwardAndClosingTime(uint24 drawId, uint256 closingAt) public {
        vm.mockCall(address(prizePool), abi.encodeWithSelector(prizePool.getDrawIdToAward.selector), abi.encode(drawId));
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