// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPrizePool - interface for Prize Pools
interface IPrizePool {
    function getDrawIdToAward() external view returns (uint24);
    function awardDraw(uint256 winningRandomNumber_) external returns (uint24);
    function allocateRewardFromReserve(address _to, uint96 _amount) external;
}
