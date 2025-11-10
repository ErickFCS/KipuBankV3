// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// 1. Foundry Imports
import {Test, console} from "forge-std/Test.sol";

// 2. Contract Imports
import {KipuBankV3} from "src/KipuBankV3.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";

// 3. Interface Imports
import {IPermit2} from "@uniswap/permit2/contracts/interfaces/IPermit2.sol";

/**
 * @title KipuBankV3BaseTest
 * @notice Base setup contract for all KipuBankV3 tests.
 * @dev This contract is abstract and intended to be inherited.
 */
abstract contract KipuBankV3BaseTest is Test {
    /*///////////////////////////////////
    //       Test Contract State
    //////////////////////////////////*/

    KipuBankV3 internal bank;
    MockAggregatorV3 internal mockPriceFeed;
    MockERC20 internal usdc;
    MockERC20 internal tokenIn;
    MockUniversalRouter internal mockRouter;

    // We can use a simple address for Permit2 as it's not used heavily
    address internal mockPermit2 = makeAddr("Permit2");

    /*///////////////////////////////////
    //          Test Users
    //////////////////////////////////*/

    address internal owner = address(this); // Test contract is owner
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    /*///////////////////////////////////
    //        Test Constants
    //////////////////////////////////*/

    // Price feed constants
    uint8 internal constant PRICE_FEED_DECIMALS = 8;
    int256 internal constant ETH_PRICE = 3_000e8; // $3,000 with 8 decimals

    // Bank constants (must match USD_STANDARD_DECIMALS = 6)
    uint256 internal constant BANK_CAP_USD = 1_000_000e6; // $1M cap
    uint256 internal constant MAX_EXTRACT_USD = 10_000e6; // $10k extract limit

    // Token decimals
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant TOKEN_IN_DECIMALS = 18;

    // Swap rate: 1 tokenIn (18 dec) = 1,500 USDC (6 dec)
    // (1e18 * 1500e6) / 1e18 = 1500e6
    uint256 internal constant SWAP_RATE = 1_500e6; // 1,500

    /*///////////////////////////////////
    //           Setup
    //////////////////////////////////*/

    /**
     * @notice Sets up the test environment before each test.
     */
    function setUp() public virtual {
        // 1. Deploy Mock Tokens
        usdc = new MockERC20("USD Coin", "USDC", USDC_DECIMALS);
        tokenIn = new MockERC20("Mock TokenIn", "MTKN", TOKEN_IN_DECIMALS);

        // 2. Deploy Mock Dependencies
        mockPriceFeed = new MockAggregatorV3(ETH_PRICE, PRICE_FEED_DECIMALS);
        mockRouter = new MockUniversalRouter(
            address(tokenIn),
            address(usdc),
            SWAP_RATE
        );

        // 3. Fund the Mock Router with USDC so it can pay for swaps
        usdc.mint(address(mockRouter), 10_000_000e6); // 10M USDC

        // 4. Deploy KipuBankV3 (using the assumed new constructor)
        bank = new KipuBankV3(
            MAX_EXTRACT_USD,
            BANK_CAP_USD,
            address(mockPriceFeed),
            address(mockRouter),
            mockPermit2,
            address(usdc)
        );

        // 5. Approve the router to pull tokens from the bank
        // This is necessary for the `SETTLE_ALL` action simulation
        vm.prank(address(bank));
        tokenIn.approve(address(mockRouter), type(uint256).max);
    }
}
