// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {KipuBankV3BaseTest} from "./KipuBankV3.Base.t.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @title KipuBankV3CoreTest
 * @notice Tests all core (non-swapExactInputForUSDC) functionality of KipuBankV3.
 */
contract KipuBankV3CoreTest is KipuBankV3BaseTest, IERC20Errors {
    /*///////////////////////////////////
    //        Constructor Tests
    //////////////////////////////////*/

    function test_Constructor_SetsImmutables() public {
        assertEq(bank.i_maxExtractUSD(), MAX_EXTRACT_USD);
        assertEq(bank.i_bankCapUSD(), BANK_CAP_USD);
        assertEq(address(bank.i_priceFeed()), address(mockPriceFeed));
        assertEq(address(bank.i_router()), address(mockRouter));
        assertEq(address(bank.i_permit2()), mockPermit2);
        assertEq(bank.i_usdcAddress(), address(usdc)); // Renamed to i_usdcAddress to match contract
        assertEq(bank.owner(), owner);
    }

    function testRevert_Constructor_ZeroPriceFeed() public {
        vm.expectRevert(KipuBankV3.KipuBank_ZeroPriceFeed.selector);
        new KipuBankV3(
            MAX_EXTRACT_USD,
            BANK_CAP_USD,
            address(0), // Zero address
            address(mockRouter),
            mockPermit2,
            address(usdc)
        );
    }

    /*///////////////////////////////////
    //        Receive/Fallback Tests
    //////////////////////////////////*/

    function testRevert_ReceiveETH() public {
        uint256 sendAmount = 1 ether;
        vm.deal(user, sendAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_UseDepositEth.selector,
                user,
                sendAmount
            )
        );
        vm.prank(user);
        // Captures the return value
        (bool success, ) = address(bank).call{value: sendAmount}("");
        // Silences the "unused local variable" warning by 'using' the variable
        if (success) {}
    }

    /*///////////////////////////////////
    //        depositETH Tests
    //////////////////////////////////*/

    function test_DepositETH_Success() public {
        uint256 depositAmount = 1 ether;
        uint256 expectedUsdValue = 3_000e6;

        vm.deal(user, depositAmount);

        // 1. This event is emitted FIRST (from _updateAccountBalance)
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulBalanceUpdate(
            user,
            address(0),
            depositAmount
        );

        // 2. This event is emitted SECOND (from depositETH)
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulDeposit(
            user,
            address(0),
            depositAmount,
            expectedUsdValue
        );

        vm.prank(user);
        bank.depositETH{value: depositAmount}();

        assertEq(bank.getBalance(user, address(0)), depositAmount);
        assertEq(bank.s_totalDepositsUSD(), expectedUsdValue);
        assertEq(address(bank).balance, depositAmount);
    }

    function testRevert_DepositETH_ZeroValue() public {
        vm.expectRevert(KipuBankV3.KipuBank_ZeroValue.selector);
        vm.prank(user);
        bank.depositETH{value: 0}();
    }

    function testRevert_DepositETH_CapReached() public {
        uint256 depositAmount = 400 ether;
        uint256 expectedUsdValue = 1_200_000e6;

        vm.deal(user, depositAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_CapReached.selector,
                user,
                expectedUsdValue
            )
        );
        vm.prank(user);
        bank.depositETH{value: depositAmount}();
    }

    /*///////////////////////////////////
    //        depositERC20 Tests
    //////////////////////////////////*/

    function test_DepositERC20_Success() public {
        uint256 depositAmount = 10_000e18;
        uint256 expectedUsdValue = 10_000e6;

        tokenIn.mint(user, depositAmount);

        vm.startPrank(user);
        tokenIn.approve(address(bank), depositAmount);

        // 1. This event is emitted FIRST
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulBalanceUpdate(
            user,
            address(tokenIn),
            depositAmount
        );

        // 2. This event is emitted SECOND
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulDeposit(
            user,
            address(tokenIn),
            depositAmount,
            expectedUsdValue
        );

        bank.depositERC20(address(tokenIn), depositAmount);
        vm.stopPrank();

        assertEq(bank.getBalance(user, address(tokenIn)), depositAmount);
        assertEq(bank.s_totalDepositsUSD(), expectedUsdValue);
        assertEq(tokenIn.balanceOf(address(bank)), depositAmount);
    }

    function testRevert_DepositERC20_NoEthToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_UseDepositEth.selector,
                user,
                1 ether
            )
        );
        vm.prank(user);
        bank.depositERC20(address(0), 1 ether);
    }

    function testRevert_DepositERC20_FailedTransfer() public {
        uint256 depositAmount = 10_000e18;
        tokenIn.mint(user, depositAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(bank), // spender
                0, // allowance
                depositAmount // value
            )
        );
        vm.prank(user);
        bank.depositERC20(address(tokenIn), depositAmount);
    }

    /*///////////////////////////////////
    //     extractFromAccount Tests
    //////////////////////////////////*/

    function test_ExtractETH_Success() public {
        uint256 depositAmount = 5 ether;
        uint256 extractAmount = 2 ether;
        uint256 newBalance = depositAmount - extractAmount;

        // Deposit setup
        vm.deal(user, depositAmount);
        vm.prank(user);
        bank.depositETH{value: depositAmount}();
        vm.stopPrank(); // Stop prank after setup

        uint256 userBalanceBefore = user.balance;

        // 1. This event is emitted FIRST
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulBalanceUpdate(
            user,
            address(0),
            newBalance
        );

        // 2. This event is emitted SECOND
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulExtract(
            user,
            address(0),
            extractAmount
        );

        vm.prank(user);
        bank.extractFromAccount(address(0), extractAmount);
        vm.stopPrank();

        assertEq(bank.getBalance(user, address(0)), newBalance);
        assertEq(user.balance, userBalanceBefore + extractAmount);
    }

    function test_ExtractERC20_Success() public {
        uint256 depositAmount = 10_000e18;
        uint256 extractAmount = 4_000e18;
        uint256 newBalance = depositAmount - extractAmount;

        // Deposit setup
        tokenIn.mint(user, depositAmount);
        vm.startPrank(user);
        tokenIn.approve(address(bank), depositAmount);
        bank.depositERC20(address(tokenIn), depositAmount);
        vm.stopPrank();

        uint256 userBalanceBefore = tokenIn.balanceOf(user);

        // 1. This event is emitted FIRST
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulBalanceUpdate(
            user,
            address(tokenIn),
            newBalance
        );

        // 2. This event is emitted SECOND
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.KipuBank_SuccessfulExtract(
            user,
            address(tokenIn),
            extractAmount
        );

        vm.prank(user);
        bank.extractFromAccount(address(tokenIn), extractAmount);
        vm.stopPrank();

        assertEq(bank.getBalance(user, address(tokenIn)), newBalance);
        assertEq(tokenIn.balanceOf(user), userBalanceBefore + extractAmount);
    }

    function testRevert_Extract_InsufficientBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_InsufficientBalance.selector,
                user,
                1 ether
            )
        );
        vm.prank(user);
        bank.extractFromAccount(address(0), 1 ether);
    }

    function testRevert_Extract_LimitExceeded() public {
        uint256 depositAmount = 5 ether;
        uint256 extractAmount = 4 ether;

        // Deposit setup
        vm.deal(user, depositAmount);
        vm.prank(user);
        bank.depositETH{value: depositAmount}();
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBankV3.KipuBank_LimitExceeded.selector,
                user,
                extractAmount
            )
        );
        vm.prank(user);
        bank.extractFromAccount(address(0), extractAmount);
    }
}
