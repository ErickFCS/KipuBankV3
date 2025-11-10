# KipuBankV3

## Overview

**KipuBankV3** is a multi-asset, non-custodial vault contract on Ethereum. It allows users to deposit and withdraw ETH and various ERC-20 tokens into a personal, gas-efficient balance sheet. The contract enforces a global, USD-denominated deposit cap and a per-transaction USD-denominated extraction limit.

This version also integrates with Uniswap V4 to provide a `swapExactInputForUSDC` function, allowing users to deposit any ERC-20 token and have it automatically converted and credited as USDC in their vault balance.

##  Implemented Improvements (V2 -> V3)

This contract version includes several key improvements over a V2 design:

1.  **Functional Swaps:** The primary improvement was re-architecting the contract to support a swappable, non-constant `i_usdcAddress`. The V2 design had `USDC_ADDRESS` set to `address(0)`, which made the swap function untestable and non-functional. By making `i_usdcAddress` an `immutable` variable set in the constructor, the contract can now correctly interact with a real USDC token, enabling the `swapExactInputForUSDC` feature.

2.  **Enhanced Testability:** The `getBalance` function was refactored from `getBalance(token)` to `getBalance(user, token)`. On a public blockchain, all state is public, so this change does not introduce any security or privacy risk. It serves as a crucial "getter" function that simplifies on-chain data access for UIs, analytics, and—most importantly—our Foundry test suite.

3.  **Robust Error Handling:** The contract's internal logic was validated to ensure it reverts with the correct custom errors (e.g., `KipuBank_CapReached`, `KipuBank_LimitExceeded`). Tests were also written to confirm that external call failures (like `ERC20InsufficientAllowance`) are correctly handled and revert as expected.

##  Deployment and Interaction

### Deployment

The contract must be deployed using Foundry, providing all 6 immutable arguments.

1.  **Set Environment Variables:**
    ```bash
    export RPC_URL=<YOUR_RPC_URL>
    export PRIVATE_KEY=<YOUR_PRIVATE_KEY>
    export ETHERSCAN_API_KEY=<YOUR_ETHERSCAN_API_KEY>
    ```

2.  **Set Constructor Arguments:**
    * `_maxExtractUSD`: Max extraction limit (in 6 decimals).
    * `_bankCapUSD`: Total bank cap (in 6 decimals).
    * `_priceFeedAddress`: Chainlink ETH/USD feed.
    * `_routerAddress`: Uniswap Universal Router address.
    * `_permit2Address`: Uniswap Permit2 address.
    * `_usdcAddress`: The official USDC token address.

3.  **Deploy Command:**
    ```bash
    forge create src/KipuBankV3.sol:KipuBankV3 \
        --rpc-url $RPC_URL \
        --private-key $PRIVATE_KEY \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        --verify \
        --constructor-args 10000e6 1000000e6 <_priceFeedAddress> <_routerAddress> <_permit2Address> <_usdcAddress>
    ```

### Interaction

You can interact with the deployed contract using `cast`.

**Example: Deposit 0.1 ETH**
```bash
cast send <BANK_ADDRESS> "depositETH()" --value 0.1ether --rpc-url $RPC_URL --private-key $PRIVATE_KEY
````

**Example: Deposit 100 WETH (ERC-20)**
*First, approve the bank to spend your WETH:*

```bash
cast send <WETH_ADDRESS> "approve(address,uint256)" <BANK_ADDRESS> 100e18 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

*Then, call `depositERC20`:*

```bash
cast send <BANK_ADDRESS> "depositERC20(address,uint256)" <WETH_ADDRESS> 100e18 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

**Example: Extract 0.05 ETH**

```bash
cast send <BANK_ADDRESS> "extractFromAccount(address,uint256)" 0x0000000000000000000000000000000000000000 0.05e18 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

##  Design Decisions & Trade-offs

