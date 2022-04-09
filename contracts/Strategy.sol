// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
import "../interfaces/notional/nTokenERC20.sol";
// 2) Transact between WETH (Vault) and ETH (Notional)
import "../interfaces/IWETH.sol";
// 3) Swap and quote rewards to any want
import "../interfaces/balancer/BalancerV2.sol";
import "../interfaces/sushi/ISushiRouter.sol";

// 4) Views not fitting in the contract due to bytecode
import "../libraries/NotionalLpLib.sol";

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

// Import the necessary structs to send/ receive data from Notional
import {
    BalanceActionWithTrades,
    AccountContext,
    PortfolioAsset,
    AssetRateParameters,
    Token,
    ETHRate
} from "../interfaces/notional/Types.sol";

/*
     * @notice
     *  Yearn Strategy allocating vault's funds to an LP position funding Notional's fixed rate lend and borrow markets
*/
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // NotionalContract: proxy that points to a router with different implementations depending on function 
    NotionalProxy public nProxy;
    // NOTE token for rewards
    IERC20 private noteToken;
    // Address of the nToken we interact with
    nTokenERC20 public nToken;
    // Balancer pool contrct to swap NOTE for WETH
    IBalancerPool private balancerPool;
    // Balancer vault used to swap rewards
    IBalancerVault private balancerVault;
    // Id of the balancer NOTE/WETH pool to use
    bytes32 private poolId;
    // ID of the asset being lent in Notional
    uint16 private currencyID;
    // minimum amount of want to act on
    uint256 private minAmountWant;
    // Initialize Sushi router interface to swap WETH for want
    ISushiRouter public constant router = ISushiRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    // Initialize WETH interface
    IWETH public constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // To control when positions should be liquidated 
    bool internal toggleLiquidatePosition;
    // To control when rewards are claimed 
    bool internal toggleClaimRewards;
    
    uint256 internal constant MAX_UINT = type(uint256).max;

    // EVENTS
    event Cloned(address indexed clone);

    /*
     * @notice constructor for the contract, called at deployment, calls the initializer function used for 
     * cloning strategies
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     * @param _balancerVault Address of the balancer vault to use to exchange NOTEs to WETH
     * @param _poolId 32 bytes identifier of the NOTE/WETH balancer pool to use
     */
    constructor(
        address _vault,
        NotionalProxy _nProxy,
        uint16 _currencyID,
        address _balancerVault,
        bytes32 _poolId 
    ) public BaseStrategy (_vault) {
        _initializeNotionalStrategy(_nProxy, _currencyID, _balancerVault, _poolId);
    }

    /*
     * @notice Initializer function to initialize both the BaseSrategy and the Notional strategy 
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _strategist Strategist managing the strategy
     * @param _rewards Rewards address
     * @param _keeper Keeper address
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     * @param _balancerVault Address of the balancer vault to use to exchange NOTEs to WETH
     * @param _poolId 32 bytes identifier of the NOTE/WETH balancer pool to use
     */
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        NotionalProxy _nProxy,
        uint16 _currencyID,
        address _balancerVault,
        bytes32 _poolId
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeNotionalStrategy(_nProxy, _currencyID, _balancerVault, _poolId);
    }

    /*
     * @notice Internal initializer for the Notional Strategy contract
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     * @param _balancerVault Address of the balancer vault to use to exchange NOTEs to WETH
     * @param _poolId 32 bytes identifier of the NOTE/WETH balancer pool to use
     */
    function _initializeNotionalStrategy (
        NotionalProxy _nProxy,
        uint16 _currencyID,
        address _balancerVault,
        bytes32 _poolId
    ) internal {
        currencyID = _currencyID;
        nProxy = _nProxy;

        (Token memory assetToken, Token memory underlying) = _nProxy.getCurrency(_currencyID);
        
        // By default do not realize losses
        toggleLiquidatePosition = false;
        // By default claim rewrds
        toggleClaimRewards = true;

        // Initialize NOTE token and nToken
        noteToken = IERC20(nProxy.getNoteToken());
        nToken = nTokenERC20(nProxy.nTokenAddress(_currencyID));

        // Check whether the currency is set up right
        if (_currencyID == 1) {
            require(address(0) == underlying.tokenAddress); 
        } else {
            require(address(want) == underlying.tokenAddress);
        }

        // Balancer setup
        balancerVault = IBalancerVault(_balancerVault);
        poolId = _poolId;
        (address balancerPoolAddress,) = balancerVault.getPool(_poolId);
        balancerPool = IBalancerPool(balancerPoolAddress);

        // Approve movements from balancerVault
        want.approve(address(balancerVault), MAX_UINT);
        noteToken.approve(address(balancerVault), MAX_UINT);
    }

    /*
     * @notice Cloning function to re-use the strategy code and deploy the same strategy with other key parameters,
     * notably currencyID or yVault
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _strategist Strategist managing the strategy
     * @param _rewards Rewards address
     * @param _keeper Keeper address
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     * @param _balancerVault Address of the balancer vault to use to exchange NOTEs to WETH
     * @param _poolId 32 bytes identifier of the NOTE/WETH balancer pool to use
     */
    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        NotionalProxy _nProxy,
        uint16 _currencyID,
        address _balancerVault,
        bytes32 _poolId
    ) external returns (address payable newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, 
            _strategist, _rewards, _keeper, _nProxy, _currencyID,
            _balancerVault, _poolId
            );

        emit Cloned(newStrategy);
    }

    // For ETH based strategies
    receive() external payable {}

    /*
     * @notice
     *  Sweep function only callable by governance to be able to sweep any ETH assigned to the strategy's balance
     */
    function sendETHToGovernance() external onlyGovernance {
        (bool sent, bytes memory data) = governance().call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }

    /*
     * @notice
     *  Getter function for the name of the strategy
     * @return string, the name of the strategy
     */
    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyNotionalLp";
    }

    /*
     * @notice
     *  Getter function for the toggle defining whether to realize losses or not
     * @return bool, current toggleRealizeLosses state variable
     */
    function getToggleLiquidatePosition() external view returns(bool) {
        return toggleLiquidatePosition;
    }

    /*
     * @notice
     *  Getter function for the current minimum amount of want required to enter a position
     * @return uint256, current minAmountWant state variable
     */
    function getMinAmountWant() external view returns(uint256) {
        return minAmountWant;
    }

    /*
     * @notice
     *  Setter function for the toggle defining whether to liquidate positions or not
     * only accessible to vault managers
     * @param _newToggle, new booelan value for the toggle
     */
    function setToggleLiquidatePosition(bool _newToggle) external onlyVaultManagers {
        toggleLiquidatePosition = _newToggle;
    }
    
    /*
     * @notice
     *  Setter function for the toggle defining whether to claim rewards or not
     * only accessible to vault managers
     * @param _newToggle, new booelan value for the toggle
     */
    function setToggleClaimRewards(bool _newToggle) external onlyVaultManagers {
        toggleClaimRewards = _newToggle;
    }

    /*
     * @notice
     *  Setter function for the minimum amount of want to invest, accesible only to vault managers
     * @param _newMinAmount, new minimum amount of want to invest
     */
    function setMinAmountWant(uint256 _newMinAmount) external onlyVaultManagers {
        minAmountWant = _newMinAmount;
    }

    /*
     * @notice
     *  Getter function for the current balancer vault used to swap NOTE rewards
     * @return address, current balancerVault state variable
     */
    function getBalancerVault() external view returns (address) {
        return address(balancerVault);
    }

    /*
     * @notice
     *  Getter function for the current balancer NOTE/WETH pool is used to swap NOTE rewards
     * @return address, current balancerPool state variable
     */
    function getBalancerPool() external view returns (address) {
        return address(balancerPool);
    }

    /*
     * @notice
     *  Getter function for the current currency ID of the strategy, following Notional's convention:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     * @return uint16, current currencyID state variable
     */
    function getCurrencyID() external view returns (uint16) {
        return currencyID;
    }

    /*
     * @notice
     *  Getter function for the current value of NOTE rewards earned and pending of to be claimed, in want tokens exchanged in Sushi
     * @return uint256, current value of strategy's rewards
     */
    function getRewardsValue() external view returns (uint256) {
        return _getRewardsValue();
    }

    /*
     * @notice
     *  Setter function for the balancer vault ot use
     * @param _newVault, new address of the balancer vault to use
     */
    function setBalancerVault(address _newVault) external onlyVaultManagers {
        balancerVault = IBalancerVault(_newVault);
    }

    /*
     * @notice
     *  Setter function for the balancer NOTE/WETH pool id to use
     * @param _newPoolId, new pool id to use
     */
    function setBalancerPool(bytes32 _newPoolId) external onlyVaultManagers {
        (address balancerPoolAddress,) = balancerVault.getPool(_newPoolId);
        balancerPool = IBalancerPool(balancerPoolAddress);
    }

    /*
     * @notice
     *  Function estimating the total assets under management of the strategy, whether realized (token balances
     * of the contract) or unrealized (as Notional LP positions and/or NOTE rewards)
     * @return uint256, value containing the total AUM valuation
     */
    function estimatedTotalAssets() public view override returns (uint256) {
        // To estimate the assets under management of the strategy we add the want balance already 
        // in the contract and the current valuation of share of nTokens held by the strategy and the 
        // tokens we would get by exchanging the accumulated rewards to want tokens

        return balanceOfWant()
            .add(_getNTokenTotalValueFromPortfolio())
            .add(_getRewardsValue())
        ;
    }

    /*
     * @notice
     *  Function claiming the pending rewards for the strategy (if any), swap them to WETH in balancer
     * as it's the primary exchange venue for NOTE (only a NOTE / WETH pool available) and if want is not WETH, 
     * swap the obtained in WETH in Sushi
     * @return uint256, value containing the current valuation of accumulakted rewards
     */
    function _claimRewards() internal {
        uint256 _incentives = noteToken.balanceOf(address(this));
        _incentives += nProxy.nTokenClaimIncentives();

        if (_incentives > 0) {
            // Create the NOTE/WETH swap object for balancer
            IBalancerVault.SingleSwap memory swap = IBalancerVault.SingleSwap(
                poolId,
                IBalancerVault.SwapKind.GIVEN_IN,
                IAsset(address(noteToken)),
                IAsset(address(weth)),
                _incentives,
                abi.encode(0)
            );
             // Swap the NOTE tokens to WETH
            balancerVault.swap(
                swap, 
                IBalancerVault.FundManagement(address(this), false, address(this), false),
                _incentives, 
                now
                );
            
            if (currencyID > 1) {
                IERC20(address(weth)).safeApprove(address(router), weth.balanceOf(address(this)));
                // Path for Sushi is [weth, want]
                address[] memory path = new address[](2);
                path[0] = address(weth);
                path[1] = address(want);
                // Swap exact tokens
                router.swapExactTokensForTokens(
                    weth.balanceOf(address(this)),
                    0,
                    path,
                    address(this),
                    now
                );
                IERC20(address(weth)).safeApprove(address(router), 0);
            }

        }

    }

    /*
     * @notice
     *  Accounting function preparing the reporting to the vault taking into acccount the standing debt
     * @param _debtOutstanding, Debt still left to pay to the vault
     * @return _profit, the amount of profits the strategy may have produced until now
     * @return _loss, the amount of losses the strategy may have produced until now
     * @return _debtPayment, the amount the strategy has been able to pay back to the vault
     */
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {   
        // Get all possible rewards to th strategy (in want)
        _claimRewards();
        // We only need profit for decision making
        (_profit, ) = getUnrealisedPL();

        // free funds to repay debt + profit to the strategy
        uint256 wantBalance = balanceOfWant();
        
        uint256 amountRequired = _debtOutstanding.add(_profit);
        if(amountRequired > wantBalance) {
            // we need to free funds
            // NOTE: liquidatePosition will try to use balanceOfWant first
            // liquidatePosition will realise Losses if required !! (which cannot be equal to unrealised losses if
            // we are not withdrawing 100% of position)
            uint256 amountAvailable = wantBalance;

            // If the toggle to realize losses is off, do not close any position
            if(toggleLiquidatePosition) {
                (amountAvailable, _loss) = liquidatePosition(amountRequired);
            }
            
            if(amountAvailable >= amountRequired) {
                // There are no realisedLosses, debt is paid entirely
                _debtPayment = _debtOutstanding;
                _profit = amountAvailable.sub(_debtOutstanding);
            } else {
                // we were not able to free enough funds
                if(amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // loss amount is not calculated here as it comes from the liquidate position assessment
                    // if the toggle was set positions are freed if not, but it could be done in the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    // We will not report and losses but pay the entire debtOutstanding and report the rest of
                    // amountAvailable as profit (therefore losses are 0 because we were able to pay debtPayment)
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable.sub(_debtPayment);
                    _loss = 0;
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
        }
    }

    /*
     * @notice
     * Function re-allocating the available funds (present in the strategy's balance in the 'want' token)
     * into new LP positions in Notional
     * @param _debtOutstanding, Debt still left to pay to the vault
     */
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Available balance
        uint256 availableWantBalance = balanceOfWant();
        
        // If there is more debt, don't do anything
        if(availableWantBalance <= _debtOutstanding) {
            return;
        }
        availableWantBalance = availableWantBalance.sub(_debtOutstanding);
        // Check if we have the minimum required
        if(availableWantBalance < minAmountWant) {
            return;
        }
        
        if (currencyID == 1) {
            // Only necessary for wETH/ ETH pair
            weth.withdraw(availableWantBalance);
        } else {
            want.approve(address(nProxy), availableWantBalance);
        }

        // Deposit all and mint all possible nTokens
        executeBalanceAction(
            DepositActionType.DepositUnderlyingAndMintNToken,
            availableWantBalance,
            0
        );

    }
    
    /*
     * @notice
     *  Internal function to assess the unrealised P&L of the Notional's positions
     * @return uint256 result, the encoded trade ready to be used in Notional's 'BatchTradeAction'
     */
    function getUnrealisedPL() internal view returns (uint256 _unrealisedProfit, uint256 _unrealisedLoss) {
        // Calculate assets. This includes profit and cost of closing current position. 
        // Due to cost of closing position, If called just after opening the position, assets < invested want
        uint256 totalAssets = estimatedTotalAssets();
        // Get total debt from vault
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        // Calculate current P&L
        if(totalDebt > totalAssets) {
            // we have losses
            // Losses are unrealised until we close the position so we should not report them until realised
            _unrealisedLoss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _unrealisedProfit = totalAssets.sub(totalDebt);
        }

    }

    /*
     * @notice
     *  Internal function liquidating enough Notional positions to liberate _amountNeeded 'want' tokens
     * @param _amountNeeded, The total amount of tokens needed to pay the vault back
     * @return uint256 _liquidatedAmount, Amount freed
     * @return uint256 _loss, Losses incurred due to early closing of positions
     */
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // If enough want balance can repay the debt, do it
        uint256 wantBalance = balanceOfWant();
        if (wantBalance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }
        // Get current position's P&L
        (, uint256 unrealisedLosses) = getUnrealisedPL();
        // We only need to withdraw what we don't currently have in want
        uint256 amountToLiquidate = _amountNeeded.sub(wantBalance);
        
        // The strategy will only realise losses proportional to the amount we are liquidating
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 lossesToBeRealised = unrealisedLosses.mul(amountToLiquidate).div(totalDebt.sub(wantBalance));

        // Due to how Notional works, we need to substract losses from the amount to liquidate
        // If we don't do this and withdraw a small enough % of position, we will not incur in losses,
        // leaving them for the future withdrawals (which is bad! those who withdraw should take the losses)
        
        amountToLiquidate = amountToLiquidate.sub(lossesToBeRealised);
        
        // Minor gas savings
        uint16 _currencyID = currencyID;
        // Liquidate the proportional part of nTokens necessary
        // We calculate the number of tokens to redeem by calculating the % of assets to 
        // liquidate and applying that % to the # of nTokens held
        // NOTE: We do not use estimatedTotalAssets as it includes the value of the rewards
        // instead we use the internal function calculating the value of the nToken position
        uint256 tokensToRedeem = amountToLiquidate
            .mul(nProxy.nTokenBalanceOf(_currencyID, address(this)))
            .div(_getNTokenTotalValueFromPortfolio()
                );
        
        // We launch the balance action with RedeemNtoken type and the previously calculated amount of tokens
        executeBalanceAction(
            DepositActionType.RedeemNToken, 
            tokensToRedeem,
            0
        );

        // Assess result 
        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            // _loss should be equal to lossesToBeRealised ! 
            _loss = _amountNeeded.sub(totalAssets);
            
        } else {
            _liquidatedAmount = totalAssets;
        }

        // Re-set the toggle to false
        toggleLiquidatePosition = false;
    }
    
    /*
     * @notice
     *  External function used in emergency to redeem a specific amount of tokens manually
     * @param amountToRedeem number of tokens to redeem
     * @return uint256 amountLiquidated, the total amount liquidated
     */
    function redeemNTokenAmount(uint256 amountToRedeem) external onlyVaultManagers {
        executeBalanceAction(
                    DepositActionType.RedeemNToken, 
                    amountToRedeem,
                    0
                );
    }

    /*
     * @notice
     *  Internal function used in emergency to close all active positions and liberate all assets
     * @return uint256 amountLiquidated, the total amount liquidated
     */
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 claimableRewards = noteToken.balanceOf(address(this));
        claimableRewards += nProxy.nTokenGetClaimableIncentives(address(this), block.timestamp);
        if(claimableRewards > 0 && 
            toggleClaimRewards) {
            _claimRewards();
        }
        uint256 nTokenBalance = nToken.balanceOf(address(this));
        executeBalanceAction(
                    DepositActionType.RedeemNToken, 
                    nTokenBalance,
                    0
                );

        return balanceOfWant();
    }

    /*
     * @notice
     *  External function used in emergency to claim and swap to want tokens the NOTE rewards
     */
    function manuallyClaimRewards() external onlyVaultManagers {
        _claimRewards();
    }
    
    /*
     * @notice
     *  Internal function used to migrate all 'want' tokens and active Notional positions to a new strategy
     * @param _newStrategy address where the contract of the new strategy is located
     */
    function prepareMigration(address _newStrategy) internal override {
        uint256 claimableRewards = noteToken.balanceOf(address(this));
        claimableRewards += nProxy.nTokenGetClaimableIncentives(address(this), block.timestamp);
        if(claimableRewards > 0 && 
            toggleClaimRewards) {
            _claimRewards();
        }
        // Transfer nTokens and NOTE incentives (may be necessary to claim them)
        uint256 nTokenBalance = nToken.balanceOf(address(this));
        nToken.transfer(_newStrategy, nTokenBalance);
    }

    /*
     * @notice
     *  Define protected tokens for the strategy to manage persistently that will not get converted back
     * to 'want'
     * @return address result, the address of the tokens to protect
     */
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /*
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     */
    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return _fromETH(_amtInWei, address(want));
    }

    /*
     * @notice
     *  Internal function exchanging between ETH to 'want'
     * @param _amount, Amount to exchange
     * @param asset, 'want' asset to exchange to
     * @return uint256 result, the equivalent ETH amount in 'want' tokens
     */
    function _fromETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(weth) // 1:1 change
        ) {
            return _amount;
        }

        (
            Token memory assetToken,
            Token memory underlyingToken,
            ETHRate memory ethRate,
            AssetRateParameters memory assetRate
        ) = nProxy.getCurrencyAndRates(currencyID);
            
        return _amount.mul(uint256(underlyingToken.decimals)).div(uint256(ethRate.rate));
    }

    // INTERNAL FUNCTIONS

    /*
     * @notice
     *  Internal view estimating the rewards value in want tokens. We simulate the trade in balancer to 
     * get WETH from the NOTE / WETH pool and if want is not weth, we simulate a trade in sushi to obtain want tokens 
     * @return uint256 tokensOut, current number of want tokens the strategy would obtain for its rewards
     */
    function _getRewardsValue() internal view returns(uint256 tokensOut) {
        // Get NOTE rewards
        uint256 claimableRewards = noteToken.balanceOf(address(this));
        claimableRewards += nProxy.nTokenGetClaimableIncentives(address(this), block.timestamp);
        if (claimableRewards > 0) {
            (IERC20[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock) = balancerVault.getPoolTokens(poolId);
            // Setup SwapRequest object for balancer
            IBalancerPool.SwapRequest memory swapRequest = IBalancerPool.SwapRequest(
                IBalancerPool.SwapKind.GIVEN_IN,
                tokens[1],
                tokens[0],
                claimableRewards,
                poolId,
                lastChangeBlock,
                address(this),
                address(this),
                abi.encode(0)
            );
            // Simulate NOTE/WETH trade
            tokensOut = balancerPool.onSwap(
                swapRequest, 
                balances[1],
                balances[0] 
            );
            
            // If want is not weth, simulate sushi trade
            if(currencyID > 1) {
                // Sushi path is [weth, want]
                address[] memory path = new address[](2);
                path[0] = address(weth);
                path[1] = address(want);
                // Get expected number of tokens out
                tokensOut = router.getAmountsOut(tokensOut, path)[1];
            }
        }

    }

    /*
     * @notice
     *  Loop through the strategy's positions and convert the fcash to current valuation in 'want', including the
     * fees incurred by leaving the position early. Represents the NPV of the position today.
     * @return uint256 _totalWantValue, the total amount of 'want' tokens of the strategy's positions
     */
    function _getNTokenTotalValueFromPortfolio() internal view returns(uint256 totalUnderlyingClaim) {
        address nTokenAddress = address(nToken);

        return NotionalLpLib.getNTokenTotalValueFromPortfolio(
                NotionalLpLib.NTokenTotalValueFromPortfolioVars(
                    address(this), 
                    nTokenAddress,
                    nProxy,
                    currencyID
                )
            );
    }

    // CALCS
    /*
     * @notice
     *  Internal function getting the current 'want' balance of the strategy
     * @return uint256 result, strategy's 'want' balance
     */
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // NOTIONAL FUNCTIONS
    /*
     * @notice
     *  Internal function executing a 'batchBalanceAndTradeAction' within Notional to either Lend,Borrow or mint nTokens
     * @param actionType, Identification of the action to perform, following the Notional classification 
     * in enum 'DepositActionType'
     * @param withdrawAmountInternalPrecision, withdraw an amount of asset cash specified in Notional 
     *  internal 8 decimal precision
     * @param withdrawEntireCashBalance, whether to withdraw entire cash balance. Useful if there may be
     * an unknown amount of asset cash residual left from trading
     * @param redeemToUnderlying, whether to redeem asset cash to the underlying token on withdraw
     * @param trades, array of bytes32 trades to perform
     */
    function checkIdiosyncratic() external view returns(bool){
        return NotionalLpLib.checkIdiosyncratic(nProxy, currencyID, address(nToken));
    }

    function executeBalanceAction(
        DepositActionType actionType,
        uint256 depositActionAmount,
        uint256 withdrawAmountInternalPrecision
        ) internal {

        uint16 _currencyID = currencyID;
        // Handle the 24h protection window where an nToken may have an idiosyncratic position
        if (NotionalLpLib.checkIdiosyncratic(nProxy, _currencyID, address(nToken))) {
            return;
        }

        BalanceAction[] memory actions = new BalanceAction[](1);
        // gas savings
        actions[0] = BalanceAction(
            actionType,
            _currencyID,
            depositActionAmount,
            withdrawAmountInternalPrecision,
            true, 
            true
        );

        if (_currencyID == 1) {
            if (actionType == DepositActionType.DepositUnderlyingAndMintNToken) {
                nProxy.batchBalanceAction{value: depositActionAmount}(address(this), actions);
            } else if (actionType == DepositActionType.RedeemNToken) {
                nProxy.batchBalanceAction(address(this), actions);
            }
            weth.deposit{value: address(this).balance}();
        } else {
            nProxy.batchBalanceAction(address(this), actions);
        }
    }

    // TODO: Implement harvestTrigger that checks whether in 24h we'll be in the 24h protection window after maturity
    // do it by checking maturity time of market index == 1    

}