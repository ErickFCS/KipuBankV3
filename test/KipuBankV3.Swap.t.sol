// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {KipuBankV3BaseTest} from "./KipuBankV3.Base.t.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @title KipuBankV3SwapExactInputForUSDCTest
 * @notice Tests all SwapExactInput functionality of KipuBankV3.
 */
contract KipuBankV3SwapTest is KipuBankV3BaseTest, IERC20Errors {
    /**
     * @notice Test A successful Token swap deposit.
     */
    function test_Swap_Success() public {
        uint128 amountIn = 10e18;
        uint256 expectedAmountOut = 15_000e6;
        uint128 minAmountOut = 14_900e6;

        tokenIn.mint(user, amountIn);

        vm.startPrank(user);
        tokenIn.approve(address(bank), amountIn);

        // 1. This event is emitted FIRST (from _updateAccountBalance).
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulBalanceUpdate(
            user,
            address(usdc),
            expectedAmountOut
        );

        // 2. This event is emitted SECOND (from swapExactInputForUSDC).
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulExchange(
            user,
            address(tokenIn),
            amountIn,
            expectedAmountOut
        );

        uint256 amountOut = bank.swapExactInputForUSDC(
            address(tokenIn),
            amountIn,
            minAmountOut,
            uint48(block.timestamp + 20)
        );
        vm.stopPrank();

        assertEq(amountOut, expectedAmountOut, "Amount out incorrect");

        assertEq(
            bank.getBalance(user, address(usdc)),
            expectedAmountOut,
            "User USDC balance incorrect"
        );
        assertEq(
            bank.s_totalDepositsUSD(),
            expectedAmountOut,
            "Total USD deposits incorrect"
        );
        assertEq(
            tokenIn.balanceOf(address(bank)),
            0,
            "Bank should have 0 tokenIn"
        );
        assertEq(
            usdc.balanceOf(address(bank)),
            expectedAmountOut,
            "Bank should have USDC"
        );
    }

    /**
     * @notice Test A unsuccessful Token swap deposit.
     * Here the allowed amount by the user is not sufficient or discrepant with the tokenInAmount.
     */
    function testRevert_Swap_FailedTokenDeposit() public {
        uint128 amountIn = 10e18;
        tokenIn.mint(user, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(bank),
                0,
                amountIn
            )
        );
        vm.prank(user);
        bank.swapExactInputForUSDC(
            address(tokenIn),
            amountIn,
            0,
            uint48(block.timestamp + 20)
        );
    }

    /**
     * @notice Test A unsuccessful Token swap deposit.
     * Here the swaped USDC values is less than expected.
     */
    function testRevert_Swap_BelowExpectedAmount() public {
        uint128 amountIn = 10e18;
        uint128 minAmountOut = 16_000e6; // Set min higher than actual (15_000)

        tokenIn.mint(user, amountIn);

        vm.startPrank(user);
        tokenIn.approve(address(bank), amountIn);

        vm.expectRevert(KipuBankV3.KipuBank_BelowExpectedAmount.selector);

        bank.swapExactInputForUSDC(
            address(tokenIn),
            amountIn,
            minAmountOut,
            uint48(block.timestamp + 20)
        );
        vm.stopPrank();
    }

    /**
     * @notice Test A unsuccessful Token swap deposit.
     * Here the Bankcap is reached.
     */
    function testRevert_Swap_CapReached() public {
        uint128 amountIn = 1_000e18; // 1,000 MTKN
        uint256 expectedUsdValue = 1_500_000e6; // $1.5M (over $1M cap)

        tokenIn.mint(user, amountIn);

        vm.startPrank(user);
        tokenIn.approve(address(bank), amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_CapReached.selector,
                user,
                expectedUsdValue
            )
        );

        bank.swapExactInputForUSDC(
            address(tokenIn),
            amountIn,
            0,
            uint48(block.timestamp + 20)
        );
        vm.stopPrank();
    }
}
