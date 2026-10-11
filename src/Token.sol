// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @notice ERC-20 token that mints its entire supply to the treasury.
 * @dev The total supply is 50 million tokens, all minted to the treasury at deployment.
 *      Of those 50 million tokens, 10 million are intended for the presale and must be
 *      transferred directly from the treasury to Presale.sol.
 */
contract Token is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 50_000_000e18;
    address public immutable TREASURY;

    /**
     * @notice Deploys the token and mints the full supply to the treasury.
     * @dev The constructor does not transfer tokens to the presale. The treasury must
     *      transfer 10 million tokens directly to Presale.sol for the presale allocation.
     * @param name_ ERC-20 token name.
     * @param symbol_ ERC-20 token symbol.
     * @param treasury_ Address that receives the full 50 million token supply.
     */
    constructor(string memory name_, string memory symbol_, address treasury_) ERC20(name_, symbol_) {
        TREASURY = treasury_;
        _mint(TREASURY, TOTAL_SUPPLY);
    }
}
