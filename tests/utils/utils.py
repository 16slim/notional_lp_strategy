from os import curdir
import brownie
from brownie import interface, chain, Contract, accounts


def vault_status(vault):
    print(f"--- Vault {vault.name()} ---")
    print(f"API: {vault.apiVersion()}")
    print(f"TotalAssets: {to_units(vault, vault.totalAssets())}")
    print(f"PricePerShare: {to_units(vault, vault.pricePerShare())}")
    print(f"TotalSupply: {to_units(vault, vault.totalSupply())}")


def strategy_status(vault, strategy):
    status = vault.strategies(strategy).dict()
    print(f"--- Strategy {strategy.name()} ---")
    print(f"Performance fee {status['performanceFee']}")
    print(f"Debt Ratio {status['debtRatio']}")
    print(f"Total Debt {to_units(vault, status['totalDebt'])}")
    print(f"Total Gain {to_units(vault, status['totalGain'])}")
    print(f"Total Loss {to_units(vault, status['totalLoss'])}")


def to_units(token, amount):
    return amount / (10 ** token.decimals())


def from_units(token, amount):
    return amount * (10 ** token.decimals())


# default: 6 hours (sandwich protection)
def sleep(seconds=6 * 60 * 60):
    chain.sleep(seconds)
    chain.mine(1)

def get_min_market_index(strategy, currencyID, n_proxy_views):
    min_time = strategy.getMinTimeToMaturity()
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    for i, am in enumerate(active_markets):
        if am[1] - chain.time() >= min_time:
            return i+1

def million_in_token(token):
    token_prices = {
    "WBTC": 35_000,
    "WETH": 2_000,
    "LINK": 20,
    "YFI": 30_000,
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
    }
    return round(1e6 / token_prices[token.symbol()]) * 10 ** token.decimals()

def get_currency_id(token):
    currency_IDs = {
        "WETH": 1,
        "DAI": 2,  # DAI
        "USDC": 3,  # USDC
        "WBTC": 4
    }
    return currency_IDs[token.symbol()]

def get_token(symbol):
    token_addresses = {
        "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",  # WBTC
        "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
        "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",  # DAI
        "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
    }
    return Contract(token_addresses[symbol])

def get_token_whale(symbol):
    whale_addresses = {
        "WBTC": "0x28c6c06298d514db089934071355e5743bf21d60",
        "WETH": "0x28c6c06298d514db089934071355e5743bf21d60",
        "USDC": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
        "DAI": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    }
    return accounts.at(whale_addresses[symbol], force=True)

def getMarketIndexForMaturity(markets, maturity):
    for (i,m) in enumerate(markets):
        if m[1] == maturity:
            return i
    return -1

def ntoken_net_state(n_proxy_implementation, currencyID):
    nToken = n_proxy_implementation.nTokenAddress(currencyID)
    (liq, fCash) = n_proxy_implementation.getNTokenPortfolio(nToken)
    markets = n_proxy_implementation.getActiveMarkets(currencyID)

    net_fcash = 0
    for (i, fc) in enumerate(fCash):
        m_index = getMarketIndexForMaturity(markets, fc[1])
        if m_index >= 0:
            net_fcash += (fc[3] + int(markets[m_index][2] / markets[m_index][4] * liq[i][3]))
        
    if net_fcash > 0:
        return "lender"
    elif net_fcash < 0:
        return "borrower"
    else:
        return "neutral"

def amount_in_NOTE(amount):
    return round(amount / 1.3) * 10 ** 8
