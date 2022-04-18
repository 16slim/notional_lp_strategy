// SPDX-License-Identifier: GPL-v3
pragma solidity 0.6.12;

interface ISushiRouter {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns(uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
} 