1.  **`_getUSDValue` Oracle Simplification:**

      * **Decision:** The `_getUSDValue` function perfectly values ETH using a Chainlink oracle. However, for all other ERC-20 tokens, it **assumes a 1:1 USD peg** and simply adjusts for decimals.
      * **Trade-off:** This was a major simplification to make the core deposit/extract logic testable without integrating a complex multi-token oracle system.
      * **Result:** This makes the contract **unsafe for production use** with any non-stablecoin ERC-20 (e.g., WETH, WBTC), as it would incorrectly value them, breaking the cap and limit logic.

2.  **`getBalance(user, token)`:**

      * **Decision:** The `getBalance` function was made public and takes a `_user` argument.
      * **Trade-off:** This may seem like a privacy leak to Web2 developers. However, all storage on Ethereum is public, and `s_accounts` could be read externally regardless.
      * **Result:** This design provides a convenient, gas-efficient "getter" for public data, which is standard practice and greatly simplifies UI development and testing.

3.  **Hardcoded V4 Pool Key:**

      * **Decision:** The `getPoolKey` function hardcodes the fee tier (3000) and tick spacing (60) for swaps.
      * **Trade-off:** This simplifies the `swapExactInputForUSDC` function, as the user doesn't need to provide this data.
      * **Result:** The swap function will fail if a liquid pool for `TokenIn -> USDC` does not exist at the 0.3% fee tier.

##  Threat Analysis Report

### 1\. Protocol Weaknesses & Missing Maturity Steps

The single greatest weakness preventing this contract from being production-ready is the **oracle logic in `_getUSDValue`**.

  * **Critical Weakness:** The 1:1 USD peg assumption for all non-ETH ERC-20s is fundamentally insecure. A user could deposit 1,000 WETH (worth $3,000,000) and the contract would value it at $1,000, effectively bypassing the `i_bankCapUSD` entirely.

  * **Missing Step:** To reach maturity, this function **must** be refactored to:

    1.  Use a robust, production-grade oracle (like Chainlink Price Feeds) for *every* token the contract will accept.
    2.  Implement a whitelist of acceptable ERC-20 tokens that have a corresponding price feed.
    3.  A `depositERC20` call with a non-whitelisted token should be rejected.

  * **Minor Weakness:** The contract does not check for stale data from the Chainlink ETH/USD feed. While it checks for `price <= 0`, a production contract should also check `updatedAt` to ensure the price is recent.

  * **Minor Weakness:** The swap function relies on a hardcoded V4 pool key. This is inflexible and will fail for tokens that have liquidity at different fee tiers.

### 2\. Test Coverage

The contract is accompanied by a **17-test suite** built with Foundry. All 17 tests are currently passing.

  * **12 Revert Tests:** These tests confirm that all security modifiers and internal checks function correctly. This includes:

      * `KipuBank_CapReached`
      * `KipuBank_LimitExceeded`
      * `KipuBank_InsufficientBalance`
      * `KipuBank_ZeroValue`
      * `KipuBank_UseDepositEth`
      * `KipuBank_ZeroPriceFeed`
      * External `ERC20InsufficientAllowance` reverts

  * **5 Success Tests:** These tests confirm the "happy path" for every core function, including:

      * `depositETH`
      * `depositERC20`
      * `extractFromAccount` (for ETH and ERC-20)
      * `swapExactInputForUSDC`

Coverage includes all external functions, modifiers, and primary event emissions.

### 3\. Testing Methods

  * **Framework:** Foundry
  * **Methodology:** Unit Testing
  * **Mocks:** All external dependencies were fully mocked for isolated, deterministic testing:
      * `MockERC20` (for USDC and TokenIn)
      * `MockAggregatorV3` (for the Chainlink Price Feed)
      * `MockUniversalRouter` (to simulate swap outputs)
  * **Validation:** Tests were written to validate:
    1.  Correct state changes (using `assertEq`).
    2.  Correct revert-with-error (using `vm.expectRevert`).
    3.  Correct event emission and order (using `vm.expectEmit`).

