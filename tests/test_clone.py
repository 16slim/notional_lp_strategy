import brownie
from utils import actions, checks, utils
import pytest
from brownie import reverts

# tests harvesting a strategy that returns profits correctly
def test_clone(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, balancer_vault, balancer_note_weth_pool
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)

    # Cloning a clone should not work
    with reverts():
        strategy.cloneStrategy(
            vault,
            strategist,
            strategy.rewards(),
            strategy.keeper(),
            n_proxy_views.address,
            currencyID,
            balancer_vault.address, balancer_note_weth_pool,
            {"from": strategist}
        )
