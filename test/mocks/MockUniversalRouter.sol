 // SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Actions} from "@uniswap/v4-periphery/contracts/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/contracts/interfaces/IV4Router.sol";

/**
 * @title MockUniversalRouter
 * @notice Mocks the Uniswap Universal Router for testing swaps.
 * @dev This implements the specific `execute` function
 * that IUniversalRouter requires and that our bank contract uses.
 */
contract MockUniversalRouter is IUniversalRouter {
    IERC20 public tokenIn;
    IERC20 public usdc;
    uint256 public swapRate; // How many USDC per 1 tokenIn (e.g., 500e6)

    constructor(address tokenIn_, address usdc_, uint256 rate_) {
        tokenIn = IERC20(tokenIn_);
        usdc = IERC20(usdc_);
        swapRate = rate_; // e.g., 500e6 = 500 USDC per 1 tokenIn (at 18->6 dec)
    }

    /**
     * @notice This is the *correctly* signed function to match the interface.
     * It simulates a V4 swap.
     * 1. It pulls the `tokenIn` from the caller (the KipuBank contract).
     * 2. It calculates the `usdc` output.
     * 3. It transfers the `usdc` back to the caller.
     */
    function execute(
        bytes calldata, // commands - we don't use it in this mock
        bytes[] calldata inputs, // inputs
        uint256 // deadline - we don't use it in this mock
    ) external payable {
        // We decode the inputs to find the `amountIn`
        // In the real swap, inputs[0] is abi.encode(actions, params)
        (bytes memory actions, bytes[] memory params) = abi.decode(
            inputs[0],
            (bytes, bytes[])
        );

        // Find the SWAP_EXACT_IN_SINGLE action (0)
        uint256 amountIn;
        if (uint8(actions[0]) == uint8(Actions.SWAP_EXACT_IN_SINGLE)) {
            IV4Router.ExactInputSingleParams memory swapParams = abi.decode(
                params[0],
                (IV4Router.ExactInputSingleParams)
            );
            amountIn = swapParams.amountIn;
        } else {
            revert("MockRouter: Expected SWAP_EXACT_IN_SINGLE");
        }

        // 1. Pull the `tokenIn` from KipuBank (msg.sender)
        // This simulates the `SETTLE_ALL` action, assuming the bank
        // has approved this router.
        tokenIn.transferFrom(msg.sender, address(this), amountIn);

        // 2. Calculate output (adjusting for 18 -> 6 decimals)
        // (amountIn * rate) / 1e18
        uint256 amountOut = (amountIn * swapRate) / 1e18;

        // 3. Send `usdc` back to KipuBank
        usdc.transfer(msg.sender, amountOut);
    }

    /**
     * @notice This is the second `execute` overload from the interface.
     * We must implement it to avoid the "abstract" error, but it can be empty.
     */
    function execute(
        bytes calldata, // commands
        bytes[] calldata // inputs
    ) external payable {
        // We don't use this overload, so we can leave it empty.
        // It just needs to exist.
    }
}
