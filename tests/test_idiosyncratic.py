from datetime import timedelta
from utils import actions, checks, utils
import pytest

# tests operating a strategy before, within and after the 24h idiosyncratic period
def test_avoid_idiosyncratic_period(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    # State of the strategy, nTokens minted
    account = n_proxy_views.getAccount(strategy)
    nTokens_strat = account["accountBalances"][0][2]

    # Get the current active markets
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    first_market = active_markets[0][1]

    # Move the chain until just before the first maturity
    chain.mine(1, timestamp = first_market - 100)

    # Normal situation, estimated assets includes principal position, no idiosyncratic positions
    rewards_value = strategy.getRewardsValue()
    assets = strategy.estimatedTotalAssets()
    check_idiosyncratic = strategy.checkIdiosyncratic()

    assert assets > rewards_value
    assert check_idiosyncratic == False

    # Moce the chain to right after first maturity and initialize markets
    chain.mine(1, timestamp = first_market + 1)
    n_proxy_implementation.initializeMarkets(currencyID, False, {"from":accounts[0]})

    # APplicable for 3-maturities strats (DAI / USDC)
    if strategy.checkIdiosyncratic():
        # Idiosyncratic situation, no principal position, only rewards
        rewards_value = strategy.getRewardsValue()
        assets = strategy.estimatedTotalAssets()
        check_idiosyncratic = strategy.checkIdiosyncratic()

        assert assets == rewards_value
        assert check_idiosyncratic == True

        # Balance actions to redeem ntokens are protected as they would revert, nothing happens
        strategy.redeemNTokenAmount(nTokens_strat, {"from":gov})
        account = n_proxy_views.getAccount(strategy)
        assert account["accountBalances"][0][2] == nTokens_strat

        # Harvesting doesn't do anything (only swapping rewards if we let it)
        vault.updateStrategyDebtRatio(strategy, 0, {"from": vault.governance()})
        strategy.setToggleClaimRewards(False, {"from": vault.governance()})
        tx = strategy.harvest({"from": gov})
        assert tx.events["Harvested"]["profit"] == 0
        assert tx.events["Harvested"]["loss"] == 0
        assert tx.events["Harvested"]["debtPayment"] == 0

        # strat position remains unchanged
        account = n_proxy_views.getAccount(strategy)
        assert account["accountBalances"][0][2] == nTokens_strat

        # Get a whale to buy the nToken residuals
        actions.buy_residuals(n_proxy_batch, n_proxy_implementation, currencyID, million_in_token, token, token_whale)

    #  Idiosyncratic situation resolved
    assert strategy.checkIdiosyncratic() == False

    #  Strategy can now be harvested noramally
    vault.updateStrategyDebtRatio(strategy, 0, {"from": vault.governance()})
    strategy.setToggleClaimRewards(True, {"from": vault.governance()})
    tx = strategy.harvest({"from": gov})
    assert tx.events["Harvested"]["profit"] > 0
    assert tx.events["Harvested"]["loss"] == 0
    assert tx.events["Harvested"]["debtPayment"] > 0

    chain.mine(1, timedelta = 6 * 3600)

# tests operating a strategy within the 24h idiosyncratic period
def test_exit_during_idiosyncratic_period(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token, note_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    # State of the strategy, nTokens minted
    account = n_proxy_views.getAccount(strategy)
    nTokens_strat = account["accountBalances"][0][2]

    # Get the current active markets
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    first_market = active_markets[0][1]
    
    # Move the chain until just before the first maturity
    chain.mine(1, timestamp = first_market + 1 )
    n_proxy_implementation.initializeMarkets(currencyID, False, {"from":accounts[0]})

    assert strategy.checkIdiosyncratic() == True

    # Exit the startegy the wrong way
    tx = strategy.redeemIdiosyncratic(
        nTokens_strat, 
        True, 
        True, 
        {"from":gov})
    
    account = n_proxy_views.getAccount(strategy)
    
    amount_withdraw = account["accountBalances"][0][1]

    assert amount_withdraw > 0
    assert amount_withdraw == tx.return_value[0]
    assert account["accountBalances"][0][2] == 0

    strategy.withdrawFromNotional(amount_withdraw, True, {"from": gov})

    account = n_proxy_views.getAccount(strategy)
    assert account["accountBalances"][0][1] == 0
    assert account["accountBalances"][0][2] == 0

    assert token.balanceOf(strategy) > amount

    chain.mine(1, timedelta = 6 * 3600)
