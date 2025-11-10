// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice A standard ERC20 mock with a public mint function.
 * @dev This version is compatible with OpenZeppelin v5.x.
 * It sets the decimals by overriding the `decimals()` function.
 */
contract MockERC20 is ERC20 {
    /**
     * @dev We store the decimals in a state variable.
     */
    uint8 private _decimals;

    /**
     * @notice Constructor for the mock token.
     * @param name The name of the token (e.g., "USD Coin").
     * @param symbol The symbol of the token (e.g., "USDC").
     * @param decimals_ The number of decimals (e.g., 6).
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    )
        // The ERC20 constructor now only takes name and symbol
        ERC20(name, symbol)
    {
        _decimals = decimals_;
    }

    /**
     * @notice Overrides the base `decimals` function to return our
     * custom value instead of the default 18.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mints a new supply of tokens to an address.
     * @param to The address to receive the tokens.
     * @param amount The quantity of tokens to mint.
     */
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
