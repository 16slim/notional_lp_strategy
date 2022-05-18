from datetime import timedelta
from utils import actions, checks, utils
import pytest
from brownie import reverts

def test_user_early_exit(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token, sushiswap_router, weth
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    next_strat_queue = vault.withdrawalQueue(0)
    while next_strat_queue != strategy.address:
        vault.removeStrategyFromQueue(next_strat_queue, {"from":gov})
        next_strat_queue = vault.withdrawalQueue(0)

    amount_needed = amount / 2

    assets = strategy.estimatedTotalAssets() - strategy.getRewardsValue()
    unrealized_loss = assets - amount
    loss_to_be_realized = unrealized_loss * amount_needed / amount
    amount_to_liquidate = amount_needed - loss_to_be_realized

    # Withdraw half the balance from the strat, liquidating the positions
    strategy.setSlippage(10, {"from":gov}) # 0.01%
    # This reverts at the intended requires in liquidatePosition but breaks the RPC, commenting it
    # with reverts():
    #     tx = vault.withdraw(int(amount/2), user, 1e4, {"from":user})
    
    slippage = 110
    strategy.setSlippage(slippage, {"from":gov}) # 1.1%
    prev_pps = vault.pricePerShare()
    tx = vault.withdraw(int(amount/2), user, 1e4, {"from":user})

    assert prev_pps == vault.pricePerShare()
    withdrawn = token.balanceOf(user)
    lost = vault.strategies(strategy)["totalLoss"]
    
    # Ensure we haven't allowed more slippage than specified
    assert (lost / loss_to_be_realized + 1) * 1e4 <= slippage
    # Ensure no tokens are lost
    assert withdrawn + lost + vault.strategies(strategy)["totalDebt"] == amount
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setDoHealthCheck(False, {"from": gov})
    actions.sell_rewards_to_want(sushiswap_router, token, weth, strategy, gov, currencyID)

    tx = strategy.harvest({"from": strategist})

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})
    
