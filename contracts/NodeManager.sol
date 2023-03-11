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

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IStKlay.sol";
import "./interfaces/IStKly.sol";
import "./interfaces/INodeManager.sol";

///////////////////////////////////////////////////////////////////
// Good to know in advance about KLAY Tokenomics
///////////////////////////////////////////////////////////////////
// - The more evenly distributed KLAY among nodes, the higher the total interest rate
// - If node has less than 5M KLAY, block reward will not be paid (We consider these nodes as non-operational)
// - Claiming staked KLAY requires 1 week of delay after unstaking request
//   (Claimable Time = 1 week after unstaking request)
// - After 1 week from claimable time, unstaking request will be expired
// - See more details here - https://docs.klaytn.foundation/klaytn/design/token-economy

/**
 * @title NodeManager Contract
 * @author Team Stakely
 * @notice Keeps track of node manager
 * @dev Accessed by stKlay Contract to stake/unstake/claim to each NodeHandler
 */
contract NodeManager is
    INodeManager,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    struct UnstakeDistributionParams {
        uint256[] protocolNetStakings;
        uint256 maxProtocolNetStaking;
        uint256 minProtocolNetStaking;
        uint256 minSafelyUnstakeable;
        uint256 richest;
        uint256 totalSafelyUnstakeable;
        uint256 unstakeableNodeCount;
    }

    using AddressUpgradeable for address payable;

    bytes32 private constant ROLE_FEE_MANAGER = keccak256("ROLE_FEE_MANAGER");
    bytes32 private constant ROLE_NODE_INFO_SETTER =
        keccak256("ROLE_NODE_INFO_SETTER");
    bytes32 private constant ROLE_STKLAY_SETTER =
        keccak256("ROLE_STKLAY_SETTER");
    bytes32 private constant ROLE_MIN_SETTER = keccak256("ROLE_MIN_SETTER");
    bytes32 private constant ROLE_TREASURY_SETTER =
        keccak256("ROLE_TREASURY_SETTER");

    /// @notice stKlay token
    // slither-disable-next-line uninitialized-state
    IStKlay private stKlay;
    /// @notice Lockup until unstaking requested amount is claimable (depends on cnStakingContract)
    uint256 private nodeLockupTime;
    /// @notice Node Id => NodeInfo mapping
    // slither-disable-next-line uninitialized-state
    mapping(uint256 => NodeInfo) private nodeInfos;
    /// @notice Total number of nodes added to mapping
    uint256 public nodeCount;
    /// @notice Total number of active nodes
    uint256 public activeNodeCount;
    /// @notice Threshold to split a unstake amount
    uint256 public unstakeSplitThreshold;

    /// @notice Total klay sent to stKly contract
    uint256 public totalKlayToStKly;
    /// @notice Percentage of rewards sent to fees
    uint16 public feeRate;
    /// @notice Distribution ratio of fees to each distribution target
    FeeDistribution public feeDistribution;
    /// @notice Address of treasury contract
    address private treasuryAddress;
    /// @notice Address of stKly contract
    address private stKlyAddress;

    /// @notice Minimum KLAY to operate node. If node has less than MIN_KLAY_TO_OPERATE, block reward will not be paid
    uint256 private minKlayToOperate;
    /// @notice Minimum amount before claimReward from NodeHandler
    uint256 public claimMinimum;
    /// @notice Minimum amount before distributeReward
    uint256 public distributeMinimum;

    /// @notice Unstaking Request for each id for each user (id starts from 1)
    mapping(address => mapping(uint256 => UnstakingRequest))
        public userToUnstakingRequest;
    /// @notice Total unstaking requests for each user
    mapping(address => uint256) public unstakeCount;
    /// @notice Total unstaking claimed for each user
    mapping(address => uint256) public claimCount;
    /// @notice true if unstaking is blocked for a node
    mapping(uint256 => bool) public isUnstakingBlocked;

    /// @notice Tax rate in bps
    uint16 public taxRate;
    /// @notice Address of tax receiver
    address public taxReceiver;
    /// @notice Use the id of nodeInfos
    /// @notice Determine whether sending tax seperately
    mapping(uint256 => bool) public taxFlag;

    ///////////////////////////////////////////////////////////////////
    //     Events
    ///////////////////////////////////////////////////////////////////

    event FeeRateChanged(uint16 indexed feeRate);
    event FeeDistributionChanged(
        uint8 indexed operatorsRatio,
        uint8 indexed treasuryRatio,
        uint8 indexed stKlyRatio
    );
    event TreasuryChanged(address indexed treasuryAddress);
    event RecordTotalKlayToStKly(
        uint256 rewardAmount,
        uint256 klayAmount,
        uint256 stKlyAmount
    );
    event Staked(address from, uint256 amount);
    event UnstakingRequested(
        address to,
        uint256 amount,
        uint256 claimableTimestamp
    );
    event Claimed(address user, uint256 claimed, uint256 expired);
    event TaxRateChanged(uint16 indexed taxRate);
    event TaxReceiverChanged(address indexed taxReceiver);
    event TaxCollected(uint256 indexed id, uint256 tax);

    ///////////////////////////////////////////////////////////////////
    //     Initializer / Modifiers
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Initializer for upgradeable NodeManager contract
     * @param treasuryAddress_ treasury wallet address
     * @param stKlyAddress_ stKly contract address
     */
    function initialize(
        address treasuryAddress_,
        address stKlyAddress_,
        uint256 minKlayToOperate_
    )
        external
        initializer
        validAddress(treasuryAddress_)
        validAddress(stKlyAddress_)
    {
        __Context_init_unchained();
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

        nodeCount = 0;
        activeNodeCount = 0;

        _setFeeRate(20_00);
        _setFeeDistribution(50, 20, 30); // node : treasusy : stKly
        _setTreasury(treasuryAddress_);
        _setNodeLockupTime(1 weeks);
        _setUnstakeSplitThreshold(10_000e18);

        _grantRole(ROLE_FEE_MANAGER, _msgSender());
        _grantRole(ROLE_NODE_INFO_SETTER, _msgSender());
        _grantRole(ROLE_STKLAY_SETTER, _msgSender());
        _grantRole(ROLE_MIN_SETTER, _msgSender());
        _grantRole(ROLE_TREASURY_SETTER, _msgSender());

        stKlyAddress = stKlyAddress_;
        minKlayToOperate = minKlayToOperate_;

        claimMinimum = 1e19;
        distributeMinimum = 1e20;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    receive() external payable {}

    /**
     * @notice Checks if value is not zero
     * @param value uint256 to check
     */
    modifier nonZero(uint256 value) {
        require(value > 0, "NodeManager:: value is zero");
        _;
    }

    /**
     * @notice Checks if address is valid
     * @param value address to check
     */
    modifier validAddress(address value) {
        require(value != address(0), "NodeManager:: address is zero");
        _;
    }

    /**
     * @notice Checks if valid as a basis point
     * @param value bps to check, should be 0 ~ 10,000
     */
    modifier validBasisPoint(uint16 value) {
        require(value <= 10_000, "NodeManager:: invalid basis point value");
        _;
    }

    /**
     * @notice Checks if msg.sender is stKlay contract
     */
    modifier onlyStKlay() virtual {
        require(
            msg.sender == address(stKlay),
            "NodeManager:: not called from StKlay"
        );
        _;
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Applies added reward balance and distribute fees
     */
    function distributeReward() external nonReentrant whenNotPaused {
        _claimRewardFromNodes();
        _distributeReward();
    }

    /**
     * @notice Applies added reward balance and distribute fees for a specific node
     */
    function forceDistributeReward(uint256 nodeId)
        external
        nonReentrant
        whenNotPaused
    {
        //slither-disable-next-line unused-return
        nodeInfos[nodeId].nodeHandler.claimReward();
        _distributeReward();
    }

    /**
     * @notice Stakes to nodes
     * @dev `msg.value` is the amount to stake
     * @param from staker address
     */
    function stake(address from)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyStKlay
    {
        _stake(from, msg.value);
    }

    /**
     * @notice Unstakes from nodes
     * @param to address to unstake to
     * @param amount amount to unstake
     */
    function unstake(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyStKlay
    {
        _unstake(to, amount);
    }

    /**
     * @notice Claims unstaking requested tokens
     * @param user address of unstaking requester
     */
    function claim(address user)
        external
        nonReentrant
        whenNotPaused
        onlyStKlay
        returns (uint256 claimed, uint256 expired)
    {
        return _claim(user);
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (onlyRole)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Unstakes from a specific node for rebalacing
     * @param nodeId id of node to unstake
     * @param amount amount to unstake
     */
    function unstakeForRebalacing(uint256 nodeId, uint256 amount)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        INodeHandler nodeHandler = nodeInfos[nodeId].nodeHandler;
        uint256 protocolNetStaking = nodeHandler.protocolNetStaking();
        uint256 totalNetStaking = nodeHandler.totalNetStaking();
        require(
            amount <= protocolNetStaking &&
                totalNetStaking - amount >= minKlayToOperate,
            "NodeManager:: insufficient staking"
        );

        //slither-disable-next-line unused-return
        nodeHandler.unstake(address(this), amount);
    }

    /**
     * @notice Unstakes all from a specific node and inactivates it
     * @param nodeId id of node to unstake and inactivate
     */
    function unstakeForDeregister(uint256 nodeId)
        external
        nonReentrant
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        INodeHandler nodeHandler = nodeInfos[nodeId].nodeHandler;
        _setActive(nodeId, false);

        //slither-disable-next-line unused-return
        nodeHandler.unstakeForDeregister();
    }

    /**
     * @notice Claims from a specific node and stakes again
     * @dev claimed KLAY is redistributed to the nodes regardless of stakeNodeId
     * @param claimNodeId id of node to claim
     * @param stakeNodeId id of node to stake if node to claim is active
     */
    function claimAndRestake(uint256 claimNodeId, uint256 stakeNodeId)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        NodeInfo memory claimNodeInfo = nodeInfos[claimNodeId];
        (uint256 totalClaimed, ) = claimNodeInfo.nodeHandler.claimUnstaked(
            address(this),
            type(uint256).max
        );

        if (totalClaimed == 0) return;

        if (claimNodeInfo.active) {
            NodeInfo memory stakeNodeInfo = nodeInfos[stakeNodeId];
            require(
                stakeNodeInfo.active,
                "NodeManager:: stakeNode is inactive"
            );
            //slither-disable-next-line arbitrary-send-eth
            stakeNodeInfo.nodeHandler.stake{value: totalClaimed}();
        } else {
            _stake(address(this), totalClaimed);
        }
    }

    /**
     * @notice Sets stKlay contract address
     * @param stKlayAddress stKlay contract address
     */
    function setStKlayAddress(address stKlayAddress)
        external
        onlyRole(ROLE_STKLAY_SETTER)
        validAddress(stKlayAddress)
    {
        stKlay = IStKlay(stKlayAddress);
    }

    /**
     * @notice Sets fee rate
     * @param feeRate_ new fee rate
     */
    function setFeeRate(uint16 feeRate_) external onlyRole(ROLE_FEE_MANAGER) {
        _setFeeRate(feeRate_);
    }

    /**
     * @notice Sets fee distribution
     * @dev Will revert when sum of param values != 100
     * @param operatorsRatio_ percentage distributed to node operators
     * @param treasuryRatio_ percentage distributed to treasury
     * @param stKlyRatio_ percentage distributed to stKly
     * Emits a `FeeDistributionChanged` event
     * NOTE: determine if structure change needed if add distributees
     */
    function setFeeDistribution(
        uint8 operatorsRatio_,
        uint8 treasuryRatio_,
        uint8 stKlyRatio_
    ) external onlyRole(ROLE_FEE_MANAGER) {
        _setFeeDistribution(operatorsRatio_, treasuryRatio_, stKlyRatio_);
    }

    /**
     * @notice Sets lockup until unstaking requested amount is claimable
     * @param nodeLockupTime_ new lockup time
     */
    function setNodeLockupTime(uint256 nodeLockupTime_)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        _setNodeLockupTime(nodeLockupTime_);
    }

    /**
     * @notice Set unstake split threshold
     */
    function setUnstakeSplitThreshold(uint256 threshold)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        _setUnstakeSplitThreshold(threshold);
    }

    /**
     * @notice Set tax rate in bps
     */
    function setTaxRate(uint16 taxRate_)
        external
        onlyRole(ROLE_FEE_MANAGER)
        validBasisPoint(taxRate_)
    {
        taxRate = taxRate_;
        emit TaxRateChanged(taxRate_);
    }

    /**
     * @notice Set tax receiver address
     */
    function setTaxReceiver(address taxReceiver_)
        external
        onlyRole(ROLE_FEE_MANAGER)
        validAddress(taxReceiver_)
    {
        taxReceiver = taxReceiver_;
        emit TaxReceiverChanged(taxReceiver_);
    }

    /**
     * @notice Set tax flag for a node
     */
    function setTaxFlag(uint256 nodeId, bool flag)
        external
        onlyRole(ROLE_FEE_MANAGER)
    {
        require(
            nodeInfos[nodeId].rewardAddress != address(0),
            "NodeManager:: invalid nodeId"
        );
        taxFlag[nodeId] = flag;
    }

    function setRoleAdmin() external reinitializer(2) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @notice Config function for data
     * @param what what we want to change
     * @param data new data to set
     */
    function config(bytes32 what, uint256 data)
        external
        onlyRole(ROLE_MIN_SETTER)
    {
        if (what == "claimMinimum") {
            claimMinimum = data;
        } else if (what == "distributeMinimum") {
            distributeMinimum = data;
        } else {
            revert("NodeManager:: Parameter unrecognized");
        }
    }

    /**
     * @notice Adds new node
     * @param name name for the node
     *@param nodeHandlerAddress node address
     *@param rewardAddress the node's reward address
     */
    function addNode(
        string calldata name,
        address nodeHandlerAddress,
        address rewardAddress
    )
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
        validAddress(nodeHandlerAddress)
        validAddress(rewardAddress)
        returns (uint256 nodeId)
    {
        require(
            rewardAddress != address(0),
            "NodeManager:: reward address is zero"
        );

        nodeId = nodeCount++;
        activeNodeCount++;

        NodeInfo storage info = nodeInfos[nodeId];
        info.name = name;
        info.active = true;
        info.nodeHandler = INodeHandler(nodeHandlerAddress);
        info.rewardAddress = rewardAddress;
    }

    /**
     * @notice Sets new name for node
     * @param nodeId id of node to change
     * @param name new name to set
     */
    function setNodeName(uint256 nodeId, string calldata name)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        nodeInfos[nodeId].name = name;
    }

    function setUnstakingBlocked(uint256 nodeId, bool isBlocked)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        isUnstakingBlocked[nodeId] = isBlocked;
    }

    /**
     * @notice Sets node active or inactive
     * @param nodeId id of node to change
     * @param active new active status of node
     */
    function setNodeActive(uint256 nodeId, bool active)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
    {
        _setActive(nodeId, active);
    }

    /**
     * @notice Sets new reward address for node
     * @param nodeId id of node to change
     * @param rewardAddress new reward address of node
     */
    function setNodeRewardAddress(uint256 nodeId, address rewardAddress)
        external
        onlyRole(ROLE_NODE_INFO_SETTER)
        validAddress(rewardAddress)
    {
        nodeInfos[nodeId].rewardAddress = rewardAddress;
    }

    /**
     * @notice Sets new treasury address for fees
     * @param treasuryAddress_ new treasury address
     */
    function setTreasuryAddress(address treasuryAddress_)
        external
        onlyRole(ROLE_TREASURY_SETTER)
    {
        _setTreasury(treasuryAddress_);
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (View)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Gets NodeInfo for node by id
     * @param nodeId id of node to access
     */
    function getNode(uint256 nodeId)
        external
        view
        returns (NodeInfo memory info)
    {
        info = nodeInfos[nodeId];
    }

    /**
     * @notice Get total claimable amount
     * @param user address of unstaking requester
     */
    function getTotalClaimable(address user)
        external
        view
        returns (uint256 claimable)
    {
        uint256 userUnstakeCount = unstakeCount[user];
        uint256 userClaimCount = claimCount[user];
        if (userClaimCount >= userUnstakeCount) return 0;

        for (uint256 i = userClaimCount + 1; i <= userUnstakeCount; i++) {
            UnstakingRequest memory request = userToUnstakingRequest[user][i];
            if (block.timestamp >= request.claimableTimestamp) {
                claimable += request.amount;
            }
        }
    }

    /**
     * @notice Get total claimable request count
     * @param user address of unstaking requester
     */
    function getClaimableRequestCount(address user)
        external
        view
        returns (uint256 count)
    {
        uint256 userUnstakeCount = unstakeCount[user];
        uint256 userClaimCount = claimCount[user];
        if (userClaimCount >= userUnstakeCount) return 0;

        for (uint256 i = userClaimCount + 1; i <= userUnstakeCount; i++) {
            UnstakingRequest memory request = userToUnstakingRequest[user][i];
            if (block.timestamp >= request.claimableTimestamp) {
                count += 1;
            }
        }
    }

    /**
     * @notice Get unstaking requests paginated (most recent first)
     * @param user address of unstaking requester
     * @param pageSize page size (0 for all)
     * @param pageNum page number to query (starts at 1)
     */
    function getUnstakingRequestsByPage(
        address user,
        uint256 pageSize,
        uint256 pageNum
    )
        external
        view
        returns (uint256 totalPages, UnstakingRequest[] memory requestedPage)
    {
        uint256 length = unstakeCount[user];

        if (length == 0) return (0, requestedPage);
        if (pageSize == 0) pageSize = length;
        if (pageNum == 0) pageNum = 1;

        totalPages = (length % pageSize != 0)
            ? length / pageSize + 1
            : length / pageSize;

        if (pageNum > totalPages) pageNum = totalPages;

        uint256 start = length >= pageSize * pageNum
            ? length - pageSize * pageNum
            : 0;
        uint256 end = length - pageSize * (pageNum - 1);

        requestedPage = _getUnstakingRequests(user, start, end);
    }

    ///////////////////////////////////////////////////////////////////
    //     Private Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Sets new fee rate
     * @param feeRate_ new fee rate
     */
    function _setFeeRate(uint16 feeRate_) private validBasisPoint(feeRate_) {
        feeRate = feeRate_;
        emit FeeRateChanged(feeRate_);
    }

    /**
     * @notice Sets new fee distribution ratio
     * @dev Will revert when sum of param values != 100
     * @param operatorsRatio_ percentage distributed to node operators
     * @param treasuryRatio_ percentage distributed to treasury
     * @param stKlyRatio_ percentage distributed to stKly
     * Emits a `FeeDistributionChanged` event
     * NOTE: determine if structure change needed if add distributees
     */
    function _setFeeDistribution(
        uint8 operatorsRatio_,
        uint8 treasuryRatio_,
        uint8 stKlyRatio_
    ) private {
        require(
            operatorsRatio_ + treasuryRatio_ + stKlyRatio_ == 100,
            "NodeManager:: fees don't add up"
        );

        feeDistribution.operatorsRatio = operatorsRatio_;
        feeDistribution.treasuryRatio = treasuryRatio_;
        feeDistribution.stKlyRatio = stKlyRatio_;

        emit FeeDistributionChanged(
            operatorsRatio_,
            treasuryRatio_,
            stKlyRatio_
        );
    }

    /**
     * @notice Sets new treasury address
     * @param treasuryAddress_ new treasury address
     * Emits a `TreasuryChanged` event
     */
    function _setTreasury(address treasuryAddress_)
        private
        validAddress(treasuryAddress_)
    {
        treasuryAddress = treasuryAddress_;

        emit TreasuryChanged(treasuryAddress);
    }

    /**
     * @notice Sets lockup until unstaking requested amount is claimable
     * @param nodeLockupTime_ new lockup time
     */
    function _setNodeLockupTime(uint256 nodeLockupTime_) private {
        nodeLockupTime = nodeLockupTime_;
    }

    /**
     * @notice Set unstake split threshold
     */
    function _setUnstakeSplitThreshold(uint256 threshold) private {
        unstakeSplitThreshold = threshold;
    }

    function _setActive(uint256 nodeId, bool active) private {
        NodeInfo storage info = nodeInfos[nodeId];

        if (info.active != active) {
            info.active = active;

            if (active) {
                activeNodeCount++;
            } else {
                activeNodeCount--;
            }
        }
    }

    /**
     * @notice Applies added reward balance and distribute fees
     * @dev Adds accrued rewards to totalStaking value
     * @dev Mints shares corresponding to fees
     * @dev Distribute fees to treasury and node operators
     */
    function _distributeReward() private {
        uint256 rewards = address(this).balance;

        if (rewards < distributeMinimum) return;

        uint256 fee = (rewards * feeRate) / 1e4;
        uint256 reStaking = rewards - fee;

        stKlay.increaseTotalStaking(reStaking);

        uint256 toNodeOperators = (fee * feeDistribution.operatorsRatio) / 100;
        _distributeFeeToNodeOperators(toNodeOperators);

        uint256 toStKly = (fee * feeDistribution.stKlyRatio) / 100;
        uint256 toTreasury = fee - toNodeOperators - toStKly;

        if (toStKly > 0) {
            totalKlayToStKly += toStKly;
            emit RecordTotalKlayToStKly(
                toStKly,
                totalKlayToStKly,
                IStKly(stKlyAddress).totalSupply()
            );
            payable(stKlyAddress).sendValue(toStKly);
        }
        payable(treasuryAddress).sendValue(toTreasury);

        _stake(address(this), reStaking);
    }

    /**
     * @notice Stakes to nodes
     * @dev Divides amount equally and stakes equal amount to each node
     * @param amount amount to stake
     * NOTE: subject to change depending on staking policy
     */
    function _stake(address from, uint256 amount) private nonZero(amount) {
        require(activeNodeCount > 0, "NodeManager:: node count is zero");

        uint256[] memory distributions = _computeStakeDistributions(amount);

        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];
            if (!info.active) continue;

            uint256 share = distributions[i];
            if (share == 0) continue;

            //slither-disable-next-line arbitrary-send-eth
            info.nodeHandler.stake{value: share}();
        }

        emit Staked(from, amount);
    }

    /**
     * @notice Unstakes from nodes
     * @dev Divides amount equally and unstakes equal amount from each node
     * @param to address to unstake to
     * @param amount amount to unstake
     * NOTE: subject to change depending on staking policy
     */
    function _unstake(address to, uint256 amount)
        private
        validAddress(to)
        nonZero(amount)
    {
        require(activeNodeCount > 0, "NodeManager:: node count is zero");

        uint256 count = unstakeCount[to] + 1;
        // Add to unstaking records
        uint256 claimableTimestamp = block.timestamp + nodeLockupTime;
        userToUnstakingRequest[to][count] = UnstakingRequest(
            amount,
            claimableTimestamp,
            ClaimState.Unclaimed
        );
        unstakeCount[to] = count;

        uint256[] memory distributions = _computeUnstakeDistributions(amount);

        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            if (!info.active) continue;

            uint256 share = distributions[i];
            if (share == 0) continue;

            //slither-disable-next-line unused-return
            info.nodeHandler.unstake(to, share);
        }

        emit UnstakingRequested(to, amount, claimableTimestamp);
    }

    /**
     * @notice Claims unstaking requested tokens
     * @param user unstaking requester
     */
    function _claim(address user)
        private
        returns (uint256 totalClaimed, uint256 totalExpired)
    {
        uint256 userUnstakeCount = unstakeCount[user];
        uint256 userClaimCount = claimCount[user];

        if (userClaimCount >= userUnstakeCount) return (0, 0);

        uint256 safeCount = userClaimCount + 10 > userUnstakeCount
            ? userUnstakeCount
            : userClaimCount + 10;

        uint256 timeLimit = userToUnstakingRequest[user][safeCount]
            .claimableTimestamp;

        //slither-disable-next-line reentrancy-no-eth
        (totalClaimed, totalExpired) = _claimCallToNodeHandlers(
            user,
            timeLimit
        );

        // Update unstaking records
        for (uint256 i = userClaimCount + 1; i <= safeCount; i++) {
            UnstakingRequest memory data = userToUnstakingRequest[user][i];
            if (block.timestamp < data.claimableTimestamp) break;
            userClaimCount++;
            if (block.timestamp >= data.claimableTimestamp + nodeLockupTime) {
                userToUnstakingRequest[user][i].claimState = ClaimState.Expired;
            } else {
                userToUnstakingRequest[user][i].claimState = ClaimState.Claimed;
            }
        }
        claimCount[user] = userClaimCount;

        emit Claimed(user, totalClaimed, totalExpired);
    }

    function _claimCallToNodeHandlers(address user, uint256 timeLimit)
        private
        returns (uint256 totalClaimed, uint256 totalExpired)
    {
        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            (uint256 claimed, uint256 expired) = info.nodeHandler.claimUnstaked(
                user,
                timeLimit
            );

            if (claimed > 0) totalClaimed += claimed;
            if (expired > 0) totalExpired += expired;
        }
    }

    /**
     * @notice Distributes fee for node operators. Fees are distributed equally regardless of the initial supplied KLAY
     * @dev Called in _distributeReward
     * @param amount klay for each active node operator
     */
    function _distributeFeeToNodeOperators(uint256 amount)
        private
        nonZero(amount)
    {
        uint256 toOneNode = amount / activeNodeCount;
        uint256 totalTax = 0;
        uint256 tax = (toOneNode * taxRate) / 1e4;

        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            if (!info.active) continue;
            if (taxFlag[i] && tax > 0) {
                totalTax += tax;
                emit TaxCollected(i, tax);
                payable(info.rewardAddress).sendValue(toOneNode - tax);
            } else {
                payable(info.rewardAddress).sendValue(toOneNode);
            }
        }

        if (totalTax > 0) payable(taxReceiver).sendValue(totalTax);
    }

    /**
     * @notice Claims reward to this contract if claimable over claimMinimum
     */
    function _claimRewardFromNodes() private {
        require(nodeCount > 0);

        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            if (!info.active) continue;
            if (info.nodeHandler.getClaimableReward() > claimMinimum) {
                //slither-disable-next-line unused-return
                info.nodeHandler.claimReward();
            }
        }
    }

    /**
     * @notice Calculates distributions from amount to stake
     * @notice Logic is built on the premise that staked amount of each node will not be much different
     * @param amount total KLAY to distribute
     */
    function _computeStakeDistributions(uint256 amount)
        private
        view
        returns (uint256[] memory distribution)
    {
        uint256 maxProtocolNetStaking = 0;
        uint256 minProtocolNetStaking = type(uint256).max;
        uint256 minGap = type(uint256).max;
        uint256 poorest = 0;
        uint256 closestToOperate = type(uint256).max;

        // Find the richest, poorest, closestToOperate node from active nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            if (!info.active) continue;

            uint256 protocolNetStaking = info.nodeHandler.protocolNetStaking();

            if (maxProtocolNetStaking < protocolNetStaking) {
                maxProtocolNetStaking = protocolNetStaking;
            }

            if (minProtocolNetStaking > protocolNetStaking) {
                minProtocolNetStaking = protocolNetStaking;
                poorest = i;
            }

            uint256 gap = guardedSub(
                minKlayToOperate,
                info.nodeHandler.totalNetStaking()
            );

            if (gap > 0 && gap < minGap) {
                minGap = gap;
                closestToOperate = i;
            }
        }

        uint256 left = amount;

        distribution = new uint256[](nodeCount);

        // Distribute insufficient amount for activation to closestToOperate node first
        if (closestToOperate != type(uint256).max) {
            if (minGap > left) {
                distribution[closestToOperate] = left;
                left = 0;
            } else {
                left -= minGap;
                distribution[closestToOperate] = minGap;
            }

            if (left > 0 && poorest == closestToOperate) {
                minProtocolNetStaking += minGap;
                if (minProtocolNetStaking > maxProtocolNetStaking)
                    maxProtocolNetStaking = minProtocolNetStaking;
            }
        }

        uint256 diff = maxProtocolNetStaking - minProtocolNetStaking;
        uint256 fill = Math.min(left, diff);
        uint256 share = (left - fill) / activeNodeCount;

        // Case1: left > diff (amount is big enough)
        // - 1. Distribute even amount to each node
        // - 2. Distribute more to poorest by diff

        // Case2: left < diff (amount is relatively small)
        // - Distribute all remaind amount to poorest
        if (share > 0) {
            for (uint256 i = 0; i < nodeCount; i++) {
                NodeInfo memory info = nodeInfos[i];

                if (!info.active) continue;

                distribution[i] += share;
                left -= share;
            }
        }

        if (left > 0) {
            distribution[poorest] += left;
        }
    }

    /**
     * @notice Calculate distributions from amount to unstake
     * @param amount total KLAY to distribute
     */
    function _computeUnstakeDistributions(uint256 amount)
        private
        view
        returns (uint256[] memory distribution)
    {
        distribution = new uint256[](nodeCount);

        UnstakeDistributionParams memory params = UnstakeDistributionParams({
            protocolNetStakings: new uint256[](nodeCount),
            maxProtocolNetStaking: 0,
            minProtocolNetStaking: type(uint256).max,
            minSafelyUnstakeable: type(uint256).max,
            richest: 0,
            totalSafelyUnstakeable: 0,
            unstakeableNodeCount: activeNodeCount
        });

        // Find the richest from active nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            NodeInfo memory info = nodeInfos[i];

            if (!info.active) continue;
            if (isUnstakingBlocked[i]) {
                params.unstakeableNodeCount--;
                continue;
            }

            uint256 gcStaking = info.nodeHandler.gcStaking();
            params.protocolNetStakings[i] = info
                .nodeHandler
                .protocolNetStaking();

            uint256 safelyUnstakeable = guardedSub(
                params.protocolNetStakings[i],
                guardedSub(minKlayToOperate, gcStaking)
            );

            if (params.maxProtocolNetStaking < params.protocolNetStakings[i]) {
                params.maxProtocolNetStaking = params.protocolNetStakings[i];
                params.richest = i;
            }

            if (params.minProtocolNetStaking > params.protocolNetStakings[i]) {
                params.minProtocolNetStaking = params.protocolNetStakings[i];
            }

            if (safelyUnstakeable == 0) {
                params.unstakeableNodeCount--;
                continue;
            }

            distribution[i] = safelyUnstakeable;
            params.totalSafelyUnstakeable += safelyUnstakeable;

            if (params.minSafelyUnstakeable > safelyUnstakeable) {
                params.minSafelyUnstakeable = safelyUnstakeable;
            }
        }

        // `distribution` at this point contains maximum safely unstakeable KLAY of each nodes without deactivation
        uint256 left = amount;
        uint256 diff = Math.min(
            amount,
            params.maxProtocolNetStaking - params.minProtocolNetStaking
        );

        // Case1: Total Amount can be unstaked from the richest node
        uint256 piece = guardedDiv(amount - diff, params.unstakeableNodeCount);
        if (distribution[params.richest] >= amount) {
            if (amount <= diff + unstakeSplitThreshold) {
                distribution = new uint256[](nodeCount);
                distribution[params.richest] = amount;
            } else {
                distribution[params.richest] = diff + piece;
                left -= distribution[params.richest];
                for (uint256 i = 0; i < nodeCount; i++) {
                    NodeInfo memory info = nodeInfos[i];

                    if (
                        !info.active ||
                        isUnstakingBlocked[i] ||
                        i == params.richest
                    ) continue;

                    distribution[i] = Math.min(distribution[i], piece);
                    left -= distribution[i];
                }
                distribution[params.richest] += left;
            }
            return distribution;
        }

        // Case2: All nodes are big enough to be evenly distributed
        //        && The richest node is big enough to unstake 'evenly distributed amount + diff'
        uint256 biggestPiece = diff + piece + nodeCount; // add nodeCount to deal with loss when calculate piece due to division
        if (
            distribution[params.richest] >= biggestPiece &&
            params.minSafelyUnstakeable >= piece
        ) {
            for (uint256 i = 0; i < nodeCount; i++) {
                NodeInfo memory info = nodeInfos[i];

                if (
                    !info.active || isUnstakingBlocked[i] || i == params.richest
                ) continue;

                distribution[i] = piece;
                left -= piece;
            }

            // the richest node takes `diff` and what's left - not the `biggestPiece`
            distribution[params.richest] = left;
            return distribution;
        }

        if (params.totalSafelyUnstakeable >= amount) {
            // Case3: Can unstake without deactivating any nodes but cannot distribute evenly
            left -= distribution[params.richest];

            for (uint256 i = 0; i < nodeCount; i++) {
                NodeInfo memory info = nodeInfos[i];

                if (
                    !info.active || isUnstakingBlocked[i] || i == params.richest
                ) continue;

                uint256 unstakeAmount = Math.min(distribution[i], left);

                // overwrite all previous distribution values
                distribution[i] = unstakeAmount;
                left -= unstakeAmount;
            }
        } else {
            // Case4: Deactivation is inevitable :(
            left -= params.totalSafelyUnstakeable;

            for (uint256 i = 0; i < nodeCount && left > 0; i++) {
                NodeInfo memory info = nodeInfos[i];

                if (!info.active || isUnstakingBlocked[i]) continue;

                if (params.protocolNetStakings[i] == distribution[i]) continue;

                uint256 unstakeAmount = Math.min(
                    params.protocolNetStakings[i] - distribution[i],
                    left
                );

                // add additional amounts
                distribution[i] += unstakeAmount;
                left -= unstakeAmount;
            }
        }

        require(left == 0, "NodeManager:: something went wrong");
    }

    function _getUnstakingRequests(
        address user,
        uint256 start,
        uint256 end
    ) private view returns (UnstakingRequest[] memory requests) {
        if (start >= end) return requests;

        requests = new UnstakingRequest[](end - start);

        for (uint256 i = 0; i < end - start; i++) {
            requests[i] = userToUnstakingRequest[user][end - i];
        }
    }

    function guardedSub(uint256 a, uint256 b) private pure returns (uint256 c) {
        c = a < b ? 0 : a - b;
    }

    function guardedDiv(uint256 a, uint256 b) private pure returns (uint256 c) {
        c = b == 0 ? 0 : a / b;
    }
}
