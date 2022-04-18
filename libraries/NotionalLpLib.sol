// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
import "../interfaces/notional/nTokenERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/balancer/BalancerV2.sol";
import "../interfaces/sushi/ISushiRouter.sol";
import "../interfaces/IWETH.sol";

library NotionalLpLib {
    using SafeMath for uint256;
    int256 private constant PRICE_DECIMALS = 1e18;
    IWETH private constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    struct NTokenTotalValueFromPortfolioVars {
        address _strategy;
        address _nTokenAddress;
        NotionalProxy _nProxy;
        uint16 _currencyID;
    }

    /*
     * @notice
     *  Get the current value of the nToken LP position
     * @param NTokenVars, custom struct containing:
     * - _strategy, address of the strategy owning the position
     * - _nTokenAddress, address of the nToken to use
     * - _nProxy, address of the Notional Proxy
     * - _currencyID, currency ID of the strategy
     * @return uint256 totalUnderlyingClaim, total number of want tokens
     */
    function getNTokenTotalValueFromPortfolio(
        NTokenTotalValueFromPortfolioVars memory NTokenVars
        ) public view returns(uint256 totalUnderlyingClaim) {
        
        // If the nToken has an idiosyncratic position we are in the 24h lock period and cannot calculate the 
        // portfolio value as there is an fcash position without market
        if (checkIdiosyncratic(NTokenVars._nProxy, NTokenVars._currencyID, NTokenVars._nProxy.nTokenAddress(NTokenVars._currencyID))) {
            return 0;
        }

        // First step, get how many nTokens the strategy owns
        (, int256 nTokenBalance, ) = NTokenVars._nProxy.getAccountBalance(NTokenVars._currencyID, NTokenVars._strategy);

        if (nTokenBalance > 0) {
            // Get the current portfolio of the nToken that provided liquidity to the different pools:
            // - liquidity tokens provided to each pool
            // - current fcash position in each pool
            (PortfolioAsset[] memory liquidityTokens, PortfolioAsset[] memory netfCashAssets) = NTokenVars._nProxy.getNTokenPortfolio(NTokenVars._nTokenAddress);
            // Get the current state of the active markets, notably:
            // - # of liquidity tokens used to provide liquidity to each market
            // - current # of asset tokens available in each market
            // - current # of fcash tokens available in each market
            MarketParameters[] memory _activeMarkets = NTokenVars._nProxy.getActiveMarkets(NTokenVars._currencyID);
            
            // Total number of nTokens available, used to calculate the share of the strategy
            int256 totalSupply = int256(NTokenVars._nProxy.nTokenTotalSupply(NTokenVars._nTokenAddress));

            // Iterate over all active markets and sum value of each position 
            int256 fCashClaim = 0;
            int256 assetCashClaim = 0;
            int256 totalAssetCashClaim = 0;
            
            // Process to get the current value of the position:
            // For each available market:
            // 1. Calculate the share of liquidity brought by the nToken by calculating the ratio between the 
            // # of nToken liq. tokens for theta market and the total liquidity tokens that fed that spcedific market
            // 2. Using that liq. share calculate the proportion of cTokens and fcash that the nToken "owns"
            // 3. Net the current share of market fcash against the current fcash position of the nToken (could be net lender or borrower)
            // 4. Calculate the strategy's share of both the cToken and fcash by applying the proportion between the held
            // nTokens and the total supply
            // 5. Convert the net fcash to cTokens and add it to the cTokens share from step 2
            // 6. Add the cToken position for each market
            // 7. Convert to underlying
            for(uint256 i = 0; i < liquidityTokens.length; i++) {
                // 1-2. Calculate the fcash claim on the market using liquidity tokens share
                fCashClaim = liquidityTokens[i].notional * _activeMarkets[i].totalfCash / _activeMarkets[i].totalLiquidity;
                // 1-2. Calculate the cTokens claim on the market using liquidity tokens share
                assetCashClaim = liquidityTokens[i].notional * _activeMarkets[i].totalAssetCash / _activeMarkets[i].totalLiquidity;
                // 3. Net the fcash share against the current fcash position of the nToken
                fCashClaim += netfCashAssets[i].notional;
                // 4. Calculate the strategy's share of fcash claim
                fCashClaim = fCashClaim * nTokenBalance / totalSupply;
                // 4. Calculate the strategy's share of cToken claim
                assetCashClaim = assetCashClaim * nTokenBalance / totalSupply;

                if (fCashClaim != 0) {
                    uint256 mIndex = getMarketIndexForMaturity(
                        NTokenVars._nProxy,
                        NTokenVars._currencyID,
                        liquidityTokens[i].maturity
                        );
                    // 5. Convert the netfcash claim to cTokens
                    (int256 assetInternalNotation,) = NTokenVars._nProxy.getCashAmountGivenfCashAmount(
                        NTokenVars._currencyID,
                        int88(-fCashClaim),
                        mIndex,
                        block.timestamp
                    );
                    // 5. Add it to the cToken share of market liquidity
                    assetCashClaim += assetInternalNotation;
                }
                // 6. Add positions for each market
                totalAssetCashClaim += assetCashClaim;
            }

            (
                Token memory assetToken,
                Token memory underlyingToken,
                ,
                AssetRateParameters memory assetRate
            ) = NTokenVars._nProxy.getCurrencyAndRates(NTokenVars._currencyID);
            // 7. Convert the cToken position to underlying
            totalUnderlyingClaim = uint256(totalAssetCashClaim * assetRate.rate / PRICE_DECIMALS);
        }
    }

    /*
     * @notice
     *  Get the market index for a specific maturity
     * @param _nProxy, Notional proxy address
     * @param _currencyID, Currency ID of the strategy
     * @param _maturity, Maturity to look for
     * @return uint256 index of the market we're looking for
     */
    function getMarketIndexForMaturity(
        NotionalProxy _nProxy,
        uint16 _currencyID,
        uint256 _maturity
    ) internal view returns(uint256) {
        MarketParameters[] memory _activeMarkets = _nProxy.getActiveMarkets(_currencyID);
        bool success = false;
        for(uint256 j=0; j<_activeMarkets.length; j++){
            if(_maturity == _activeMarkets[j].maturity) {
                return j+1;
            }
        }
        
        if (success == false) {
            return 0;
        }
    }

    /*
     * @notice
     *  Check whether the nToken has an idiosyncratic fcash position (non-opeable market) by looping through
     * the nToken positions (max is 3) and check whether it has a current active market or not
     * @param _nProxy, Notional proxy address
     * @param _currencyID, Currency ID of the strategy
     * @param _nTokenAddress, Address for the nToken
     * @return bool indicating whether the nToken has an idiosyncratic position or not
     */
    function checkIdiosyncratic(
        NotionalProxy _nProxy,
        uint16 _currencyID,
        address _nTokenAddress
    ) public view returns(bool) {
        MarketParameters[] memory _activeMarkets = _nProxy.getActiveMarkets(_currencyID);
        (, PortfolioAsset[] memory netfCashAssets) = _nProxy.getNTokenPortfolio(_nTokenAddress);
        for(uint256 i=0; i<netfCashAssets.length; i++){
            if(getMarketIndexForMaturity(_nProxy, _currencyID, netfCashAssets[i].maturity) == 0) {
                return true;
            }
        }
        return false;
    }

    /*
     * @notice
     *  External view estimating the rewards value in want tokens. We simulate the trade in balancer to 
     * get WETH from the NOTE / WETH pool and if want is not weth, we simulate a trade in sushi to obtain want tokens 
     * @param noteToken, rewards token to estimate value
     * @param nProxy, notional proxy distributing the rewards
     * @param balancerVault, vault address in Balancer to simulate the swap
     * @param poolId, identifier NOTE/weth pool in balancer
     * @param currencyID, identifier of the currency operated in the strategy
     * @param quoter, sushi router used to estimate simulate the weth / want trade
     * @param want, address of the want token to convert the rewards to
     * @return uint256 tokensOut, current number of want tokens the strategy would obtain for its rewards
     */
    function getRewardsValue(
        IERC20 noteToken,
        NotionalProxy nProxy,
        IBalancerVault balancerVault,
        bytes32 poolId,
        IBalancerPool balancerPool,
        uint16 currencyID,
        ISushiRouter quoter,
        address want
    ) external view returns(uint256 tokensOut) {
        // Get NOTE rewards
        uint256 claimableRewards = noteToken.balanceOf(address(this));
        claimableRewards += nProxy.nTokenGetClaimableIncentives(address(this), block.timestamp);
        if (claimableRewards > 0) {
            (IERC20[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock) = balancerVault.getPoolTokens(poolId);
            // Setup SwapRequest object for balancer
            IBalancerPool.SwapRequest memory swapRequest = IBalancerPool.SwapRequest(
                IBalancerPool.SwapKind.GIVEN_IN,
                tokens[1],
                tokens[0],
                claimableRewards,
                poolId,
                lastChangeBlock,
                address(this),
                address(this),
                abi.encode(0)
            );
            // Simulate NOTE/WETH trade
            tokensOut = balancerPool.onSwap(
                swapRequest, 
                balances[1],
                balances[0] 
            );
            
            // If want is not weth, simulate sushi trade
            if(currencyID > 1) {
                // Sushi path is [weth, want]
                address[] memory path = new address[](2);
                path[0] = address(weth);
                path[1] = address(want);
                // Get expected number of tokens out
                tokensOut = quoter.getAmountsOut(tokensOut, path)[1];
            }
        }

    }

    /*
     * @notice
     *  Function exchanging between ETH to 'want'
     * @param amount, Amount to exchange
     * @param asset, 'want' asset to exchange to
     * @param nProxy, Notional Proxu address
     * @param currendyID, ID of want
     * @return uint256 result, the equivalent ETH amount in 'want' tokens
     */
    function fromETH(
        uint256 amount,
        address asset,
        NotionalProxy nProxy,
        uint16 currencyID
        )
        external
        view
        returns (uint256)
    {
        if (
            amount == 0 ||
            amount == type(uint256).max ||
            address(asset) == address(weth) // 1:1 change
        ) {
            return amount;
        }

        (
            Token memory assetToken,
            Token memory underlyingToken,
            ETHRate memory ethRate,
            AssetRateParameters memory assetRate
        ) = nProxy.getCurrencyAndRates(currencyID);
            
        return amount.mul(uint256(underlyingToken.decimals)).div(uint256(ethRate.rate));
    }

}