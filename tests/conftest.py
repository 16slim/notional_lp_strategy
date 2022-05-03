import pytest
from brownie import config
from brownie import Contract, interface
from utils import utils

# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def strat_ms(accounts):
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)

@pytest.fixture
def notional_proxy():
    yield "0x1344A36A1B56144C3Bc62E7757377D288fDE0369"


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]

@pytest.fixture
def n_proxy():
    yield Contract.from_explorer("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")

@pytest.fixture
def n_proxy_views(n_proxy):
    views_contract = Contract(n_proxy.VIEWS())
    yield Contract.from_abi("VIEWS", n_proxy.address, views_contract.abi)

@pytest.fixture
def n_proxy_batch(n_proxy):
    batch_contract = Contract(n_proxy.BATCH_ACTION())
    yield Contract.from_abi("BATCH", n_proxy.address, batch_contract.abi)

@pytest.fixture
def n_proxy_account(n_proxy):
    account_contract = Contract(n_proxy.ACCOUNT_ACTION())
    yield Contract.from_abi("ACCOUNT", n_proxy.address, account_contract.abi)

@pytest.fixture
def n_proxy_implementation(n_proxy):
    yield interface.NotionalProxy(n_proxy.address)

@pytest.fixture
def note_token(n_proxy_implementation):
    yield Contract(n_proxy_implementation.getNoteToken())

@pytest.fixture
def note_whale():
    yield "0x22341fB5D92D3d801144aA5A925F401A91418A05"

@pytest.fixture
def balancer_vault():
    yield Contract("0xBA12222222228d8Ba445958a75a0704d566BF2C8")

@pytest.fixture
def balancer_note_weth_pool():
    yield "0x5f7fa48d765053f8dd85e052843e12d23e3d7bc50002000000000000000000c0"

@pytest.fixture
def trade_factory():
    yield Contract("0x99d8679bE15011dEAD893EB4F5df474a4e6a8b29")

@pytest.fixture
def ymechs_safe():
    yield Contract("0x2C01B4AD51a67E2d8F02208F54dF9aC4c0B778B6")

@pytest.fixture
def sushiswap_router():
    yield Contract("0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F")

@pytest.fixture()
def multicall_swapper(interface):
    yield interface.MultiCallOptimizedSwapper(
        "0xB2F65F254Ab636C96fb785cc9B4485cbeD39CDAA"
    )


token_addresses = {
    "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",  # WBTC
    "YFI": "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e",  # YFI
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",  # LINK
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",  # USDT
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",  # DAI
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
}

# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        # 'WBTC', # WBTC
        # "WETH",  # WETH
        'DAI', # DAI
        # 'USDC', # USDC
    ],
    scope="session",
    autouse=True,
)
def token(request):
    yield Contract(token_addresses[request.param])

currency_IDs = {
    "WETH": 1,
    "DAI": 2,  # DAI
    "USDC": 3,  # USDC
    "WBTC": 4
}

thresholds = {
    "WETH": (1000e18, -500e8),
    "DAI": (20e24, -20e14),
    "WBTC": (50e8, -50e8),
    "USDC": (20e12, -20e14),
}

@pytest.fixture
def balance_threshold(token):
    yield thresholds[token.symbol()]

@pytest.fixture
def currencyID(token):
    yield currency_IDs[token.symbol()]


whale_addresses = {
    "WBTC": "0x28c6c06298d514db089934071355e5743bf21d60",
    "WETH": "0x28c6c06298d514db089934071355e5743bf21d60",
    "USDC": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "DAI": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
}

@pytest.fixture
def token_whales():
    yield whale_addresses

@pytest.fixture(scope="session", autouse=True)
def token_whale(token):
    yield whale_addresses[token.symbol()]


token_prices = {
    "WBTC": 35_000,
    "WETH": 3_000,
    "LINK": 20,
    "YFI": 30_000,
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
}


@pytest.fixture(autouse=True)
def amount(token, token_whale, user):
    # this will get the number of tokens (around $100k worth of token)
    amillion = round(100_000 / token_prices[token.symbol()])
    amount = amillion * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate a whale address
    if amount > token.balanceOf(token_whale):
        amount = token.balanceOf(token_whale)
    token.transfer(user, amount, {"from": token_whale})
    yield amount

@pytest.fixture(autouse=True)
def million_in_token(token):
    yield round(1e6 / token_prices[token.symbol()]) * 10 ** token.decimals()

@pytest.fixture(autouse=True)
def million_fcash_notation(million_in_token, token):
    yield million_in_token / (10 ** token.decimals()) * (10 ** 8)

@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amount(user, weth):
    weth_amount = 10 ** weth.decimals()
    user.transfer(weth, weth_amount)
    yield weth_amount


@pytest.fixture(scope="function", autouse=True)
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management, {"from": guardian})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    vault.setPerformanceFee(0, {"from": gov})
    yield vault


@pytest.fixture(scope="session")
def registry():
    yield Contract("0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804")


@pytest.fixture(scope="session")
def live_vault(registry, token):
    yield registry.latestVault(token)


@pytest.fixture
def strategy(strategist, keeper, vault, rewards, Strategy, gov, \
    notional_proxy, currencyID, balancer_vault, balancer_note_weth_pool, 
    NotionalLpLib, trade_factory, ymechs_safe):
    notional_lp_lib = strategist.deploy(NotionalLpLib)
    strategy = strategist.deploy(Strategy, vault, notional_proxy, \
        currencyID, balancer_vault.address, balancer_note_weth_pool)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    cloned_strategy = strategy.cloneStrategy(
        vault,
        strategist,
        rewards,
        keeper,
        notional_proxy,
        currencyID,
        balancer_vault.address, balancer_note_weth_pool,
        {"from": strategist}
    ).return_value
    cloned_strategy = Strategy.at(cloned_strategy)
    vault.revokeStrategy(strategy)
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    cloned_strategy.setShouldClaimRewards(True, {"from": gov})
    cloned_strategy.setDoHealthCheck(False, {"from": gov})

    utils.prepare_trade_factory(
        cloned_strategy,
        trade_factory,
        ymechs_safe,
        gov
        )

    yield cloned_strategy

@pytest.fixture(autouse=True)
def withdraw_no_losses(vault, token, amount, user):
    yield
    if vault.totalSupply() != 0:
        vault.withdraw({"from": user})
        # check that we dont have previously realised losses
        # NOTE: this assumes deposit is `amount`
        assert token.balanceOf(user) >= amount
        return


@pytest.fixture(scope="session", autouse=True)
def RELATIVE_APPROX():
    yield 5e-3

@pytest.fixture(scope="session", autouse=True)
def MAX_BPS():
    yield 1e4

