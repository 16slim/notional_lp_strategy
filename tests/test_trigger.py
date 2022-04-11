from datetime import timedelta
from utils import actions, checks, utils
import pytest

def test_harvest_trigger(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    amount_invested = vault.strategies(strategy)["totalDebt"]

    account = n_proxy_views.getAccount(strategy)
    amount_tokens = account[1][0][2]

    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    # No harvest trigger as there are more than 12h until market roll
    assert strategy.harvestTrigger(1) == False

    first_maturity = active_markets[0][1]

    chain.mine(1, timestamp = first_maturity - 12*3600 + 1)
    # No harvest trigger as there is still some debt ratio
    assert strategy.harvestTrigger(1) == False

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    # Harvest trigger fires
    assert strategy.harvestTrigger(1) == True
    
    chain.mine(1, timestamp = first_maturity + 1)
    n_proxy_implementation.initializeMarkets(currencyID, False, {"from":accounts[0]})

    if strategy.checkIdiosyncratic():
        actions.buy_residuals(n_proxy_batch, n_proxy_implementation, currencyID, million_in_token, token, token_whale)

    # No harvest trigger as markets have rolled
    assert strategy.harvestTrigger(1) == False

    strategy.setToggleLiquidatePosition(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})
    
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})

    
