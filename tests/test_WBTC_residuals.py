from datetime import timedelta
from utils import actions, checks, utils
import pytest
from brownie import reverts, history, chain

# tests harvesting a strategy that returns profits correctly
def test_wbtc_residuals(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token, sushiswap_router, weth, million_fcash_notation
):
    if token.symbol() != "WBTC":
        pytest.skip()
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy).dict()
    n_tokens = account["accountBalances"][0][2]
    
    with reverts():
        strategy.redeemIdiosyncratic(n_tokens, 1, 0, {"from":gov})
    
    # We need to accept residuals
    strategy.redeemIdiosyncratic(n_tokens, 1, 1, {"from":gov})
    new_account = n_proxy_views.getAccount(strategy).dict()
    market_index = utils.getMarketIndexForMaturity(n_proxy_views.getActiveMarkets(currencyID) , new_account["portfolio"][0][1])
    # Small residual borrow position
    fcash_borrow = new_account["portfolio"][0][3]
    assert fcash_borrow < 0
    # Small collateral balance
    assert new_account["accountBalances"][0][1] > 0

    # We cannot lend now
    with reverts():
        strategy.lendAmountManually(0, -fcash_borrow, market_index+1, {"from":gov})

    if currencyID == 2:
        symbol_collateral = "USDC"
    else:
        symbol_collateral = "DAI"
    
    i = 1
    while (i <= 5):
        print("Whale borrowing million ", i)
        actions.borrow_1m_whales(n_proxy_implementation, currencyID, 
            utils.get_token(symbol_collateral), n_proxy_batch, 
            utils.get_token_whale(symbol_collateral), million_fcash_notation, market_index+1
            )
        i+=1

    strategy.lendAmountManually(0, -fcash_borrow, market_index+1, {"from":gov})
    settled_account = n_proxy_views.getAccount(strategy).dict()
    assert settled_account["accountBalances"][0][1] == 0
    assert settled_account["portfolio"] == ()

    chain.undo()

    to_withdraw = int(new_account["accountBalances"][0][1] * 70 / 100)
    strategy.withdrawFromNotional(to_withdraw, 1, {"from": gov})
    strategy.lendAmountManually(token.balanceOf(strategy), -fcash_borrow, market_index+1, {"from":gov})

    settled_account = n_proxy_views.getAccount(strategy).dict()
    assert settled_account["accountBalances"][0][1] == 0
    assert settled_account["portfolio"] == ()
