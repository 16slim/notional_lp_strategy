// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library NotionalLpLib {
    using SafeMath for uint256;

    struct NTokenTotalValueFromPortfolioVars {
        address _strategy;
        address _nTokenAddress;
        NotionalProxy _nProxy;
        uint16 _currencyID;
    }

    function getNTokenTotalValueFromPortfolio(
        NTokenTotalValueFromPortfolioVars memory NTokenVars
        ) public view returns(uint256 totalUnderlyingClaim) {
        
        (, int256 nTokenBalance, ) = NTokenVars._nProxy.getAccountBalance(NTokenVars._currencyID, NTokenVars._strategy);

        if (nTokenBalance > 0) {
            (PortfolioAsset[] memory liquidityTokens, PortfolioAsset[] memory netfCashAssets) = NTokenVars._nProxy.getNTokenPortfolio(NTokenVars._nTokenAddress);
            MarketParameters[] memory _activeMarkets = NTokenVars._nProxy.getActiveMarkets(NTokenVars._currencyID);
            // TODO: Implement _checkIdiosyncratic(_activeMarkets, netfCashAssets);
            int256 totalSupply = int256(NTokenVars._nProxy.nTokenTotalSupply(NTokenVars._nTokenAddress));

            // Iterate over all active markets and sum value of each position 
            int256 fCashClaim = 0;
            int256 assetCashClaim = 0;
            int256 totalAssetCashClaim = 0;
            
            for(uint256 i = 0; i < liquidityTokens.length; i++) {

                fCashClaim = liquidityTokens[i].notional * _activeMarkets[i].totalfCash / _activeMarkets[i].totalLiquidity;
                assetCashClaim = liquidityTokens[i].notional * _activeMarkets[i].totalAssetCash / _activeMarkets[i].totalLiquidity;
                fCashClaim += netfCashAssets[i].notional;

                fCashClaim = fCashClaim * nTokenBalance / totalSupply;
                assetCashClaim = assetCashClaim * nTokenBalance / totalSupply;

                if (fCashClaim > 0) {
                    uint256 mIndex = getMarketIndexForMaturity(
                        NTokenVars._nProxy,
                        NTokenVars._currencyID,
                        liquidityTokens[i].maturity
                        );
                    (int256 assetInternalNotation,) = NTokenVars._nProxy.getCashAmountGivenfCashAmount(
                        NTokenVars._currencyID,
                        int88(-fCashClaim),
                        mIndex,
                        block.timestamp
                    );
                    assetCashClaim += assetInternalNotation;
                }
                totalAssetCashClaim += assetCashClaim;
            }
            // totalAssetCashClaim = totalAssetCashClaim;

            (
                Token memory assetToken,
                Token memory underlyingToken,
                ,
                AssetRateParameters memory assetRate
            ) = NTokenVars._nProxy.getCurrencyAndRates(NTokenVars._currencyID);

            totalUnderlyingClaim = uint256(totalAssetCashClaim * assetRate.rate / assetRate.underlyingDecimals);
        }
    }

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