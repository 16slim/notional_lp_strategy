def getLiquidityTokenValue(assetType, notional, markets):
    index = assetType - 2
    fCashClaim = markets[index][2] * notional / markets[index][4]
    assetCashClaim = markets[index][3] * notional / markets[index][4]
    
    return (fCashClaim, assetCashClaim)

def getfCashResidualByMaturity(fCash, maturity):
    for fc in fCash:
        if fc[1] == maturity:
            return fc[3]
    return 0

def getMarketIndexForMaturity(markets, maturity):
    for (i,m) in enumerate(markets):
        if m[1] == maturity:
            return i+1
    return 0

token.approve(n_proxy_batch.address, 2**255, {"from":user})

n_proxy_batch.batchBalanceAndTradeAction(user, \
        [(4,currencyID,1e21,0,1,1,\
            [])], \
                {"from": user,\
                     "value":0})

chain.mine(1, timedelta=30*86400)
# n_proxy_implementation.initializeMarkets(2, 0, {"from": user})

nToken = n_proxy_implementation.nTokenAddress(2)
totalSupply = n_proxy_implementation.nTokenTotalSupply(nToken)
(liquidityTokens, fCash) = n_proxy_implementation.getNTokenPortfolio(nToken)
cashBalanceToken = n_proxy_views.getNTokenAccount(nToken)["cashBalance"]
nTokens = n_proxy_views.getAccount(user)["accountBalances"][0][2]
assert nTokens > 0
cashBalanceShare = cashBalanceToken * nTokens / totalSupply
markets = n_proxy_views.getActiveMarkets(currencyID)

totalAssetCash = 0
for (i, lt) in enumerate(liquidityTokens):
    (fCashClaim, assetCashClaim) = getLiquidityTokenValue(lt[2], lt[3], markets)
    netfCash = fCashClaim + getfCashResidualByMaturity(fCash, lt[1])
    netfCashShare = nTokens * netfCash / totalSupply
    assetCashShare = nTokens * assetCashClaim / totalSupply

    if netfCashShare != 0:
        mIndex = getMarketIndexForMaturity(markets, lt[1])
        netCashToAccount = n_proxy_views.getCashAmountGivenfCashAmount(currencyID, -netfCashShare, mIndex, chain.time())
        netAssetCashShare = netCashToAccount[0]
        totalAssetCash += netAssetCashShare

    totalAssetCash += assetCashShare

n_proxy_implementation.nTokenRedeem(user, 2, nTokens, 1, {"from": user})

n_proxy_batch.batchBalanceAction(strategy, \
[(5,currencyID,nTokens,0,1,1)], \
        {"from": strategy,\
            "value":0})


