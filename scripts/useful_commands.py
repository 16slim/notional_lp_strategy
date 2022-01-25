nProxy_batch.batchBalanceAndTradeAction(accounts[0], \
        [(2,1,100e18,0,1,1,\
            [0x000100000000000002198dd90200000000000000000000000000000000000000])], \
                {"from": accounts[0],\
                     "value":100e18})
nProxy_batch.batchBalanceAndTradeAction(whale, \
        [(2,1,100e24,0,1,1,\
            [0x0001000000001c7665d2c8120000000000000000000000000000000000000000])], \
                {"from": whale,\
                     "value":0})
nProxy_batch.batchBalanceAndTradeAction(accounts[-1], \
        [(2,1,1000e18,0,1,1,\
            [0x0001000000000000174912f60000000000000000000000000000000000000000])], \
                {"from": accounts[-1],\
                     "value":1000e18})
n_proxy_batch.batchBalanceAndTradeAction(user, \
        [(2,2,1e18,0,1,1,\
            [0x0001000000000000000613747c00000000000000000000000000000000000000])], \
                {"from": user,\
                     "value":0})
n_proxy_batch.batchBalanceAndTradeAction(strategy, \
        [(0,2,0,0,1,1,\
            [0x010100000000000940385bd7a000000000000000000000000000000000000000])], \
                {"from": strategy,\
                     "value":0})
nProxy_batch.batchBalanceAndTradeAction(whale, \
        [(0,1,0,0,1,1,\
            [0x01010000000000000babb17bf800000000000000000000000000000000000000])], \
                {"from": whale,\
                     "value":0})

nProxy_batch.batchBalanceAndTradeAction("0x12B1b1d8fF0896303E2C4d319087F5f14A537395", \
        [(2,1,1e18,0,1,1,\
            [0x0001000000000000000099323a00000000000000000000000000000000000000])], \
                {"from": "0x12B1b1d8fF0896303E2C4d319087F5f14A537395",\
                     "value":1e18})
accounts.at("0x12B1b1d8fF0896303E2C4d319087F5f14A537395", force=True)
nProxy_batch.batchBalanceAndTradeAction("0x12B1b1d8fF0896303E2C4d319087F5f14A537395", \
        [(0,1,0,0,1,1,\
            [0x01020000000000000005fbf6440209b341000000000000000000000000000000])], \
                {"from": "0x12B1b1d8fF0896303E2C4d319087F5f14A537395",\
                     "value":0})

>>> accountJ.balance() - balancePre
996322199871610067
>>> (accountJ.balance() - balancePre) / 1e18
0.9963221998716101
>>> ((accountJ.balance() - balancePre) - 999999990000000000)
-3677790128389933
>>> ((accountJ.balance() - balancePre) - 999999990000000000) / 1e18
-0.003677790128389933
nProxy_views.getCashAmountGivenfCashAmount(1,-100398660,2,chain
.time()+1)



n_proxy_batch.batchBalanceAndTradeAction(usdcWhale, \
        [(2,3,100000e6,0,0,0,\
            [trade])], \
                {"from": usdcWhale,\
                     "value":0})
n_proxy_batch.batchBalanceAndTradeAction(accounts[0], \
        [(0,3,0,0,1,1,\
            [trade])], \
                {"from": accounts[0],\
                     "value":0})