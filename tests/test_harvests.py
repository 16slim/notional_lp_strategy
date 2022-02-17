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
    print("Vault assets 2: ", vault.totalAssets())
    assert balance >= amount
    assert vault.pricePerShare() > before_pps


# tests harvesting a strategy that reports losses
def test_lossy_harvest(
    chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID,
    n_proxy_implementation, gov, million_fcash_notation
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    initial_value = strategy.estimatedTotalAssets()
    print("Initial position value: ", initial_value)
    amount_invested = vault.strategies(strategy)["totalDebt"]
    
    if currencyID == 2:
        symbol_collateral = "USDC"
    else:
        symbol_collateral = "DAI"
    
    # Create impermanent loss by borrowing 10 million
    i = 1
    while (i <= 10):
        print("Whale borrowing million ", i)
        actions.borrow_1m_whales(n_proxy_views, currencyID, 
            utils.get_token(symbol_collateral), n_proxy_batch, 
            utils.get_token_whale(symbol_collateral), million_fcash_notation
            )
        i+=1
    
    final_value = strategy.estimatedTotalAssets()
    print("Final position value: ", final_value)

    loss = amount_invested - final_value
    
    assert loss > 0
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setToggleLiquidatePosition(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_loss(tx, loss, RELATIVE_APPROX)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})


# tests harvesting a strategy twice, once with loss and another with profit
# it checks that even with previous profit and losses, accounting works as expected
def test_choppy_harvest(
    chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID,
    n_proxy_implementation, gov, million_fcash_notation
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    initial_value = strategy.estimatedTotalAssets()
    print("Initial position value: ", initial_value)
    amount_invested = vault.strategies(strategy)["totalDebt"]
    
    if currencyID == 2:
        symbol_collateral = "USDC"
    else:
        symbol_collateral = "DAI"
    
    # Create impermanent loss by borrowing 10 million
    i = 1
    while (i <= 10):
        print("Whale borrowing million ", i)
        actions.borrow_1m_whales(n_proxy_views, currencyID, 
            utils.get_token(symbol_collateral), n_proxy_batch, 
            utils.get_token_whale(symbol_collateral), million_fcash_notation
            )
        i+=1
    
    final_value = strategy.estimatedTotalAssets()
    print("Intermediate position value: ", final_value)
    want_balance = token.balanceOf(strategy)
    vault.updateStrategyDebtRatio(strategy, 5000, {"from":vault.governance()})
    
    loss_amount = (amount_invested - final_value) * \
        (vault.debtOutstanding({"from":strategy}) - want_balance) \
         / (vault.strategies(strategy)["totalDebt"] - want_balance)
    assert loss_amount > 0
    
    strategy.setToggleLiquidatePosition(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_loss(tx, loss_amount, RELATIVE_APPROX)

    actions.wait_n_days(14)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    final_value = strategy.estimatedTotalAssets()
    print("Final position value: ", final_value)

    remaining_debt = vault.strategies(strategy)["totalDebt"]
    profit = final_value - remaining_debt

    assert profit > 0

    strategy.setToggleLiquidatePosition(True, {"from":gov})
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_profit(tx, profit, RELATIVE_APPROX)

    chain.mine(1, timedelta=6 * 3_600)

    assert pytest.approx(vault.strategies(strategy)["totalLoss"], rel=RELATIVE_APPROX) == loss_amount
    assert pytest.approx(vault.strategies(strategy)["totalGain"], rel=RELATIVE_APPROX) == profit

    vault.withdraw({"from": user})

# def test_maturity_harvest(
#     chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
#     n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
#     balance_threshold, million_in_token
# ):
#     # Deposit to the vault
#     actions.user_deposit(user, vault, token, amount)
#     min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
#     amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
#         strategy.currencyID(),
#         - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
#         min_market_index,
#         chain.time()+5
#         )
    
#     # Harvest 1: Send funds through the strategy
#     chain.sleep(1)
    
#     strategy.harvest({"from": strategist})

#     account = n_proxy_views.getAccount(strategy)
#     next_settlement = account[0][0]

#     assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

#     position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
#         strategy.currencyID(),
#         - amount_fcash,
#         min_market_index,
#         chain.time()+1
#         )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
#     total_assets = strategy.estimatedTotalAssets()
    
#     assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
#     # Add some code before harvest #2 to simulate earning yield
#     actions.wait_until_settlement(next_settlement)
#     actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
#         account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
#     checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
#     chain.sleep(next_settlement - chain.time() + 1)
#     chain.mine(1)
#     checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
#     totalAssets = strategy.estimatedTotalAssets()
#     position_cash = account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

#     assert pytest.approx(position_cash+token.balanceOf(strategy), rel=RELATIVE_APPROX) == totalAssets
#     profit_amount = totalAssets - amount
#     assert profit_amount > 0
    
#     vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
#     tx = strategy.harvest()
#     assert tx.events["Harvested"]["profit"] >= profit_amount

#     chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
#     chain.mine(1)
#     assert vault.strategies(strategy)["totalLoss"] == 0
#     assert vault.strategies(strategy)["totalGain"] >= profit_amount
    
#     vault.withdraw({"from": user})

    