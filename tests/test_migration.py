
import pytest
from utils import actions, utils


def test_migration(
    chain,
    token,
    vault,
    strategy,
    amount,
    Strategy,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    notional_proxy, 
    currencyID,
    n_proxy_views,
    balancer_note_weth_pool,
    note_token,
    note_whale
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    # assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    first_assets = strategy.estimatedTotalAssets()
    # migrate to a new strategy both pricipal and rewards
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, strategy.getBalancerVault(), balancer_note_weth_pool)
    
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    mid_assets = new_strategy.estimatedTotalAssets()
    assert mid_assets >= first_assets
    assert strategy.estimatedTotalAssets() == 0

    chain.mine(1, timedelta = 2 * 86400)

    # test that after some time it's the new strat that earns rewards
    assert new_strategy.estimatedTotalAssets() >= mid_assets
    assert strategy.estimatedTotalAssets() == 0

    # Migrate once again but only principal
    new_new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, strategy.getBalancerVault(), balancer_note_weth_pool)
    new_strategy.setToggleClaimRewards(False, {"from":gov})

    prev_rewards = new_strategy._getRewardsValue()

    vault.migrateStrategy(new_strategy, new_new_strategy, {"from": gov})

    # rewards should have stayed at prev. strat
    assert pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == prev_rewards
    assert strategy.estimatedTotalAssets() == 0
    #  new strat only has vault debt
    assert pytest.approx(new_new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == vault.strategies(new_new_strategy)["totalDebt"]
    # create a profitable harvest
    actions.airdrop_amount_rewards(new_new_strategy, 500, note_token, note_whale)
    new_new_strategy.setToggleLiquidatePosition(True, {"from":gov})
    vault.updateStrategyDebtRatio(new_new_strategy, 0, {"from": gov})
    # check that harvest work as expected
    tx = new_new_strategy.harvest({"from": gov})

    assert tx.events["Harvested"]["profit"] > 0
    assert token.balanceOf(vault) > amount

