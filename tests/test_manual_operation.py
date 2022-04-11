from datetime import timedelta
from utils import actions, checks, utils
import pytest

# tests migrating a strategy manually
def test_force_migration(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token, notional_proxy, Strategy, balancer_note_weth_pool
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    amount_invested = vault.strategies(strategy)["totalDebt"]

    account = n_proxy_views.getAccount(strategy)
    amount_tokens = account[1][0][2]

    # new strategy
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, 
        strategy.getBalancerVault(), balancer_note_weth_pool)

    # migrate nTokens
    strategy.manuallyTransferNTokens(new_strategy, amount_tokens, {"from": gov})

    # claim rewards manually
    strategy.setToggleClaimRewards(True, {"from":gov})
    strategy.manuallyClaimAndSellRewards({"from":gov})
    # no more rewards in the strat
    assert strategy.getRewardsValue() == 0

    # previous strategy has no tokens
    assert n_proxy_views.getAccount(strategy)[1][0][2] == 0
    assert n_proxy_views.getAccount(new_strategy)[1][0][2] == amount_tokens
    # exchanged rewards are pending to be swept in the previous strategy
    assert token.balanceOf(strategy) > 0

    # prevent the strategy form executing any code with the ntoken
    strategy.setForceMigration(True, {"from": gov})
    strategy.setToggleClaimRewards(False, {"from":gov})
    # migrate all tokens to the new strat
    vault.migrateStrategy(strategy, new_strategy, {"from":gov})

    # previous strat is completely empty
    assert strategy.estimatedTotalAssets() == 0
    assert token.balanceOf(new_strategy) > 0

    # give it all back to the vault
    vault.updateStrategyDebtRatio(new_strategy, 0, {"from":gov})
    new_strategy.setToggleLiquidatePosition(True, {"from":gov})
    new_strategy.harvest({"from":gov})

    assert new_strategy.estimatedTotalAssets() == 0

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    
    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})

# tests liquidating a strategy manually
def test_force_liquidation(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token, notional_proxy, Strategy, balancer_note_weth_pool
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    amount_invested = vault.strategies(strategy)["totalDebt"]

    account = n_proxy_views.getAccount(strategy)
    amount_tokens = account[1][0][2]

    # Close half the tokens
    tokens_to_close = int(amount_tokens / 2)
    strategy.redeemNTokenAmount(tokens_to_close, {"from": gov})

    assert amount_tokens - n_proxy_views.getAccount(strategy)[1][0][2] == tokens_to_close

    # Close the entire position
    strategy.redeemNTokenAmount(n_proxy_views.getAccount(strategy)[1][0][2], {"from": gov})
    
    # Swap all rewards
    strategy.setToggleClaimRewards(True, {"from":gov})
    strategy.manuallyClaimAndSellRewards({"from":gov})

    assert n_proxy_views.getAccount(strategy)[1][0][2] == 0
    assert strategy.getRewardsValue() == 0

    # give it all back to the vault
    vault.updateStrategyDebtRatio(strategy, 0, {"from":gov})
    strategy.setToggleLiquidatePosition(True, {"from":gov})

    strategy.harvest({"from":gov})

    assert strategy.estimatedTotalAssets() == 0

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    
    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})

# tests liquidating a strategy in emergency situation
def test_emergency_exit(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token, notional_proxy, Strategy, balancer_note_weth_pool
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    amount_invested = vault.strategies(strategy)["totalDebt"]

    account = n_proxy_views.getAccount(strategy)
    amount_tokens = account[1][0][2]

    strategy.setEmergencyExit({"from":gov})
    strategy.setToggleLiquidatePosition(True, {"from":gov})
    strategy.setToggleClaimRewards(True, {"from":gov})

    tx = strategy.harvest({"from":gov})

    assert strategy.estimatedTotalAssets() == 0

    chain.mine(1, timedelta = 6 * 3600)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})