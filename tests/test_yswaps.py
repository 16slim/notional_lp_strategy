from datetime import timedelta
from utils import actions, checks, utils
import pytest
from eth_abi.packed import encode_abi_packed

# tests harvesting a strategy that returns profits correctly
def test_yswap_profitable_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_implementation, gov, note_token, note_whale, sushiswap_router, 
    multicall_swapper, trade_factory, ymechs_safe, balancer_vault, 
    balancer_note_weth_pool, weth
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    print(f"Strategy total assets: {strategy.estimatedTotalAssets()}")
    actions.airdrop_amount_rewards(strategy, 1000, note_token, note_whale)
    # Close the entire position
    strategy.redeemNTokenAmount(n_proxy_implementation.getAccount(strategy)[1][0][2], {"from": gov})
    print(f"Strategy total assets: {strategy.estimatedTotalAssets()}")
    strategy.swapToWETHManually({"from": gov})
    
    if token != weth:

        token_in = weth
        token_out = token

        print(f"Executing trade...")
        receiver = strategy.address
        amount_in = token_in.balanceOf(strategy)

        asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]

        # always start with optimizations. 5 is CallOnlyNoValue
        optimizations = [["uint8"], [5]]
        a = optimizations[0]
        b = optimizations[1]

        calldata = token_in.approve.encode_input(sushiswap_router, amount_in)
        t = utils.create_tx(token_in, calldata)
        a = a + t[0]
        b = b + t[1]

        path = [token_in.address, token_out.address]
        calldata = sushiswap_router.swapExactTokensForTokens.encode_input(
            amount_in, 0, path, multicall_swapper, 2 ** 256 - 1
        )
        t = utils.create_tx(sushiswap_router, calldata)
        a = a + t[0]
        b = b + t[1]
        
        expectedOut = sushiswap_router.getAmountsOut(amount_in, path)[1]

        calldata = token_out.transfer.encode_input(receiver, expectedOut)
        t = utils.create_tx(token_out, calldata)
        a = a + t[0]
        b = b + t[1]

        transaction = encode_abi_packed(a, b)

        # min out must be at least 1 to ensure that the tx works correctly
        trade_factory.execute['tuple,address,bytes'](asyncTradeExecutionDetails,
            multicall_swapper.address, transaction, {"from": ymechs_safe}
        )
        print(token_out.balanceOf(strategy))
    print(f"Strategy total assets: {strategy.estimatedTotalAssets()}")
    
    vault.updateStrategyDebtRatio(strategy, 0, {'from': gov})
    tx = strategy.harvest({'from': strategist})

    assert token.balanceOf(vault) > amount
    assert strategy.estimatedTotalAssets() == 0

def test_remove_trade_factory(
    strategy, gov, trade_factory, note_token
):
    assert strategy.getTradeFactory() == trade_factory.address
    assert note_token.allowance(strategy.address, trade_factory.address) > 0

    strategy.removeTradeFactoryPermissions({'from': gov})

    assert strategy.getTradeFactory() != trade_factory.address
    assert note_token.allowance(strategy.address, trade_factory.address) == 0
