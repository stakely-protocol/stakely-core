// SPDX-License-Identifier: SEE LICENSE IN LICENSE
//       ,
//       )\
//      /  \
//     '  # '
//     ',  ,'
//       `'
//   ___          ___  __
//   )_  )   / /   )   ) )
//  (   (__ (_/  _(_  /_/

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./interfaces/ICnStaking.sol";
import "./interfaces/IUnstakingReceiver.sol";
import "./interfaces/INodeHandler.sol";

/**
 * @title NodeHandler Contract
 * @author Team Stakely
 * @notice Interacts with node to stake, unstake, get reward
 * @notice Block reward for staking KLAY accumulated in NodeHandler first,
 *         and then distributed to GC Node and NodeManager contract in proportion to the staked amount
 */
contract NodeHandler is
    INodeHandler,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using AddressUpgradeable for address payable;

    /// @notice Initial amount staked by gc
    uint256 public gcStaking;
    /// @notice Total reward sent to gc reward address
    uint256 public gcReward;
    /// @notice Total staked from protocol in connected node
    uint256 public protocolStaking;
    /// @notice Total reward accumulated for the protocol
    uint256 public protocolReward;
    /// @notice Unstaking requested amount
    uint256 public unstakingRequested;

    /// @notice GC reward address
    address public gcRewardAddress;
    /// @notice Node Manager address
    address public nodeManagerAddress;

    /// @notice Node
    ICnStaking private node;
    /// @notice Unstaking receiver that receives claimed KLAY from node
    IUnstakingReceiver private unstakingReceiver;

    /// @notice Unstaking Ids for each user
    mapping(address => mapping(uint256 => UnstakingInfo))
        public userToUnstakingData;
    /// @notice Total unstaking requests for each user
    mapping(address => uint256) public unstakeCount;
    /// @notice Total unstaking claimed for each user
    mapping(address => uint256) public claimCount;
    /// @notice true if node becomes unavailable
    bool public isDisconnected;

    ///////////////////////////////////////////////////////////////////
    //     Events
    ///////////////////////////////////////////////////////////////////

    event Staked(uint256 amount);
    event UnstakingRequested(address user, uint256 amount);
    event ClaimUnstakedSuccess(uint256 amount);
    event ClaimUnstakedFailed(uint256 amount);
    event UnstakingClaimed(address user, uint256 amount);
    event RewardClaimed(address to, uint256 amount);

    ///////////////////////////////////////////////////////////////////
    //     Initializer / Modifiers
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Initializer for upgradeable NodeHandler Contract
     */
    function initialize(
        address nodeAddress_,
        address gcRewardAddress_,
        address nodeManagerAddress_,
        address unstakingAddress_
    )
        external
        initializer
        validAddress(nodeAddress_)
        validAddress(gcRewardAddress_)
        validAddress(nodeManagerAddress_)
        validAddress(unstakingAddress_)
    {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();

        node = ICnStaking(nodeAddress_);
        gcRewardAddress = gcRewardAddress_;
        nodeManagerAddress = nodeManagerAddress_;
        unstakingReceiver = IUnstakingReceiver(unstakingAddress_);

        gcStaking = node.staking();
        protocolStaking = 0;
    }

    receive() external payable {}

    /**
     * @notice Checks if sender is node manager contract
     */
    modifier onlyNodeManager() {
        require(
            nodeManagerAddress == _msgSender(),
            "NodeHandler:: caller is not node manager"
        );
        _;
    }

    /**
     * @notice Checks if address is valid
     * @param value address to check
     */
    modifier validAddress(address value) {
        require(value != address(0), "NodeHandler:: address is zero");
        _;
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (onlyNodeManager)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Stakes klay to node
     * @dev Emits `Staking` event
     */
    function stake() external payable onlyNodeManager nonReentrant {
        uint256 amount = msg.value;
        require(amount > 0, "NodeHandler:: msg.value is zero");

        protocolStaking += amount;
        node.stakeKlay{value: amount}();
        emit Staked(amount);
    }

    /**
     * @notice Sends unstaking request to node
     * @dev Emits `UnstakingRequested` event
     * @param user address of user
     * @param amount amount to unstake
     * @return timestamp unstaking amount claimable timestamp
     */
    function unstake(address user, uint256 amount)
        external
        onlyNodeManager
        nonReentrant
        returns (uint256 timestamp)
    {
        require(amount > 0, "NodeHandler:: amount is zero");
        require(
            amount <= protocolStaking - unstakingRequested,
            "NodeHandler:: amount too large"
        );
        unstakingRequested += amount;

        timestamp = _unstake(user, amount);
    }

    /**
     * @notice Unstakes all protocol staking and disconnects the node
     */
    function unstakeForDeregister() external onlyNodeManager nonReentrant {
        unstakingRequested = protocolStaking;
        _unstake(nodeManagerAddress, protocolStaking);
        isDisconnected = true;
    }

    /**
     * @notice Claims all available unstaking requests
     * @dev Emits `ClaimUnstakedSuccess` event for each unstaking request claimed
     * @dev Emits `ClaimUnstakedFailed` event for each unstaking request whose claim window passed
     * @dev Emits `UnstakingClaimed` event for amount sent to destination
     * @param user address of unstaking requester
     * @param timeLimit within timeLimit, unstaking requests are claimed
     */
    function claimUnstaked(address user, uint256 timeLimit)
        external
        onlyNodeManager
        nonReentrant
        returns (uint256 totalClaimed, uint256 expired)
    {
        uint256 userUnstakeCount = unstakeCount[user];
        uint256 userClaimCount = claimCount[user];

        if (userClaimCount >= userUnstakeCount) return (0, 0);

        if (isDisconnected && user != nodeManagerAddress) {
            for (uint256 i = userClaimCount; i < userUnstakeCount; i++) {
                UnstakingInfo memory data = userToUnstakingData[user][i];
                if (
                    block.timestamp >= data.claimableTimestamp &&
                    timeLimit >= data.claimableTimestamp
                ) {
                    userClaimCount++;
                    expired += data.amount;
                    delete userToUnstakingData[user][i];
                } else {
                    break;
                }
            }

            claimCount[user] = userClaimCount;
            return (0, expired);
        }

        uint256 totalProcessed = 0;

        for (uint256 i = userClaimCount; i < userUnstakeCount; i++) {
            UnstakingInfo memory data = userToUnstakingData[user][i];
            if (
                block.timestamp >= data.claimableTimestamp &&
                timeLimit >= data.claimableTimestamp
            ) {
                userClaimCount++;
                uint256 id = data.id;
                delete userToUnstakingData[user][i];
                //slither-disable-next-line calls-loop
                node.withdrawApprovedStaking(id);
                //slither-disable-next-line calls-loop
                (, uint256 amount, , uint256 state) = node
                    .getApprovedStakingWithdrawalInfo(id);

                if (state == 1) {
                    // success
                    totalClaimed += amount;
                    totalProcessed += amount;
                    emit ClaimUnstakedSuccess(amount);
                } else if (state == 2) {
                    // claim window closed, need to request unstake again
                    totalProcessed += amount;
                    expired += amount;
                    emit ClaimUnstakedFailed(amount);
                }
            } else {
                break;
            }
        }

        claimCount[user] = userClaimCount;
        unstakingRequested -= totalProcessed;
        protocolStaking -= totalClaimed;
        if (totalClaimed > 0) {
            unstakingReceiver.withdraw(user);
            emit UnstakingClaimed(user, totalClaimed);
        }
    }

    /**
     * @notice Claims reward from node
     * @dev Emits `RewardClaimed` event for node manager and gc reward address
     * @return amount amount of KLAY reward sent to node manager
     */
    function claimReward()
        external
        onlyNodeManager
        nonReentrant
        returns (uint256)
    {
        uint256 amount = address(this).balance;
        //slither-disable-next-line incorrect-equality
        if (amount == 0 || totalStaking() == 0) return 0;

        // transfer reward to gc
        uint256 amountGC = 0;
        if (gcStaking >= 10**18) {
            amountGC = (amount * gcStaking) / totalStaking();
            gcReward += amountGC;
            amount -= amountGC;
            //slither-disable-next-line reentrancy-benign
            payable(gcRewardAddress).sendValue(amountGC);
            emit RewardClaimed(gcRewardAddress, amountGC);
        }

        // transfer reward to node manager
        protocolReward += amount;
        payable(nodeManagerAddress).sendValue(amount);
        emit RewardClaimed(nodeManagerAddress, amount);

        return amount;
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (onlyRole)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Updates gc staked amount based on staked total
     */
    function updateGcStakedAmount() external onlyOwner {
        gcStaking = node.staking() - protocolStaking;
    }

    /**
     * @notice Sets reward address for amount staked separately by gc
     * @param gcRewardAddress_ new reward address
     */
    function setGcRewardAddress(address gcRewardAddress_)
        external
        onlyOwner
        validAddress(gcRewardAddress_)
    {
        gcRewardAddress = gcRewardAddress_;
    }

    /**
     * @notice Sets node manager address
     * @param nodeManagerAddress_ new node manager address
     */
    function setNodeManagerAddress(address nodeManagerAddress_)
        external
        onlyOwner
        validAddress(nodeManagerAddress_)
    {
        //slither-disable-next-line events-access
        nodeManagerAddress = nodeManagerAddress_;
    }

    /**
     * @notice Sets unstaking receiver
     * @param unstakingReceiverAddress new unstaking receiver address
     */
    function setUnstakingReceiver(address unstakingReceiverAddress)
        external
        onlyOwner
        validAddress(unstakingReceiverAddress)
    {
        unstakingReceiver = IUnstakingReceiver(unstakingReceiverAddress);
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (View)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Returns address of node
     */
    function nodeAddress() external view returns (address) {
        return address(node);
    }

    /**
     * @notice Return unstaking requests not yet claimed
     * @param user address to find unstaking ids for
     */
    function getUserUnstakingCount(address user)
        external
        view
        returns (uint256)
    {
        return unstakeCount[user] - claimCount[user];
    }

    /**
     * @notice Returns reward claimable for node manager
     */

    function getClaimableReward() external view returns (uint256) {
        uint256 amount = address(this).balance;
        // slither-disable-next-line incorrect-equality
        if (amount == 0 || totalStaking() == 0) return 0;

        uint256 amountManager = amount - (amount * gcStaking) / totalStaking();
        return amountManager;
    }

    /**
     *@notice Returns total staked to node minus unstaking requested
     */
    function totalNetStaking() external view returns (uint256) {
        return protocolStaking + gcStaking - unstakingRequested;
    }

    /**
     *@notice Returns total reward earned
     */
    function totalReward() external view returns (uint256) {
        return protocolReward + gcReward;
    }

    function protocolNetStaking() external view returns (uint256) {
        return protocolStaking - unstakingRequested;
    }

    ///////////////////////////////////////////////////////////////////
    //     Public Functions
    ///////////////////////////////////////////////////////////////////

    /**
     *@notice Returns total staked to node
     */
    function totalStaking() public view returns (uint256) {
        return protocolStaking + gcStaking;
    }

    ///////////////////////////////////////////////////////////////////
    //     Private Functions
    ///////////////////////////////////////////////////////////////////

    function _unstake(address user, uint256 amount)
        private
        returns (uint256 timestamp)
    {
        uint256 id = node.withdrawalRequestCount();
        //slither-disable-next-line reentrancy-benign
        node.submitApproveStakingWithdrawal(address(unstakingReceiver), amount);

        uint256 userUnstakeCount = unstakeCount[user];
        (, , timestamp, ) = node.getApprovedStakingWithdrawalInfo(id);
        userToUnstakingData[user][userUnstakeCount] = UnstakingInfo(
            id,
            amount,
            timestamp
        );
        unstakeCount[user]++;

        emit UnstakingRequested(user, amount);
    }
}
