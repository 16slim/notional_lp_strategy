from datetime import timedelta
from utils import actions, checks, utils
import pytest

# tests harvesting a strategy that returns profits correctly
def test_profitable_harvest(
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

    assert amount_tokens > 0
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == vault.strategies(strategy)["totalDebt"]

    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    first_settlement = active_markets[0][1]

    chain.mine(1, timedelta=int((first_settlement-chain.time()) / 3))
    assert strategy.estimatedTotalAssets() > amount_invested
    tx = strategy.harvest({"from": strategist})
    
    assert tx.events["Harvested"]["profit"] > 0
    assert tx.events["Harvested"]["loss"] == 0
    assert tx.events["Harvested"]["debtPayment"] == 0

    chain.mine(1, timedelta=int((first_settlement-chain.time()) / 3))

    tx = strategy.harvest({"from": strategist})
    
    assert tx.events["Harvested"]["profit"] > 0
    assert tx.events["Harvested"]["loss"] == 0
    assert tx.events["Harvested"]["debtPayment"] == 0

    chain.mine(1, timestamp=first_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    before_pps = vault.pricePerShare()
    print("Vault assets 1: ", vault.totalAssets())
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from": vault.governance()})
    strategy.setToggleLiquidatePosition(True, {"from": vault.governance()})
    
    tx2 = strategy.harvest()

    account = n_proxy_views.getAccount(strategy)
    
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    balance = token.balanceOf(vault.address)  # Profits go to vault
    print("ETH Balance is ", vault.balance())
    print("Vault assets 2: ", vault.totalAssets())
    assert balance >= amount
    assert vault.pricePerShare() > before_pps


# # tests harvesting a strategy that reports losses
def test_lossy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, balance_threshold, n_proxy_implementation, gov
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold, min_market_index)

    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()+5
        )

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    
    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    actions.wait_half_until_settlement(next_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID, min_market_index)
    print("Amount: ", amount)
    position_cash = strategy.estimatedTotalAssets()
    loss_amount = amount - position_cash
    assert loss_amount > 0
    print("TA: ", position_cash)
    # Harvest 2: Realize loss
    chain.sleep(1)

    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setToggleRealizeLosses(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_loss(tx, loss_amount, RELATIVE_APPROX)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})
    assert pytest.approx(token.balanceOf(user) + loss_amount, rel=RELATIVE_APPROX) == amount


# tests harvesting a strategy twice, once with loss and another with profit
# it checks that even with previous profit and losses, accounting works as expected
def test_choppy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold, gov, million_in_token
):
    # Deposit to the vault
    # assert token.balanceOf(user) == amount + 5e20 - 3
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)

    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold, min_market_index)

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    actions.wait_half_until_settlement(next_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID, min_market_index)

    print("TA: ", strategy.estimatedTotalAssets())

    # Harvest 2: Realize loss
    chain.sleep(1)
    position_cash = strategy.estimatedTotalAssets()
    loss_amount = (amount - position_cash) / 2
    assert loss_amount > 0
    vault.updateStrategyDebtRatio(strategy, 5_000, {"from":vault.governance()})
    strategy.setToggleRealizeLosses(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})

    # Harvest 3: Realize profit on the rest of the position
    print("TA 1: ", strategy.estimatedTotalAssets())
    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user,
        account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    chain.sleep(next_settlement - chain.time() - 100)
    chain.mine(1)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    print("TA 2: ", strategy.estimatedTotalAssets())
    position_cash = strategy.estimatedTotalAssets()
    profit_amount = position_cash - vault.totalDebt()
    assert profit_amount > 0
    
    realized_profit = 0
    tx = strategy.harvest({"from": strategist})
    
    checks.check_harvest_profit(tx, realized_profit, RELATIVE_APPROX)

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert pytest.approx(vault.strategies(strategy)["totalLoss"], rel=RELATIVE_APPROX) == loss_amount
    assert pytest.approx(vault.strategies(strategy)["totalGain"], rel=RELATIVE_APPROX) == realized_profit

    vault.withdraw({"from": user})

def test_maturity_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold, million_in_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()+5
        )
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        min_market_index,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    total_assets = strategy.estimatedTotalAssets()
    
    assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
    # Add some code before harvest #2 to simulate earning yield
    actions.wait_until_settlement(next_settlement)
    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
        account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    chain.sleep(next_settlement - chain.time() + 1)
    chain.mine(1)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    totalAssets = strategy.estimatedTotalAssets()
    position_cash = account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

    assert pytest.approx(position_cash+token.balanceOf(strategy), rel=RELATIVE_APPROX) == totalAssets
    profit_amount = totalAssets - amount
    assert profit_amount > 0
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    tx = strategy.harvest()
    assert tx.events["Harvested"]["profit"] >= profit_amount

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert vault.strategies(strategy)["totalLoss"] == 0
    assert vault.strategies(strategy)["totalGain"] >= profit_amount
    
    vault.withdraw({"from": user})

    