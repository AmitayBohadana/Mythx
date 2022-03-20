//"SPDX-License-Identifier: UNLICENSED"
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract LinearVestingFarm is OwnableUpgradeable, ReentrancyGuardUpgradeable{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info about each user
    struct Reward{
        address user;
        uint256 amount;
    }

    // Time when farm is starting to vest
    uint256 public startTime;
    // Time when farm is finished with vesting
    uint256 public endTime;
    // (endTime - startTime)
    uint256 public farmDurationSec;
    // Mapping with reward amount,
    // that should be paid out for all users
    mapping(address => uint256) public totalUserRewards;
    // Total amount of reward token
    uint256 public totalRewards;
    // Remaining rewards to payout
    uint256 public totalRewardsPendingBalance;
    // Mapping with reward amount,
    // that are paid out for all users
    mapping(address => uint256) public totalUserPayouts;
    // Address of token that is vested
    IERC20 public vestedToken;
    // Activation of farm
    bool public isActive;
    // Array of users
    address[] public participants;
    // Mapping of users id
    mapping(address => uint256) public usersId;
    // Number of users
    uint256 public noOfUsers;
    // Is farm user
    mapping(address => bool) public isFarmUser;
    // Linear vesting farm implementation
    address public farmImplementation;
    // Total rewards withdrawn
    uint256 totalWithdrawn;
    // Is user removed
    mapping(address => bool) public isRemoved;
    // Claim percentage
    uint256 public earlyClaimAvailablePercent;

    // Events
    event RewardPaid(
        address indexed user,
        uint256 indexed reward
    );
    event EndTimeSet(
        uint256 indexed endTime
    );
    event EmergencyWithdraw(
        address indexed _asset,
        uint256 indexed _amount,
        address indexed _owner
    );
    event UserRemoved(
        address indexed user,
        uint256 indexed totalRewards,
        uint256 indexed totalPayouts,
        uint256 balanceWhenRemoved
    );
    event LeftOverTokensRemoved(
        uint256 indexed amountWithdrawn,
        address indexed collector,
        uint256 indexed balance,
        uint256 pendingAmount
    );
    event StartFarm(bool indexed _isActive);
    event PauseFarm(bool indexed _isActive);
    event RewardPaidWithBurn(
        address indexed user,
        uint256 indexed rewardPaid,
        uint256 indexed rewardBurned
    );

    function initialize(
        address _vestedToken,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _earlyClaimAvailablePer,
        address _farmImplementation
    )
        external
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();

        require(
            _vestedToken != address(0x0),
            "Tokens address can not be 0x0"
        );
        require(
            _startTime >= block.timestamp,
            "Start time can not be in the past"
        );
        require(
            _endTime > _startTime,
            "End time can not be before start time"
        );
        require(
            _earlyClaimAvailablePer >= 0 && _earlyClaimAvailablePer <= 100,
            "Claim percentage should be above 0 and below 100"
        );

        vestedToken = IERC20(_vestedToken);
        startTime = _startTime;
        endTime = _endTime;
        farmDurationSec = endTime - startTime;
        isActive = false;
        farmImplementation = _farmImplementation;
        earlyClaimAvailablePercent = _earlyClaimAvailablePer;
    }

    // All state changing functions

    /**
     * @notice function is adding users into the array
     *
     * @dev this is function that creates data,
     * to work with
     *
     * @param _rewards - array of [userAddress, userAmount]
     */
    function addUsersRewards(
        Reward[] calldata _rewards
    )
        external
        onlyOwner
    {
        require(
            !isActive,
            "Farm is activated you can not add more users"
        );

        for(uint256 i = 0 ; i < _rewards.length; i++){
            Reward calldata r = _rewards[i];
            if(r.amount > 0 && !isFarmUser[r.user]){
                totalRewards = totalRewards
                    .add(r.amount)
                    .sub(totalUserRewards[r.user]);
                totalRewardsPendingBalance = totalRewardsPendingBalance
                    .add(r.amount)
                    .sub(totalUserRewards[r.user]);
                usersId[r.user] = noOfUsers;
                noOfUsers++;
                participants.push(r.user);
                totalUserRewards[r.user] = r.amount;
                isFarmUser[r.user] = true;
            }
        }
    }

    /**
     * @notice function is removing user from farm
     *
     * @param user - address of user,
     * that needs to be removed
     */
    function removeUser(
        address user
    )
        external
        onlyOwner
    {
        require(
            !isActive,
            "Linear farm is activated, you can't remove user"
        );
        require(
            totalUserRewards[user] > totalUserPayouts[user],
            "User can not be kicked, he is already paid"
        );

        uint256 removedUserPendingBalance =
            totalUserRewards[user].sub(totalUserPayouts[user]);
        // update totalRewards
        totalRewards = totalRewards.sub(removedUserPendingBalance);
        // update totalRewardsPendingBalance
        totalRewardsPendingBalance = totalRewardsPendingBalance.sub(removedUserPendingBalance);
        // remove him
        totalUserRewards[user] = totalUserPayouts[user];
        isRemoved[user] = true;

        emit UserRemoved(
            user,
            totalUserRewards[user],
            totalUserPayouts[user],
            removedUserPendingBalance
        );
    }

    /**
     * @notice function is funding the farm
     */
    function fundAndOrActivate()
        external
        onlyOwner
    {
        if(totalRewardsPendingBalance > vestedToken.balanceOf(address(this))) {
            uint256 amount =
                totalRewardsPendingBalance - vestedToken.balanceOf(address(this));

            vestedToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                amount
            );
        }

        require(
            vestedToken.balanceOf(address(this)) >= totalRewardsPendingBalance,
            "There is not enough money to payout all users"
        );

        isActive = true;
        emit StartFarm(isActive);
    }

    /**
     * @notice function is stopping farm
     */
    function pauseFarm()
        external
        onlyOwner
    {
        isActive = false;
        emit PauseFarm(isActive);
    }

    // All setter functions

    /**
     * @notice function is setting new end time
     *
     * @param _endTime - unix timestamp
     */
    function setEndTime(
        uint256 _endTime
    )
        external
        onlyOwner
    {
        require(
            _endTime > block.timestamp,
            "End time can not be in the past"
        );

        endTime = _endTime;
        farmDurationSec = endTime - startTime;
        emit EndTimeSet(endTime);
    }

    // All view functions

    /**
     * @notice function is getting last rewardTime
     *
     * @return unix timestamp
     */
    function lastTimeRewardApplicable()
        public
        view
        returns(uint256)
    {
        return block.timestamp < endTime ? block.timestamp : endTime;
    }

    /**
     * @notice returns total amount,
     * that has been rewarded to the user to the current time
     *
     * @param account - user address
     *
     * @return paid rewards
     */
    function earned(
        address account
    )
        public
        view
        returns(uint256)
    {
        return totalUserRewards[account]
            .mul(lastTimeRewardApplicable() - startTime)
            .div(farmDurationSec);
    }

    /**
     * @notice returns total rewards,
     * that are locked,unlocked and withdrawn
     *
     * @return totalRewardsLocked,totalRewardsUnlocked
     * and totalWithdrawn
     */
    function getTotalRewardsLockedUnlockedAndWithdrawn()
        external
        view
        returns(uint256, uint256, uint256)
    {
        uint256 totalRewardsUnlocked = totalRewards
            .mul(lastTimeRewardApplicable() - startTime)
            .div(farmDurationSec);
        uint256 totalRewardsLocked = totalRewards - totalRewardsUnlocked;
        return (totalRewardsLocked, totalRewardsUnlocked, totalWithdrawn);
    }

    /**
     * @notice function is returning info about assets of user
     *
     * @param user - address of user
     *
     * @return amountEarned - available to claim at this moment
     * @return totalLeftLockedForUser - how many is locked
     * @return claimAmountFromLocked -  how much can be withdrawn from locked
     * @return burnAmount - how much will be burnt
     */
    function getInfoOfUser(address user)
        public
        view
        returns(uint256, uint256, uint256, uint256)
    {
        uint256 amountEarned = _withdrawCalculation(user);
        uint256 totalLeftLockedForUser = totalUserRewards[user]
            .sub(totalUserPayouts[user])
            .sub(amountEarned);
        uint256 burnPercent = 100 - earlyClaimAvailablePercent;
        uint256 claimAmountFromLocked = totalLeftLockedForUser
            .mul(earlyClaimAvailablePercent).div(100);
        uint256 burnAmount = totalLeftLockedForUser.mul(burnPercent).div(100);

        return(
            amountEarned,
            totalLeftLockedForUser,
            claimAmountFromLocked,
            burnAmount
        );
    }

    // All withdraw functions

    /**
     * @notice function is calculating available amount for withdrawal
     */
    function _withdrawCalculation(address user)
        internal
        view
        returns (uint256)
    {
        uint256 _earned = earned(address(user));
        require(
            _earned <= totalUserRewards[address(user)],
            "Earned is more than reward!"
        );
        require(
            _earned > totalUserPayouts[address(user)],
            "Earned is less or equal to already paid!"
        );

        uint256 amountEarned = _earned
            .sub(totalUserPayouts[address(user)]);

        return amountEarned;
    }

    /**
     * @notice function is allowing user to withdraw his rewards,
     * and to finish with vesting
     */
    function claimWholeRewards()
        external
        nonReentrant
    {
        require(
            earlyClaimAvailablePercent != 0,
            "This option is not available on this farm"
        );
        require(
            block.timestamp > startTime,
            "Farm has not started yet"
        );
        require(
            isActive,
            "Linear Vesting Farm is not activated"
        );
        require(
            totalUserPayouts[address(msg.sender)] < totalUserRewards[address(msg.sender)],
            "User has been paid out"
        );

        uint256 amountEarned;
        uint256 totalLeftLockedForUser;
        uint256 claimAmountFromLocked;
        uint256 burnAmount;

        (
            amountEarned,
            totalLeftLockedForUser,
            claimAmountFromLocked,
            burnAmount
        ) = getInfoOfUser(address(msg.sender));

        if (amountEarned > 0) {
            amountEarned = amountEarned.add(claimAmountFromLocked);
            totalUserPayouts[address(msg.sender)] = totalUserRewards[address(msg.sender)];

            totalRewardsPendingBalance = totalRewardsPendingBalance
                .sub(amountEarned + burnAmount);
            vestedToken.safeTransfer(address(msg.sender), amountEarned);
            vestedToken.safeTransfer(address(1), burnAmount);
            emit RewardPaidWithBurn(
                address(msg.sender),
                amountEarned,
                burnAmount
            );

            totalWithdrawn += (amountEarned + totalLeftLockedForUser);
        }
    }

    /**
     * @notice function is paying users their rewards back
     */
    function withdraw()
        external
        nonReentrant
    {
        require(
            block.timestamp > startTime,
            "Farm has not started yet"
        );
        require(
            isActive,
            "Linear Vesting Farm is not activated"
        );
        require(
            totalUserPayouts[address(msg.sender)] < totalUserRewards[address(msg.sender)],
            "User has been paid out"
        );

        uint256 rewardAmount = _withdrawCalculation(address(msg.sender));

        if (rewardAmount > 0) {
            totalUserPayouts[address(msg.sender)] += rewardAmount;
            totalRewardsPendingBalance -= rewardAmount;
            vestedToken.safeTransfer(address(msg.sender), rewardAmount);
            emit RewardPaid(address(msg.sender), rewardAmount);

            totalWithdrawn += rewardAmount;
        }
    }

    /**
     * @notice function is collecting,
     * superfluous rewards
     *
     * @param collector - address of client
     */
    function removeLeftOverRewards(
        address collector
    )
        external
        onlyOwner
    {
        require(
            block.timestamp > endTime,
            "Farm is not finished yet"
        );
        require(
            vestedToken.balanceOf(address(this)) > totalRewardsPendingBalance,
            "There is no superfluous tokens on factory"
        );

        uint256 withdrawnAmount =
            vestedToken.balanceOf(address(this)).sub(totalRewardsPendingBalance);

        vestedToken.safeTransfer(collector, withdrawnAmount);

        emit LeftOverTokensRemoved(
            withdrawnAmount,
            collector,
            vestedToken.balanceOf(address(this)),
            totalRewardsPendingBalance
        );
    }

    /**
     * @notice function in case of emergency
     * is withdrawing on account of factory
     *
     * @param asset - address of token
     * @param collector - address of congress
     */
    function emergencyAssetsWithdrawal(
        address asset,
        address collector
    )
        external
        onlyOwner
    {
        require(
            !isActive,
            "Farm is active you can't emergency withdraw"
        );
        require(
            asset != address(0x0),
            "Address of token can not be 0x0 address"
        );
        require(
            collector != address(0x0),
            "Collector can not be 0x0 address"
        );

        IERC20 token = IERC20(asset);
        uint256 amount = token.balanceOf((address(this)));
        token.safeTransfer(collector, token.balanceOf((address(this))));
        emit EmergencyWithdraw(asset, amount, msg.sender);
    }
}