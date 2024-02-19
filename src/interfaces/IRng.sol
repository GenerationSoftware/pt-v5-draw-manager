// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRng {
    function requestedAtBlock(uint32 rngRequestId) external returns (uint256);
    function isRequestComplete(uint32 rngRequestId) external returns (bool);
    function randomNumber(uint32 rngRequestId) external returns (uint256);
}
