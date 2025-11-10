// SPDX-License-Identifier: BSD 3-Clause
pragma solidity 0.8.30;

// Interfaces
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IPermit2} from "@uniswap/permit2/contracts/interfaces/IPermit2.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/contracts/interfaces/IV4Router.sol";
// Access Control
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// Libraries
import {Actions} from "@uniswap/v4-periphery/contracts/libraries/Actions.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
// Types
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

/**
 * @title KipuBankV3
 * @author Erick Fernando Carvalho Sanchez
 * @notice A multi-asset vault allowing deposits and extractions of ETH and ERC-20 tokens,
 * with a global USD-denominated deposit cap and a per-transaction extraction limit.
 * ETH is represented by address(0).
 * @custom:security Implements the Checks-Effects-Interactions (CEI) pattern in all external functions.
 * @custom:decimal-standard All USD-denominated values (caps, limits, total deposits) are scaled to 6 decimals.
 */
contract KipuBankV3 is Ownable {
    /*///////////////////////////////////
    //           Type declarations
    ///////////////////////////////////*/
    /// @notice Defines the type of balance update operation.
    enum Operation {
        Extract,
        Deposit
    }

    /// @notice The standard decimal unit for internal USD accounting (e.g., 6 for USDC).
    uint8 private constant USD_STANDARD_DECIMALS = 6;

    /*///////////////////////////////////
    //           Immutable variables
    ///////////////////////////////////*/
    /// @notice Total cumulative deposit value allowed across all assets, denominated in USD_STANDARD_DECIMALS.
    uint256 public immutable i_bankCapUSD;
    /// @notice Biggest USD value allowed for any single extraction, denominated in USD_STANDARD_DECIMALS.
    uint256 public immutable i_maxExtractUSD;
    /// @notice Instance of the Chainlink ETH/USD data feed.
    AggregatorV3Interface public immutable i_priceFeed;
    /// @notice Universal router Instance
    IUniversalRouter public immutable i_router;
    /// @notice Permit2 instance
    IPermit2 public immutable i_permit2;
    /// @notice The address of the USDC token.
    address public immutable i_usdcAddress;

    /*///////////////////////////////////
    //           State variables
    ///////////////////////////////////*/
    /// @notice Mapping for storing user balances: user => token address => balance.
    /// Balances are stored in the token's native decimals.
    mapping(address user => mapping(address token => uint256 balance))
        private s_accounts;

    /// @notice Total value deposited across all assets, denominated in USD_STANDARD_DECIMALS.
    uint256 public s_totalDepositsUSD;

    /*///////////////////////////////////
    //                Errors
    ///////////////////////////////////*/
    /// @notice Emitted when a ETH deposit is done via the recive or depositERC20 function.
    /// @param wallet The address that attempted the deposit.
    /// @param quantity The USD value of the failed deposit (in USD_STANDARD_DECIMALS).
    error KipuBank_UseDepositEth(address wallet, uint256 quantity);
    /// @notice Emitted when a deposit fails due to the bank cap being reached.
    /// @param wallet The address that attempted the deposit.
    /// @param quantity The USD value of the failed deposit (in USD_STANDARD_DECIMALS).
    error KipuBank_CapReached(address wallet, uint256 quantity);
    /// @notice Emitted when an extraction exceeds the extract limit.
    /// @param wallet The address that attempted the extraction.
    /// @param quantity The token quantity of the failed extraction (in token decimals).
    error KipuBank_LimitExceeded(address wallet, uint256 quantity);
    /// @notice Emitted when an extraction have insufficient balance.
    /// @param wallet The address that attempted the extraction.
    /// @param quantity The token quantity of the failed extraction (in token decimals).
    error KipuBank_InsufficientBalance(address wallet, uint256 quantity);
    /// @notice Emitted when a transfer interaction fail after the checks and effects.
    /// @param wallet The address that attempted the interaction.
    /// @param quantity The token quantity of the failed interaction (in token decimals).
    error KipuBank_FailedInteraction(address wallet, uint256 quantity);
    /// @notice Emitted when the price feed address is address(0).
    error KipuBank_ZeroPriceFeed();
    /// @notice Emitted when the ETH price given by the oracle is lesser or equal 0.
    error KipuBank_InvalidOracleETHPrice();
    /// @notice Emitted when a zero value is passed to a function that requires a positive quantity.
    error KipuBank_ZeroValue();
    /// @notice Emitted when an ERC20 token exchange to USDC token amount is lesser than the expected.
    error KipuBank_BelowExpectedAmount();
    /// @notice Emitted when an ERC20 token transfer to contract fails.
    error KipuBank_FailedTokenDeposit();

    /*///////////////////////////////////
    //              Events
    ///////////////////////////////////*/
    /// @notice Emitted when a successful extraction occurs.
    /// @param wallet The address of the account that extracted.
    /// @param token The token address (address(0) for ETH).
    /// @param quantity The quantity extracted (in token decimals).
    event KipuBank_SuccessfulExtract(
        address indexed wallet,
        address indexed token,
        uint256 quantity
    );
    /// @notice Emitted when a successful deposit occurs.
    /// @param wallet The address of the account that deposited.
    /// @param token The token address (address(0) for ETH).
    /// @param quantity The quantity deposited (in token decimals).
    /// @param usdValue The USD value of the deposit (in USD_STANDARD_DECIMALS).
    event KipuBank_SuccessfulDeposit(
        address indexed wallet,
        address indexed token,
        uint256 quantity,
        uint256 usdValue
    );
    /// @notice Emitted after any successful balance update for an account.
    /// @param wallet The address of the account whose balance was updated.
    /// @param token The token address (address(0) for ETH).
    /// @param newBalance The new total balance of the account (in token decimals).
    event KipuBank_SuccessfulBalanceUpdate(
        address indexed wallet,
        address indexed token,
        uint256 newBalance
    );
    /// @notice Emitted after any successful ERC20 token exchange.
    /// @param wallet The address of the account.
    /// @param token The token address.
    /// @param tokenAmount The token amount.
    /// @param USDCAmount The USDC token amountOut.
    event KipuBank_SuccessfulExchange(
        address indexed wallet,
        address indexed token,
        uint256 tokenAmount,
        uint256 USDCAmount
    );

    /*///////////////////////////////////
    //              Modifiers
    ///////////////////////////////////*/
    /**
     * @notice Verifies the global bank cap limit.
     * @dev Checks that the new total deposits will not exceed the immutable cap.
     * @param _usdValue The USD value of the deposit to check against the cap (in USD_STANDARD_DECIMALS).
     */
    modifier underBankCap(uint256 _usdValue) {
        if (s_totalDepositsUSD + _usdValue > i_bankCapUSD)
            revert KipuBank_CapReached(msg.sender, _usdValue);
        _;
    }

    /**
     * @notice Checks if the provided quantity is positive.
     * @param _quantity The quantity to check.
     */
    modifier positiveAmount(uint256 _quantity) {
        if (_quantity == 0) revert KipuBank_ZeroValue();
        _;
    }

    /**
     * @notice Checks if the provided price feed address is address(0).
     * @param _priceFeedAddress price feed address.
     */
    modifier noZeroPriceFeed(address _priceFeedAddress) {
        if (_priceFeedAddress == address(0)) {
            revert KipuBank_ZeroPriceFeed();
        }
        _;
    }

    /**
     * @notice Checks if the provided token address is address(0)(aka ETH).
     * @param _token token address.
     * @param _quantity The quantity of tokens (in token decimals).
     */
    modifier noEthToken(address _token, uint256 _quantity) {
        if (_token == address(0))
            revert KipuBank_UseDepositEth(msg.sender, _quantity); // Use depositETH
        _;
    }

    /**
     * @notice Checks if the token extract usd value is lesser than the extract limit.
     * @param _token token address.
     * @param _quantity The quantity of tokens (in token decimals).
     */
    modifier belowExtractLimit(address _token, uint256 _quantity) {
        if (_getUSDValue(_token, _quantity) > i_maxExtractUSD)
            revert KipuBank_LimitExceeded(msg.sender, _quantity);
        _;
    }

    /*///////////////////////////////////
    //            constructor
    ///////////////////////////////////*/
    /**
     * @notice Initializes the contract with limits, caps, and the Chainlink Oracle address.
     * @param _maxExtractUSD The biggest USD value allowed for a single extraction (in USD_STANDARD_DECIMALS).
     * @param _bankCapUSD The total bank USD limit for all deposits (in USD_STANDARD_DECIMALS).
     * @param _priceFeedAddress The address of the Chainlink ETH/USD Data Feed.
     */
    constructor(
        uint256 _maxExtractUSD,
        uint256 _bankCapUSD,
        address _priceFeedAddress,
        address _routerAddress,
        address _permit2Address,
        address _usdcAddress
    ) noZeroPriceFeed(_priceFeedAddress) Ownable(msg.sender) {
        i_maxExtractUSD = _maxExtractUSD;
        i_bankCapUSD = _bankCapUSD;
        i_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        i_router = IUniversalRouter(_routerAddress);
        i_permit2 = IPermit2(_permit2Address);
        i_usdcAddress = _usdcAddress;
    }

    /*///////////////////////////////////
    //         Receive & Fallback
    ///////////////////////////////////*/
    /**
     * @notice Prevents direct accidental or intentional Ether deposits via the 'send' or 'transfer' methods.
     * @dev Requires users to use the explicit `depositETH()` function to enforce cap checks.
     */
    receive() external payable {
        revert KipuBank_UseDepositEth(msg.sender, msg.value);
    }

    /*///////////////////////////////////
    //             External
    ///////////////////////////////////*/

    /**
     * @notice Deposits Native Ether to the sender's account.
     * @dev The function uses `msg.value` as the deposit quantity.
     */
    function depositETH()
        external
        payable
        positiveAmount(msg.value) // CHECK: Ensure value > 0
        underBankCap(_getUSDValue(address(0), msg.value)) // CHECK: Cap check
    {
        // 1. CHECKS (Completed by modifiers)

        // 2. EFFECTS
        // Calculate USD value and update state (only read from view function once)
        uint256 usdValue = _getUSDValue(address(0), msg.value);

        // Safe addition: Since the underBankCap modifier passed, we know there's no overflow
        // relative to the cap, but we use 'unchecked' here to skip redundant mathematical
        // overflow/underflow checks since the quantity is checked against the cap already,
        // and we assume the cap is less than max(uint256).
        unchecked {
            s_totalDepositsUSD += usdValue;
        }

        // Update user balance (internal state change)
        _updateAccountBalance(address(0), msg.value, Operation.Deposit);

        // 3. INTERACTIONS (None in the ETH deposit flow)

        // 4. LOGGING
        emit KipuBank_SuccessfulDeposit(
            msg.sender,
            address(0),
            msg.value,
            usdValue
        );
    }

    /**
     * @notice Deposits an ERC-20 token to the sender's account. Must be pre-approved by the sender.
     * @dev The function uses `transferFrom` to pull tokens from the sender.
     * @param _token The address of the ERC-20 token.
     * @param _quantity The quantity of tokens to deposit (in token decimals).
     */
    function depositERC20(
        address _token,
        uint256 _quantity
    )
        external
        positiveAmount(_quantity) // CHECK: Ensure quantity > 0.
        underBankCap(_getUSDValue(_token, _quantity)) // CHECK: Cap check.
        noEthToken(_token, _quantity) // CHECK: Ensure not ETH.
    {
        // 1. CHECKS (Completed by modifiers).

        // 2. EFFECTS.
        // Calculate USD value and update state (only read from view function once).
        uint256 usdValue = _getUSDValue(_token, _quantity);

        // Safe addition: Using unchecked as the check is performed in the modifier.
        unchecked {
            s_totalDepositsUSD += usdValue;
        }

        // Update user balance (internal state change).
        _updateAccountBalance(_token, _quantity, Operation.Deposit);

        // 3. INTERACTIONS (Token pull).
        // NOTE: The gas cost of this call must be less than the remaining gas.
        bool success = IERC20(_token).transferFrom(
            msg.sender,
            address(this),
            _quantity
        );
        if (!success) revert KipuBank_FailedInteraction(msg.sender, _quantity);

        // 4. LOGGING.
        emit KipuBank_SuccessfulDeposit(
            msg.sender,
            _token,
            _quantity,
            usdValue
        );
    }

    /**
     * @notice Extracts either Native Ether (address(0)) or an ERC-20 token.
     * Crucially, the token balance are updated BEFORE the external call.
     * @param _token The address of the asset (address(0) for ETH).
     * @param _quantity The quantity to extract (in token decimals).
     */
    function extractFromAccount(
        address _token,
        uint256 _quantity
    ) external positiveAmount(_quantity) belowExtractLimit(_token, _quantity) {
        // 1. CHECKS (Completed by modifiers).

        // 2. EFFECTS (State changes before external interaction)

        // Update user balance (internal state change)
        // NOTE: This updates the storage variable s_accounts[msg.sender][_token]
        _updateAccountBalance(_token, _quantity, Operation.Extract);

        // 3. INTERACTIONS (External transfer/call)
        bool success;
        if (_token == address(0)) {
            // ETH transfer via low-level call (less gas)
            (success, ) = msg.sender.call{value: _quantity}("");
        } else {
            // ERC-20 transfer
            success = IERC20(_token).transfer(msg.sender, _quantity);
        }

        // Post-interaction CHECK (Success of transfer)
        if (!success) revert KipuBank_FailedInteraction(msg.sender, _quantity);

        // 4. LOGGING
        emit KipuBank_SuccessfulExtract(msg.sender, _token, _quantity);
    }

    /**
     * @notice Swap and exact amount of erc20 token for USDC and then deposits it into this contract.
     * @dev The noEthToken modifier avoids address(0) token deposits, but allows ETH as erc20.
     * @param _tokenIn Token address for deposit.
     * @param _amountIn Token amount to exchange (in token decimals).
     * @param _minAmountOut Minimal amount expected to obtain of usdc tokens.
     * @param _deadline Timeout for the exchage to fulfill
     */
    function swapExactInputForUSDC(
        address _tokenIn,
        uint128 _amountIn,
        uint128 _minAmountOut,
        uint48 _deadline
    ) external noEthToken(_tokenIn, _amountIn) returns (uint256 amountOut_) {
        // Saves the current USDC contract holding.
        uint256 startingUSDCAmount = IERC20(i_usdcAddress).balanceOf(
            address(this)
        );

        // Pre-requisite: User Approval
        // The user must approve this contract for the token and amount.
        // Get token into the contract for router pull.
        bool success = IERC20(_tokenIn).transferFrom(
            msg.sender,
            address(this),
            _amountIn
        );
        if (!success) revert KipuBank_FailedTokenDeposit();

        // get poolKey
        PoolKey memory key = getPoolKey(_tokenIn);

        // Determine swap direction (zeroForOne: currency0 -> currency1)
        bool zeroForOne = Currency.unwrap(key.currency0) == _tokenIn;

        // Define Universal Router Commands & Actions
        // The single command is to execute a V4 swap flow.
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // The V4 flow consists of three actions: Swap, Settle, Take
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), // 1. Execute the core swap logic
            uint8(Actions.SETTLE_ALL), // 2. Transfer the input token to PoolManager
            uint8(Actions.TAKE_ALL) // 3. Transfer the output token (USDC) out
        );

        // Encode Inputs for the Actions
        bytes[] memory params = new bytes[](3);

        // Params[0]: The main swap configuration for SWAP_EXACT_IN_SINGLE
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router
            .ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: _amountIn,
                amountOutMinimum: _minAmountOut,
                hookData: new bytes(0) // No hook data for a non-hooked pool
            });
        params[0] = abi.encode(swapParams);

        // Params[1]: SETTLE_ALL input: the token to settle and the amount
        params[1] = abi.encode(_tokenIn, _amountIn);

        // Params[2]: TAKE_ALL input: the token to take and the minimum amount expected
        params[2] = abi.encode(i_usdcAddress, _minAmountOut);

        // Final Execution Encoding
        // The Universal Router `execute` takes an array of inputs, each being the encoded (actions + params) bundle.
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the Swap
        // The deadline ensures the transaction doesn't execute if pending for too long (e.g., 20 seconds from now)
        i_router.execute(commands, inputs, _deadline);

        // Calculate and Return Output
        // The Universal Router deposits the output token (USDC) to this contract,
        amountOut_ =
            IERC20(i_usdcAddress).balanceOf(address(this)) -
            startingUSDCAmount;
        // CHECK if the minimal amount was reached.
        if (amountOut_ < _minAmountOut) revert KipuBank_BelowExpectedAmount();
        // CHECK if the bankcap was reached.
        if (s_totalDepositsUSD + amountOut_ > i_bankCapUSD)
            revert KipuBank_CapReached(msg.sender, amountOut_);
        // Effect Updates the total deposits count. Unchecked because above we already checked for overflow.
        unchecked {
            s_totalDepositsUSD = s_totalDepositsUSD + amountOut_;
        }
        // Effect Update sender balance.
        _updateAccountBalance(i_usdcAddress, amountOut_, Operation.Deposit);
        // Log emit success event.
        emit KipuBank_SuccessfulExchange(
            msg.sender,
            _tokenIn,
            _amountIn,
            amountOut_
        );
    }

    /*///////////////////////////////////
    //             Internal
    ///////////////////////////////////*/

    /**
     * @notice Updates the value of an account balance in the native token decimals.
     * @dev Crucial for the CEI pattern: all state modifications for the user's balance happen here,
     * ensuring atomicity and avoiding multiple storage accesses in the public functions.
     * The 'Extract' operation perform a last underflow check here for gas optimization reasons.
     * @param _token The address of the token (address(0) for ETH).
     * @param _quantity The quantity to add or subtract.
     * @param _operation The type of operation (Extract or Deposit).
     */
    function _updateAccountBalance(
        address _token,
        uint256 _quantity,
        Operation _operation
    ) private {
        uint256 newBalance;
        uint256 currentBalance = s_accounts[msg.sender][_token];

        // Safe math for addition/subtraction.
        if (_operation == Operation.Extract) {
            // Check for underflow here to avoid double currentBalance read (gas optimization).
            if (_quantity > currentBalance)
                revert KipuBank_InsufficientBalance(msg.sender, _quantity);
            // Unchecked because if passed the check above quantity is lesser or equal to currentBalance.
            unchecked {
                newBalance = currentBalance - _quantity;
            }
        } else {
            // Assuming the total balance will not exceed max(uint256).
            unchecked {
                newBalance = currentBalance + _quantity;
            }
        }

        // Write back to storage ONCE
        s_accounts[msg.sender][_token] = newBalance;

        emit KipuBank_SuccessfulBalanceUpdate(msg.sender, _token, newBalance);
    }

    /**
     * @notice Gets the USD value of an quantity of a specific asset.
     * @dev Fetches ETH/USD price from Chainlink for ETH deposits. For ERC-20, it currently uses a
     * simplified 1:1 USD peg, adjusting for decimals. **In a real contract, an Oracle for the
     * specific token (e.g., token/USD) must be used.**
     * @param _token The asset address (address(0) for ETH).
     * @param _quantity The quantity of the asset (in its native decimals).
     * @return The USD value of the quantity, scaled to USD_STANDARD_DECIMALS (6 decimals).
     */
    function _getUSDValue(
        address _token,
        uint256 _quantity
    ) private view returns (uint256) {
        if (_quantity == 0) return 0;

        uint256 assetDecimals;
        int256 ethPrice;
        uint8 priceFeedDecimals;

        if (_token == address(0)) {
            // 1. Native ETH valuation
            assetDecimals = 18; // ETH has 18 decimals

            // Get ETH/USD price from Chainlink Oracle
            (
                ,
                // roundId
                ethPrice, // startedAt // updatedAt
                ,
                ,

            ) = i_priceFeed.latestRoundData(); // answeredInRound

            // Check for negative or stale price
            if (ethPrice <= 0) {
                revert KipuBank_InvalidOracleETHPrice();
            }
            priceFeedDecimals = i_priceFeed.decimals();

            // Calculate rawUSDValue = ethPrice * _quantity
            // Scale to USD_STANDARD_DECIMALS (6)
            // (ethPrice * _quantity * 10^USD_STANDARD_DECIMALS) / (10^(assetDecimals + priceFeedDecimals))
            uint256 rawUSDValue = uint256(ethPrice) * _quantity;

            // Use unchecked for the multiplication since the multiplication of two uint256 is safe,
            // and the division will prevent overall overflow unless the price is extremely high.
            unchecked {
                return
                    (rawUSDValue * (10 ** USD_STANDARD_DECIMALS)) /
                    (10 ** (assetDecimals + priceFeedDecimals));
            }
        } else {
            // 2. ERC-20 token valuation (Simplified for this exercise)
            // NOTE: A real contract must dynamically fetch token decimals and use a token/USD oracle.

            // Hardcode a common decimal value for simplification
            // In reality, this would require fetching decimals from the ERC20 contract:
            // assetDecimals = IERC20Metadata(_token).decimals();
            assetDecimals = 18;

            // Simplified 1:1 USD peg logic (e.g., for WETH or a fictional token)
            if (assetDecimals > USD_STANDARD_DECIMALS) {
                // Scale down (e.g., 18 to 6)
                return
                    _quantity / (10 ** (assetDecimals - USD_STANDARD_DECIMALS));
            } else if (assetDecimals < USD_STANDARD_DECIMALS) {
                // Scale up (e.g., 4 to 6)
                return
                    _quantity * (10 ** (USD_STANDARD_DECIMALS - assetDecimals));
            } else {
                // Decimals match (e.g., USDC, 6 decimals)
                return _quantity;
            }
        }
    }

    /**
     * @notice Gets the poolkey for a token ti USDC
     * @param _tokenIn The token address
     * @return poolKey_ The poolkey address
     */
    function getPoolKey(
        address _tokenIn
    ) internal view returns (PoolKey memory) {
        // Tokens must be ordered canonically: token0 < token1
        (address currency0, address currency1) = _tokenIn < i_usdcAddress
            ? (_tokenIn, i_usdcAddress)
            : (i_usdcAddress, _tokenIn);

        return
            PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 3000, // 0.3% fee tier (3000 basis points)
                tickSpacing: 60, // Standard tick spacing for 0.3%
                hooks: IHooks(address(0)) // No custom hook
            });
    }

    /*///////////////////////////////////
    //           View & Pure
    ///////////////////////////////////*/
    /**
     * @notice Get the balance of the caller's account for a specific asset.
     * @param _token The address of the asset (address(0) for ETH).
     * @param _user The address of the user who owns the balance.
     * @return balance_ The balance of the caller's account (in token native decimals).
     */
    function getBalance(
        address _user,
        address _token
    ) external view returns (uint256 balance_) {
        // Direct storage access for a view function is acceptable and efficient.
        return s_accounts[_user][_token];
    }
}
