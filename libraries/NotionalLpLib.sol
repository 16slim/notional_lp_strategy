// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library NotionalLpLib {
    using SafeMath for uint256;
    int256 private constant PRICE_DECIMALS = 1e18;

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

}