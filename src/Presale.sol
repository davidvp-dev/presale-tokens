// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

error ZeroAddress();
error SameStablecoin();
error InvalidPhaseAmount(uint256 index);
error InvalidPhasePrice(uint256 index);
error InvalidPhaseEndTime(uint256 index);
error PhasePriceNotIncreasing(uint256 index);
error InvalidTotalPhaseAmount(uint256 total, uint256 max);

/*
* Phase 1) 2M tokens at 0,005$
* Phase 2) 3M tokens at 0,010$
* Phase 3) 5M tokens at 0,015$
* Each phase lasts 5 days (presale lasts 15 days from start to end)
* All the users have to wait for the global presale to end (15 days) and then are available to claim their tokens
* If the tokens of any phase are not sold, those are moved to the next phase
*/
contract Presale is Ownable {
    using SafeERC20 for IERC20;

    struct Phase {
        uint128 amount; // 18 decimals
        uint128 price; // USD  6 decimals (0,005$ = 5_000)
        uint64 endTime; // timestamp Unix
    }

    address public immutable USDC;
    address public immutable USDT;
    address public immutable PRESALE_TOKEN_ADDRESS;
    uint256 public immutable STARTING_PERIOD;
    uint256 public immutable ENDING_PERIOD;
    uint256 public constant MAX_TOKENS_FOR_SALE = 10_000_000e18; // 10M tokens with 18 decimals
    uint256 public constant PRICE_USD_DECIMALS = 1e6;
    uint8 public constant PRESALE_PHASES = 3;

    address public fundsReceiver;
    uint256 public totalSold;
    uint256 public currentPhase;
    Phase[PRESALE_PHASES] public phases;

    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public userBalances;

    event TokenBuy(address tokenUsedToBuy_, uint256 amount_);

    constructor(
        address usdc_,
        address usdt_,
        address presaleTokenAddress_,
        address fundsReceiver_,
        uint256 STARTING_PERIOD_,
        Phase[PRESALE_PHASES] memory phases_
    ) Ownable(msg.sender) {
        if (usdc_ == address(0) || usdt_ == address(0) || fundsReceiver_ == address(0) || presaleTokenAddress_ == address(0)) {
            revert ZeroAddress();
        }
        if (usdc_ == usdt_) revert SameStablecoin();

        uint256 totalAmount;

        for (uint256 i = 0; i < PRESALE_PHASES; i++) {
            Phase memory phase = phases_[i];

            if (i == 0 && phase.endTime <= STARTING_PERIOD_) revert InvalidPhaseEndTime(i);
            if (i > 0 && phase.endTime <= phases_[i - 1].endTime) revert InvalidPhaseEndTime(i);
            if (i == 0 && phase.price == 0) revert InvalidPhasePrice(i);
            if (i > 0 && phase.price <= phases_[i - 1].price) revert PhasePriceNotIncreasing(i);
            if (phase.amount == 0) revert InvalidPhaseAmount(i);

            totalAmount += phase.amount;
            phases[i] = phase;
        }

        if (totalAmount != MAX_TOKENS_FOR_SALE) revert InvalidTotalPhaseAmount(totalAmount, MAX_TOKENS_FOR_SALE);

        USDC = usdc_;
        USDT = usdt_;
        PRESALE_TOKEN_ADDRESS = presaleTokenAddress_;
        fundsReceiver = fundsReceiver_;
        STARTING_PERIOD = STARTING_PERIOD_;
        ENDING_PERIOD = phases_[PRESALE_PHASES - 1].endTime;
    }

    function buyWithStables(address tokenUsedToBuy_, uint256 amount_) external {
        require(!isBlacklisted[msg.sender], "You are not allowed to buy this presale");
        require(block.timestamp >= STARTING_PERIOD && block.timestamp <= ENDING_PERIOD, "Presale not available");
        require(tokenUsedToBuy_ == USDT || tokenUsedToBuy_ == USDC, "Please use USDC or USDT to buy");

        uint256 tokenDecimals_ = IERC20Metadata(tokenUsedToBuy_).decimals();
        uint256 tokenAmountToReceive = amount_ * 10 ** (18 - tokenDecimals_) * PRICE_USD_DECIMALS / phases[currentPhase].price; // 18 decimals
        checkCurrentPhase(tokenAmountToReceive);
        totalSold += tokenAmountToReceive;

        // CEI Pattern
        require(totalSold <= MAX_TOKENS_FOR_SALE, "Sold out");
        userBalances[msg.sender] += tokenAmountToReceive;
        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, fundsReceiver, tokenAmountToReceive);
        emit TokenBuy(tokenUsedToBuy_, amount_);
    }

    // ---- ADMIN FUNCTIONS ----
    function blacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = true;
    }

    function removeBlacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = false;
    }

    function emergencyERC20Withdraw(address tokenAddress_, uint256 amount_) external onlyOwner {
        IERC20(tokenAddress_).safeTransfer(msg.sender, amount_);
    }

    function emergencyEthWithdraw() external onlyOwner {
        uint256 balance_ = address(this).balance;
        (bool success,) = msg.sender.call{value: balance_}("");
        require(success, "ETH withdraw failed");
    }

    function checkCurrentPhase(uint256 amount_) private returns(uint256 phase_) {
        if ((totalSold + amount_ >= phases[currentPhase].amount || block.timestamp >= phases[currentPhase].endTime) && currentPhase < PRESALE_PHASES) {
            currentPhase ++;
            phase_ = currentPhase;
        } else {
            phase_ = currentPhase;
        }
    }
}
