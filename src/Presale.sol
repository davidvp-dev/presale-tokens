// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IAggregator} from "./interfaces/IAggregator.sol";

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
error AlreadyFundedFromTreasury();
error AlreadyWithdrawnRemainingTokens();

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
        uint128 price; // USD 6 decimals (0,005$ = 5_000)
        uint64 endTime; // timestamp Unix
    }

    address public immutable USDC;
    address public immutable USDT;
    address public immutable PRESALE_TOKEN;
    address public immutable TREASURY;
    address public immutable DATA_FEED_ADDRESS;
    uint8 public immutable DATA_FEED_DECIMALS;
    uint256 public immutable STARTING_PERIOD;
    uint256 public immutable ENDING_PERIOD;
    uint256 public immutable PRESALE_TOKEN_DECIMALS;
    uint256 public constant MAX_TOKENS_FOR_SALE = 10_000_000e18; // 10M tokens with 18 decimals
    uint256 public constant MIN_BUY_AMOUNT = 10e6; // 10$ min amount
    uint256 public constant PRICE_DECIMALS = 6;
    uint256 public constant ETH_DECIMALS = 18; // 1 ETH = 1e18 wei
    uint256 public constant ETH_PRICE_DECIMALS = 18; // scale of getEtherPrice()
    uint8 public constant PRESALE_PHASES = 3;

    address public fundsReceiver;
    uint256 public totalSold;
    Phase[PRESALE_PHASES] public phases;
    bool public fundedFromTreasury = false;
    bool public tokensRemaining = false;

    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public userBalances;

    event TokensPurchased(
        address indexed buyer, address indexed paymentToken, uint256 amountIn, uint256 tokensOut, uint256 phase
    );
    event TokensClaimed(address indexed user, uint256 amount);
    event UserBlacklisted(address indexed user);
    event UserRemovedFromBlacklist(address indexed user);
    event PresaleFundedFromTreasury(uint256 amount);
    event FundsReceiverUpdated(address indexed newFundsReceiver);
    event WithdrawnRemainingTokens(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    /**
     * @notice Deploys the presale and configures its tokens, funds receiver, and phases.
     * @dev Each phase must have a positive token amount, increasing price, and end time.
     *      The sum of all phase amounts must equal the maximum number of tokens for sale.
     * @param usdc_ Address of the USDC contract accepted for purchases.
     * @param usdt_ Address of the USDT contract accepted for purchases.
     * @param presaleTokenAddress_ Address of the token that will be distributed to buyers.
     * @param treasury_ Address holding the presale token allocation.
     * @param fundsReceiver_ Address that will receive purchase payments.
     * @param dataFeedAddress_ Address of the ETH/USD price feed.
     * @param startingPeriod_ Unix timestamp when the presale starts.
     * @param phases_ Phase configuration: token amount, price, and end time.
     */
    constructor(
        address usdc_,
        address usdt_,
        address presaleTokenAddress_,
        address treasury_,
        address fundsReceiver_,
        address dataFeedAddress_,
        uint256 startingPeriod_,
        Phase[PRESALE_PHASES] memory phases_
    ) Ownable(msg.sender) {
        if (
            usdc_ == address(0) || usdt_ == address(0) || fundsReceiver_ == address(0)
                || presaleTokenAddress_ == address(0) || treasury_ == address(0) || dataFeedAddress_ == address(0)
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

        fundsReceiver = fundsReceiver_;
        USDC = usdc_;
        USDT = usdt_;
        PRESALE_TOKEN = presaleTokenAddress_;
        PRESALE_TOKEN_DECIMALS = IERC20Metadata(PRESALE_TOKEN).decimals();
        TREASURY = treasury_;
        STARTING_PERIOD = startingPeriod_;
        ENDING_PERIOD = phases_[PRESALE_PHASES - 1].endTime;
        DATA_FEED_ADDRESS = dataFeedAddress_;
        DATA_FEED_DECIMALS = IAggregator(DATA_FEED_ADDRESS).decimals();
    }

    /**
     * @notice Buys presale tokens by paying with USDC or USDT.
     * @dev The buyer must have approved the payment amount, not be blacklisted,
     *      and the purchase must remain within the active phase token cap.
     *      Tokens are accumulated in the user's balance and can be claimed after the presale ends.
     * @param tokenUsedToBuy_ Address of the stablecoin used for payment: USDC or USDT.
     * @param amountToPay_ Payment amount in the stablecoin's smallest unit.
     */
    function buyWithStables(address tokenUsedToBuy_, uint256 amountToPay_) external {
        require(fundedFromTreasury, "The presale is not active yet");
        require(!isBlacklisted[msg.sender], "You are not allowed to buy this presale");
        require(tokenUsedToBuy_ == USDT || tokenUsedToBuy_ == USDC, "Please use USDC or USDT to buy");
        uint256 tokenDecimals = IERC20Metadata(tokenUsedToBuy_).decimals();
        //amountToPay has X decimals and MIN_BUY_AMOUNT has 6 decimals
        //we can either normalize amountToPay to 6 decimals, or MIN_BUY_AMOUNT to X decimals
        //its better the 2nd way, so there's nothing lost in the division
        require(
            amountToPay_ >= (MIN_BUY_AMOUNT * 10 ** (tokenDecimals - PRICE_DECIMALS)), "Amount must be 10$ or greater"
        );

        (uint256 currentPhase, uint256 accumulatedTokens) = calculateCurrentPhase();
        uint256 tokenAmountToReceive = amountToPay_ * 10 ** (PRESALE_TOKEN_DECIMALS - tokenDecimals) * 10
            ** PRICE_DECIMALS / phases[currentPhase].price;
        require(tokenAmountToReceive > 0, "The calculated tokens to receive is 0");

        // CEI Pattern
        require(totalSold + tokenAmountToReceive <= accumulatedTokens, "Exceeded limit to buy in this phase");
        totalSold += tokenAmountToReceive;
        userBalances[msg.sender] += tokenAmountToReceive;
        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, fundsReceiver, amountToPay_);
        emit TokensPurchased(msg.sender, tokenUsedToBuy_, amountToPay_, tokenAmountToReceive, currentPhase);
    }

    /**
     * @notice Buys presale tokens by paying with ETH.
     * @dev The presale must be funded, the buyer must not be blacklisted, and the ETH value must meet the minimum purchase.
     *      The ETH payment is forwarded to the funds receiver, and purchased tokens can be claimed after the presale ends.
     */
    function buyWithEther() external payable {
        require(fundedFromTreasury, "The presale is not active yet");
        require(!isBlacklisted[msg.sender], "You are not allowed to buy this presale");
        uint256 usdValue = msg.value * getEtherPrice() / (10 ** ETH_DECIMALS);
        require(
            usdValue >= (MIN_BUY_AMOUNT * 10 ** (ETH_PRICE_DECIMALS - PRICE_DECIMALS)), "Amount must be 10$ or greater"
        );

        (uint256 currentPhase, uint256 accumulatedTokens) = calculateCurrentPhase();
        uint256 tokenAmountToReceive = usdValue * 10 ** (PRESALE_TOKEN_DECIMALS - ETH_PRICE_DECIMALS) * 10
            ** PRICE_DECIMALS / phases[currentPhase].price;
        require(tokenAmountToReceive > 0, "The calculated tokens to receive is 0");

        // CEI Pattern
        require(totalSold + tokenAmountToReceive <= accumulatedTokens, "Exceeded limit to buy in this phase");
        totalSold += tokenAmountToReceive;
        userBalances[msg.sender] += tokenAmountToReceive;
        (bool success,) = fundsReceiver.call{value: msg.value}("");
        require(success, "Error sending ETH to the funds receiver");
        emit TokensPurchased(msg.sender, address(0), msg.value, tokenAmountToReceive, currentPhase);
    }

    /**
     * @notice Claims all tokens bought by the caller after the presale ends.
     * @dev Reverts until the full presale schedule has completed. The pending balance is cleared
     *      before the transfer to prevent duplicate claims and the call reverts if no tokens are available.
     */
    function claim() external {
        if (block.timestamp < ENDING_PERIOD) revert PresaleNotFinished();
        uint256 tokensToClaim = userBalances[msg.sender];
        if (tokensToClaim == 0) revert NoTokensToClaim();
        userBalances[msg.sender] = 0;
        IERC20(PRESALE_TOKEN).safeTransfer(msg.sender, tokensToClaim);
        emit TokensClaimed(msg.sender, tokensToClaim);
    }

    // ---- ADMIN FUNCTIONS ----
    /**
     * @notice Adds an address to the blacklist, preventing it from purchasing in the presale.
     * @dev Can only be called by the contract owner.
     * @param user_ Address to add to the blacklist.
     */
    function blacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = true;
        emit UserBlacklisted(user_);
    }

    /**
     * @notice Removes an address from the blacklist.
     * @dev Can only be called by the contract owner.
     * @param user_ Address to remove from the blacklist.
     */
    function removeBlacklist(address user_) external onlyOwner {
        isBlacklisted[user_] = false;
        emit UserRemovedFromBlacklist(user_);
    }

    /**
     * @notice Withdraws an amount of an ERC-20 token from the contract to the owner.
     * @dev Can only be called by the contract owner.
     * @param tokenAddress_ Address of the ERC-20 token to withdraw.
     * @param amount_ Amount of tokens to withdraw, expressed in the token's smallest units.
     */
    function emergencyERC20Withdraw(address tokenAddress_, uint256 amount_) external onlyOwner {
        require(tokenAddress_ != PRESALE_TOKEN, "Can't withdraw presale tokens");
        IERC20(tokenAddress_).safeTransfer(fundsReceiver, amount_);
        emit EmergencyWithdraw(tokenAddress_, amount_);
    }

    /**
     * @notice Withdraws all ETH held by the contract to the configured funds receiver.
     * @dev Can only be called by the contract owner. The transfer is reverted if the call fails.
     */
    function emergencyEthWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success,) = fundsReceiver.call{value: balance}("");
        require(success, "ETH withdraw failed");
        emit EmergencyWithdraw(address(0), balance);
    }

    /**
     * @notice Sends unsold presale tokens to the funds receiver after the sale ends.
     * @dev Can only be called by the owner once the presale has completed.
     *      Reverts if all tokens were already sold or if no tokens remain to withdraw.
     */
    function withdrawRemainingPresaleTokens() external onlyOwner {
        if (!tokensRemaining) {
            if (block.timestamp < ENDING_PERIOD) revert PresaleNotFinished();
            uint256 remainingAmount = MAX_TOKENS_FOR_SALE - totalSold;
            if (remainingAmount == 0) revert PresaleSoldOut();
            tokensRemaining = true;
            IERC20(PRESALE_TOKEN).safeTransfer(TREASURY, remainingAmount);
            emit WithdrawnRemainingTokens(TREASURY, remainingAmount);
        } else {
            revert AlreadyWithdrawnRemainingTokens();
        }
    }

    /**
     * @notice Transfers the presale token supply from the treasury to this contract.
     * @dev Can only be called by the owner to fund the presale with the full token allocation.
     */
    function pullPresaleTokensFromTreasury() external onlyOwner {
        if (!fundedFromTreasury) {
            fundedFromTreasury = true;
            IERC20(PRESALE_TOKEN).safeTransferFrom(TREASURY, address(this), MAX_TOKENS_FOR_SALE);
            emit PresaleFundedFromTreasury(MAX_TOKENS_FOR_SALE);
        } else {
            revert AlreadyFundedFromTreasury();
        }
    }

    /**
     * @notice Updates the address that receives funds and remaining token withdrawals.
     * @dev Can only be called by the owner. The new receiver must not be the zero address.
     * @param newFundsReceiver_ The new address to receive stablecoin payments and emergency withdrawals.
     */
    function updateFundsReceiver(address newFundsReceiver_) external onlyOwner {
        if (newFundsReceiver_ == address(0)) revert ZeroAddress();
        fundsReceiver = newFundsReceiver_;
        emit FundsReceiverUpdated(newFundsReceiver_);
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

    /**
     * @notice Returns the current ETH price from the configured price feed.
     * @dev The returned price uses 18 decimals by default; this scale is configurable through ETH_PRICE_DECIMALS.
     * @return etherPrice ETH price with ETH_PRICE_DECIMALS decimals.
     */
    function getEtherPrice() public view returns (uint256) {
        (, int256 etherPrice,,,) = IAggregator(DATA_FEED_ADDRESS).latestRoundData();
        require(etherPrice > 0, "Invalid price received from the Price Feeds");

        uint256 uintEtherPrice = SafeCast.toUint256(etherPrice);
        uintEtherPrice = uintEtherPrice * (10 ** ETH_PRICE_DECIMALS) / (10 ** DATA_FEED_DECIMALS);
        return uintEtherPrice;
    }
}
