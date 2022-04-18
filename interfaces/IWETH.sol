// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
    function balanceOf(address user) external returns (uint256);
}