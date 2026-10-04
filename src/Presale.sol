// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract Presale is Ownable {
    address public immutable USDC;
    address public immutable USDT;
    uint256 public constant TOTAL_SUPPLY = 10_000_000;

    address public fundsReceiver;
    uint256[][3] public phases;

    constructor(address usdc_, address usdt_, address fundsReceiver_, uint256[][3] phases_) Ownable(msg.sender) {
        USDC = usdc_;
        USDT = usdt_;
        fundsReceiver = fundsReceiver_;
        phases = phases_;
    }
}
