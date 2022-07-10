// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
import "../interfaces/notional/nTokenERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/balancer/BalancerV2.sol";
import "../interfaces/sushi/ISushiRouter.sol";
import "../interfaces/IWETH.sol";

library NotionalLpLib {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    int256 private constant PRICE_DECIMALS = 1e18;
    uint256 private constant SLIPPAGE_FACTOR = 9_800;
    uint256 private constant MAX_BPS = 10_000;
    IWETH private constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 private constant WETH_DECIMALS = 1e18;
    uint8 private constant TRADE_TYPE_LEND = 0;
    uint16 private constant ETH_CURRENCY_ID = 1;

    struct NTokenTotalValueFromPortfolioVars {
        address _strategy;
        address _nTokenAddress;
        NotionalProxy _notionalProxy;
        uint16 _currencyID;
    }
    struct RewardsValueVars {
        IERC20 noteToken;
        NotionalProxy notionalProxy;
        IBalancerVault balancerVault;
        bytes32 poolId;
        IBalancerPool balancerPool;
        uint16 currencyID;
        ISushiRouter quoter;
        address want;
    }

    /*
     * @notice
     *  Get the current value of the nToken LP position following the same methodology as in: 
     *  https://github.com/notional-finance/sdk-v2/blob/master/src/system/NTokenValue.ts#L165-L171
     * @param NTokenVars, custom struct containing:
     * - _strategy, address of the strategy owning the position
     * - _nTokenAddress, address of the nToken to use
     * - _notionalProxy, address of the Notional Proxy
     * - _currencyID, currency ID of the strategy
     * @return uint256 totalUnderlyingClaim, total number of want tokens
     */
    function getNTokenTotalValueFromPortfolio(
        NTokenTotalValueFromPortfolioVars memory NTokenVars
        ) public view returns(uint256 totalUnderlyingClaim) {
        
        // If the nToken has an idiosyncratic position we are in the 24h lock period and cannot calculate the 
        // portfolio value as there is an fcash position without market
        if (checkIdiosyncratic(NTokenVars._notionalProxy, NTokenVars._currencyID, NTokenVars._notionalProxy.nTokenAddress(NTokenVars._currencyID))) {
            return 0;
        }

        // First step, get how many nTokens the strategy owns
        (, int256 nTokenBalance, ) = NTokenVars._notionalProxy.getAccountBalance(NTokenVars._currencyID, NTokenVars._strategy);

        if (nTokenBalance > 0) {
            // Get the current portfolio of the nToken that provided liquidity to the different pools:
            // - liquidity tokens provided to each pool
            // - current fcash position in each pool
            (PortfolioAsset[] memory liquidityTokens, PortfolioAsset[] memory netfCashAssets) = NTokenVars._notionalProxy.getNTokenPortfolio(NTokenVars._nTokenAddress);
            // Get the current state of the active markets, notably:
            // - # of liquidity tokens used to provide liquidity to each market
            // - current # of asset tokens available in each market
            // - current # of fcash tokens available in each market
            MarketParameters[] memory _activeMarkets = NTokenVars._notionalProxy.getActiveMarkets(NTokenVars._currencyID);
            
            // Total number of nTokens available, used to calculate the share of the strategy
            int256 totalSupply = SafeCast.toInt256(NTokenVars._notionalProxy.nTokenTotalSupply(NTokenVars._nTokenAddress));

            // Iterate over all active markets and sum value of each position 
            int256 fCashClaim = 0;
            int256 assetCashClaim = 0;
            (,,,,,int256 totalAssetCashClaim,,) = NTokenVars._notionalProxy.getNTokenAccount(NTokenVars._nTokenAddress);
            totalAssetCashClaim = totalAssetCashClaim.mul(nTokenBalance).div(totalSupply);

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
                if(liquidityTokens[i].maturity == _activeMarkets[i].maturity) {
                    // 1-2. Calculate the fcash claim on the market using liquidity tokens share
                    fCashClaim = liquidityTokens[i].notional.mul(_activeMarkets[i].totalfCash).div(_activeMarkets[i].totalLiquidity);
                    // 1-2. Calculate the cTokens claim on the market using liquidity tokens share
                    assetCashClaim = liquidityTokens[i].notional.mul(_activeMarkets[i].totalAssetCash).div(_activeMarkets[i].totalLiquidity);
                    // 3. Net the fcash share against the current fcash position of the nToken
                    fCashClaim += netfCashAssets[i].notional;
                    // 4. Calculate the strategy's share of fcash claim
                    fCashClaim = fCashClaim.mul(nTokenBalance).div(totalSupply);
                    // 4. Calculate the strategy's share of cToken claim
                    assetCashClaim = assetCashClaim.mul(nTokenBalance).div(totalSupply);

                    if (fCashClaim != 0) {
                        uint256 mIndex = getMarketIndexForMaturity(
                            NTokenVars._notionalProxy,
                            NTokenVars._currencyID,
                            liquidityTokens[i].maturity
                            );
                        // 5. Convert the netfcash claim to cTokens
                        (int256 assetInternalNotation,) = NTokenVars._notionalProxy.getCashAmountGivenfCashAmount(
                            NTokenVars._currencyID,
                            toInt88(-fCashClaim),
                            mIndex,
                            block.timestamp
                        );
                        // 5. Add it to the cToken share of market liquidity
                        assetCashClaim = assetCashClaim.add(assetInternalNotation);
                    }
                    // 6. Add positions for each market
                    totalAssetCashClaim = totalAssetCashClaim.add(assetCashClaim);
                }
            }

            (
                Token memory assetToken,
                Token memory underlyingToken,
                ,
                AssetRateParameters memory assetRate
            ) = NTokenVars._notionalProxy.getCurrencyAndRates(NTokenVars._currencyID);
            // 7. Convert the cToken position to underlying
            totalUnderlyingClaim = uint256(totalAssetCashClaim.mul(assetRate.rate).div(PRICE_DECIMALS));
        }
    }

    /*
     * @notice
     *  Get the market index for a specific maturity
     * @param _notionalProxy, Notional proxy address
     * @param _currencyID, Currency ID of the strategy
     * @param _maturity, Maturity to look for
     * @return uint256 index of the market we're looking for
     */
    function getMarketIndexForMaturity(
        NotionalProxy _notionalProxy,
        uint16 _currencyID,
        uint256 _maturity
    ) internal view returns(uint256) {
        MarketParameters[] memory _activeMarkets = _notionalProxy.getActiveMarkets(_currencyID);
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
     * @param _notionalProxy, Notional proxy address
     * @param _currencyID, Currency ID of the strategy
     * @param _nTokenAddress, Address for the nToken
     * @return bool indicating whether the nToken has an idiosyncratic position or not
     */
    function checkIdiosyncratic(
        NotionalProxy _notionalProxy,
        uint16 _currencyID,
        address _nTokenAddress
    ) public view returns(bool) {
        MarketParameters[] memory _activeMarkets = _notionalProxy.getActiveMarkets(_currencyID);
        (, PortfolioAsset[] memory netfCashAssets) = _notionalProxy.getNTokenPortfolio(_nTokenAddress);
        for(uint256 i=0; i<netfCashAssets.length; i++){
            if(getMarketIndexForMaturity(_notionalProxy, _currencyID, netfCashAssets[i].maturity) == 0) {
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
     * @param notionalProxy, notional proxy distributing the rewards
     * @param balancerVault, vault address in Balancer to simulate the swap
     * @param poolId, identifier NOTE/weth pool in balancer
     * @param currencyID, identifier of the currency operated in the strategy
     * @param quoter, sushi router used to estimate simulate the weth / want trade
     * @param want, address of the want token to convert the rewards to
     * @return uint256 tokensOut, current number of want tokens the strategy would obtain for its rewards
     */
    function getRewardsValue(
        RewardsValueVars memory rewardsValueVars
    ) external view returns(uint256 tokensOut) {
        // Get NOTE rewards
        uint256 claimableRewards = rewardsValueVars.noteToken.balanceOf(address(this));
        claimableRewards += rewardsValueVars.notionalProxy.nTokenGetClaimableIncentives(address(this), block.timestamp);
        if (claimableRewards > 0) {
            (IERC20[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock) = rewardsValueVars.balancerVault.getPoolTokens(rewardsValueVars.poolId);
            // Setup SwapRequest object for balancer
            IBalancerPool.SwapRequest memory swapRequest = IBalancerPool.SwapRequest(
                IBalancerPool.SwapKind.GIVEN_IN,
                tokens[1],
                tokens[0],
                claimableRewards,
                rewardsValueVars.poolId,
                lastChangeBlock,
                address(this),
                address(this),
                abi.encode(0)
            );
            // Simulate NOTE/WETH trade
            tokensOut = rewardsValueVars.balancerPool.onSwap(
                swapRequest, 
                balances[1],
                balances[0] 
            );
            
            // If want is not weth, simulate sushi trade
            if(rewardsValueVars.currencyID > 1) {
                // Sushi path is [weth, want]
                address[] memory path = new address[](2);
                path[0] = address(weth);
                path[1] = address(rewardsValueVars.want);
                // Get expected number of tokens out
                {
                    tokensOut = rewardsValueVars.quoter.getAmountsOut(WETH_DECIMALS, path)[1].mul(tokensOut).mul(SLIPPAGE_FACTOR).div(MAX_BPS).div(WETH_DECIMALS);
                }
            }
        }

    }

    /*
     * @notice
     *  Function exchanging between ETH to 'want'
     * @param amount, Amount to exchange
     * @param asset, 'want' asset to exchange to
     * @param notionalProxy, Notional Proxu address
     * @param currendyID, ID of want
     * @return uint256 result, the equivalent ETH amount in 'want' tokens
     */
    function fromETH(
        uint256 amount,
        address asset,
        NotionalProxy notionalProxy,
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
        ) = notionalProxy.getCurrencyAndRates(currencyID);
            
        return amount.mul(uint256(underlyingToken.decimals)).div(uint256(ethRate.rate));
    }

    /*
     * @notice
     *  External function used to offset a residual borrowing position
     * @param _notionalProxy, Notional Proxy contract
     * @param _currencyID, ID of token involved
     * @param _amount, Amount to lend
     * @param _fCashAmount, fCash amount needed to offset the residual position
     * @param _marketIndex, market index of the residual position
     * @param _ETH_CURRENCY_ID, ID of ETH as tx changes a little
     * @return bytes32 result, the encoded trade ready to be used in Notional's 'BatchTradeAction'
     */
    function lendAmountManually (
        NotionalProxy _notionalProxy,
        uint16 _currencyID,
        uint256 _amount,
        uint256 _fCashAmount,
        uint256 _marketIndex
    ) external {
        BalanceActionWithTrades[] memory _actions = new BalanceActionWithTrades[](1);
        
        bytes32[] memory _trades = new bytes32[](1);
        _trades[0] = getTradeFrom(TRADE_TYPE_LEND, _marketIndex, _fCashAmount);

        _actions[0] = BalanceActionWithTrades(
            DepositActionType.DepositUnderlying,
            _currencyID,
            _amount,
            0, 
            true,
            true,
            _trades
        );

        if (_currencyID == ETH_CURRENCY_ID) {
            _notionalProxy.batchBalanceAndTradeAction{value: _amount}(address(this), _actions);
            weth.deposit{value: address(this).balance}();
        } else {
            _notionalProxy.batchBalanceAndTradeAction(address(this), _actions);
        }
    }

    /*
     * @notice
     *  Internal function encoding a trade parameter into a bytes32 variable needed for Notional
     * @param _tradeType, Identification of the trade to perform, following the Notional classification in enum 'TradeActionType'
     * @param _marketIndex, Market index in which to trade into
     * @param _amount, fCash amount to trade
     * @return bytes32 result, the encoded trade ready to be used in Notional's 'BatchTradeAction'
     */
    function getTradeFrom(uint8 _tradeType, uint256 _marketIndex, uint256 _amount) internal returns (bytes32 result) {
        uint8 tradeType = uint8(_tradeType);
        uint8 marketIndex = uint8(_marketIndex);
        uint88 fCashAmount = uint88(_amount);
        uint32 minSlippage = uint32(0);
        uint120 padding = uint120(0);

        // We create result of trade in a bitmap packed encoded bytes32
        // (unpacking of the trade in Notional happens here: 
        // https://github.com/notional-finance/contracts-v2/blob/master/contracts/external/actions/TradingAction.sol#L322)
        result = bytes32(uint(tradeType)) << 248;
        result |= bytes32(uint(marketIndex) << 240);
        result |= bytes32(uint(fCashAmount) << 152);
        result |= bytes32(uint(minSlippage) << 120);

        return result;
    }

    /*
     * @notice
     *  Copy safe cast operation from OpenZeppelin for int88
     * @param value, value to cast
     * @return int88 result, the safely casted value
     */
    function toInt88(int256 value) internal pure returns (int88) {
        require(value >= -2**87 && value < 2**87, "SafeCast: value doesn\'t fit in 88 bits");
        return int88(value);
    }

}