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
error PresaleNotStarted();
error PresaleNotFinished();
error PresaleTimeFinished();
error PresaleSoldOut();
error NoTokensToClaim();

/*
* Phase 1) 2M tokens at 0,005$
* Phase 2) 3M tokens at 0,010$
* Phase 3) 5M tokens at 0,015$
* Each phase lasts 5 days (presale lasts 15 days from start to end)
* All the users have to wait for the global presale to end (15 days) and then are available to claim their tokens. Even if all the tokens are sold before the 15 days
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
    Phase[PRESALE_PHASES] public phases;

    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public userBalances;

    event TokensPurchased(address indexed buyer, address indexed paymentToken, uint256 amountIn, uint256 tokensOut, uint256 phase);
    event TokensClaimed(address indexed user, uint256 amount);

    /**
     * @notice Deploys the presale and configures its tokens, funds receiver, and phases.
     * @dev Each phase must have a positive token amount, increasing price, and end time.
     *      The sum of all phase amounts must equal the maximum number of tokens for sale.
     * @param usdc_ Address of the USDC contract accepted for purchases.
     * @param usdt_ Address of the USDT contract accepted for purchases.
     * @param presaleTokenAddress_ Address of the token that will be distributed to buyers.
     * @param fundsReceiver_ Address that will receive purchase payments.
     * @param startingPeriod_ Unix timestamp when the presale starts.
     * @param phases_ Phase configuration: token amount, price, and end time.
     */
    constructor(
        address usdc_,
        address usdt_,
        address presaleTokenAddress_,
        address fundsReceiver_,
        uint256 startingPeriod_,
        Phase[PRESALE_PHASES] memory phases_
    ) Ownable(msg.sender) {
        if (
            usdc_ == address(0) || usdt_ == address(0) || fundsReceiver_ == address(0)
                || presaleTokenAddress_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (usdc_ == usdt_) revert SameStablecoin();

        uint256 totalAmount;

        for (uint256 i = 0; i < PRESALE_PHASES; i++) {
            Phase memory phase = phases_[i];

            if (i == 0 && phase.endTime <= startingPeriod_) revert InvalidPhaseEndTime(i);
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
        STARTING_PERIOD = startingPeriod_;
        ENDING_PERIOD = phases_[PRESALE_PHASES - 1].endTime;
    }

    /**
     * @notice Purchases presale tokens using USDC or USDT.
     * @dev The buyer must have approved the payment amount and must not be blacklisted.
     *      Purchased tokens accrue for claiming after the entire presale has ended.
     * @param tokenUsedToBuy_ Address of the payment token (USDC or USDT).
     * @param amountToPay_ Payment amount, expressed using the payment token's decimals.
     */
    function buyWithStables(address tokenUsedToBuy_, uint256 amountToPay_) external {
        require(!isBlacklisted[msg.sender], "You are not allowed to buy this presale");
        require(tokenUsedToBuy_ == USDT || tokenUsedToBuy_ == USDC, "Please use USDC or USDT to buy");

        (uint256 currentPhase, uint256 accumulatedTokens) = calculateCurrentPhase();
        uint256 tokenDecimals = IERC20Metadata(tokenUsedToBuy_).decimals();
        uint256 tokenAmountToReceive =
            amountToPay_ * 10 ** (18 - tokenDecimals) * PRICE_USD_DECIMALS / phases[currentPhase].price; // 18 decimals

        // CEI Pattern
        require(totalSold + tokenAmountToReceive <= accumulatedTokens, "Exceeded limit to buy in this phase");
        totalSold += tokenAmountToReceive;
        userBalances[msg.sender] += tokenAmountToReceive;
        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, fundsReceiver, amountToPay_);
        emit TokensPurchased(msg.sender, tokenUsedToBuy_, amountToPay_, tokenAmountToReceive, currentPhase);
    }

    /**
     * @notice Claims purchased tokens after the presale has ended.
     * @dev Sets the pending balance to zero before transferring to prevent duplicate claims.
     */
    function claim() external {
        if (block.timestamp < ENDING_PERIOD) revert PresaleNotFinished();
        uint256 tokensToClaim = userBalances[msg.sender];
        if (tokensToClaim == 0) revert NoTokensToClaim();
        userBalances[msg.sender] = 0;
        IERC20(PRESALE_TOKEN_ADDRESS).safeTransfer(msg.sender, tokensToClaim);
        emit TokensClaimed(msg.sender, tokensToClaim);
    }

    /**
     * @notice Calculates the active phase and the cumulative token limit available through that phase.
     * @dev Reverts if the presale has not started, has ended, or has no tokens remaining.
     * @return phaseIndex Index of the active phase, starting from zero.
     * @return accumulatedTokens Maximum cumulative number of tokens available through this phase.
     */
    function calculateCurrentPhase() public view returns (uint256, uint256) {
        uint256 currentTime = block.timestamp;
        if (currentTime < STARTING_PERIOD) revert PresaleNotStarted();
        if (currentTime >= ENDING_PERIOD) revert PresaleTimeFinished();
        uint256 currentTokensSold = totalSold;
        uint256 accumulatedTokens = 0;
        for (uint256 i = 0; i < PRESALE_PHASES; i++) {
            Phase memory phase = phases[i];
            accumulatedTokens += phase.amount;
            if (currentTime < phase.endTime && currentTokensSold < accumulatedTokens) {
                return (i, accumulatedTokens);
            }
        }
        revert PresaleSoldOut();
    }

    // ---- ADMIN FUNCTIONS ----
    /**
     * @notice Adds an address to the blacklist, preventing it from purchasing in the presale.
     * @dev Can only be called by the contract owner.
     * @param user_ Address to add to the blacklist.
     */
    function blacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = true;
    }

    /**
     * @notice Removes an address from the blacklist.
     * @dev Can only be called by the contract owner.
     * @param user_ Address to remove from the blacklist.
     */
    function removeBlacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = false;
    }

    /**
     * @notice Withdraws an amount of an ERC-20 token from the contract to the owner.
     * @dev Can only be called by the contract owner.
     * @param tokenAddress_ Address of the ERC-20 token to withdraw.
     * @param amount_ Amount of tokens to withdraw, expressed in the token's smallest units.
     */
    function emergencyERC20Withdraw(address tokenAddress_, uint256 amount_) external onlyOwner {
        IERC20(tokenAddress_).safeTransfer(msg.sender, amount_);
    }

    /**
     * @notice Withdraws all ETH held by the contract to the owner.
     * @dev Can only be called by the contract owner and reverts if the transfer fails.
     */
    function emergencyEthWithdraw() external onlyOwner {
        uint256 balance_ = address(this).balance;
        (bool success,) = msg.sender.call{value: balance_}("");
        require(success, "ETH withdraw failed");
    }
}
