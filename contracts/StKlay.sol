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

import "@klaytn/contracts/KIP/token/KIP7/IKIP7.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./library/KIP7Upgradeable.sol";
import "./interfaces/IStKlay.sol";
import "./interfaces/INodeManager.sol";

/**
 * @title StKlay Token Contract
 * @author Team Stakely
 * @notice Stakes and unstakes KLAY <=> stKlay
 */
contract StKlay is
    IKIP7,
    IStKlay,
    KIP7Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using AddressUpgradeable for address payable;

    address private constant ZERO_ADDRESS = address(0);
    bytes32 public constant ROLE_PAUSER = keccak256("ROLE_PAUSER");

    /// @notice NodeManager contract
    INodeManager private nodeManager;

    /// @notice Total amount of shares in this contract
    uint256 public override totalShares;
    /// @notice Total staked through this contract including restaked amount
    uint256 public override totalStaking;
    /// @notice Total restaked amount from rewards
    uint256 public totalRestaked;
    /// @notice Value used in balance-share conversion
    uint256 private stakingSharesRatio;

    /// @notice Amount of shares for each user
    mapping(address => uint256) private shares;

    ///////////////////////////////////////////////////////////////////
    //     Events
    ///////////////////////////////////////////////////////////////////

    event SharesChanged(
        address indexed user,
        uint256 prevShares,
        uint256 shares
    );
    event RestakedFromManager(
        uint256 totalAmount,
        uint256 increaseAmount,
        uint256 totalStaking
    );

    ///////////////////////////////////////////////////////////////////
    //     Initializer / Modifiers
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Initializer for upgradeable StKlay contract
     * @param nodeManagerAddress nodeManager deployed address
     */
    function initialize(address nodeManagerAddress)
        external
        initializer
        validAddress(nodeManagerAddress)
    {
        __Context_init_unchained();
        __KIP7_init_unchained("Stake.ly Staked KLAY", "stKLAY");
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ROLE_PAUSER, _msgSender());

        nodeManager = INodeManager(nodeManagerAddress);
        stakingSharesRatio = 10**18;
    }

    function onUpgrade() external reinitializer(3) {
        _grantRole(DEFAULT_ADMIN_ROLE, tx.origin);
    }

    receive() external payable {}

    /**
     * @notice Checks if value is not zero
     * @param value uint256 to check
     */
    modifier nonZero(uint256 value) {
        require(value > 0, "StKlay:: value is zero");
        _;
    }

    /**
     * @notice Checks if address is valid
     * @param value address to check
     */
    modifier validAddress(address value) {
        require(value != address(0), "StKlay:: address is zero");
        _;
    }

    /**
     * @notice Checks if sender is nodeManager
     */
    modifier onlyNodeManager() {
        require(
            _msgSender() == address(nodeManager),
            "StKlay:: NodeManager only"
        );
        _;
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Deposits for sender
     * Emits a `Transfer` event from zero address to msgSender
     */
    function stake() external payable whenNotPaused {
        nodeManager.distributeReward();
        _stake(_msgSender(), msg.value);
    }

    /**
     * @notice Deposits for designated address
     * @param recipient address to deposit for
     * Emits a `Transfer` event from zero address to recipient
     */
    function stakeFor(address recipient) external payable whenNotPaused {
        nodeManager.distributeReward();
        _stake(recipient, msg.value);
    }

    /**
     * @notice Requests unstaking to sender
     * @param amount amount to unstake
     * Emits a `Transfer` event from msgSender to zero address
     */
    function unstake(uint256 amount) external whenNotPaused {
        nodeManager.distributeReward();
        _unstake(amount);
    }

    /**
     * @notice Claims unstaking requested funds
     */
    function claim(address user) external whenNotPaused {
        nodeManager.distributeReward();
        _claim(user);
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (onlyRole, onlyNodeManager)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Pauses functionality
     * @dev Approve, spendAllowance, claim, mintShares, burnShares, transferShares will not be available
     * Emits a `Paused` event
     */
    function pause() external onlyRole(ROLE_PAUSER) {
        _pause();
    }

    /**
     * @notice Unpauses functionality
     * Emits a `Unpaused` event
     */
    function unpause() external onlyRole(ROLE_PAUSER) {
        _unpause();
    }

    /**
     * @notice Increases totalStaking value due to re-staking of rewards
     * @param amount amount of re-staking rewards
     */
    function increaseTotalStaking(uint256 amount)
        external
        onlyNodeManager
        whenNotPaused
        nonZero(amount)
        nonReentrant
    {
        totalRestaked += amount;
        totalStaking += amount;
        if (totalShares > 0)
            stakingSharesRatio = (totalStaking * 10**27) / totalShares;
        emit RestakedFromManager(totalRestaked, amount, totalStaking);
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions (View)
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Returns amount of stKlay for corresponding shares
     * @dev Shares --> Klay
     * @param amount amount of shares to convert
     */
    function getSharesByKlay(uint256 amount) external view returns (uint256) {
        return _getSharesByKlay(amount);
    }

    /**
     * @notice Returns amount of shares for corresponding stKlay
     * @dev Klay --> Shares
     * @param amount amount of stKlay to convert
     */
    function getKlayByShares(uint256 amount) external view returns (uint256) {
        return _getKlayByShares(amount);
    }

    ///////////////////////////////////////////////////////////////////
    //     Public Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Returns user balance in stKlay amount
     */
    function balanceOf(address user)
        public
        view
        override(IKIP7, KIP7Upgradeable)
        returns (uint256)
    {
        return _getKlayByShares(sharesOf(user));
    }

    /**
     * @notice Returns user balance in shares
     */
    function sharesOf(address user) public view returns (uint256) {
        return shares[user];
    }

    /**
     * @notice Returns amount of klay in staking and unstaking reserve
     */
    function totalSupply()
        public
        view
        override(IKIP7, KIP7Upgradeable)
        returns (uint256)
    {
        return totalStaking;
    }

    ///////////////////////////////////////////////////////////////////
    //     Internal Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Approves token spending
     * @param owner address of token owner
     * @param spender address of token spender
     * @param amount amount spender can spend
     * Emits an `Approval` event
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal override whenNotPaused {
        super._approve(owner, spender, amount);
    }

    /**
     * @notice Updates spending allowance
     * @param owner address of token owner
     * @param spender address of token spender
     * @param amount total amount to update to (inc. spent amount)
     * Emits an `Approval` event
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal override whenNotPaused {
        super._spendAllowance(owner, spender, amount);
    }

    /**
     * @notice Transfers token ownership
     * @param from address of current token owner
     * @param to address of new token owner
     * @param amount amount of tokens to transfer
     * Emits a `Transfer` event
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        _beforeTokenTransfer(from, to, amount);

        _transferShares(from, to, _getSharesByKlay(amount));
        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    ///////////////////////////////////////////////////////////////////
    //     Private Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Deposits klay for user provided
     * @param user user to deposit for
     * @param amount amount to deposit
     * Emits a `Transfer` event from zero address to user
     */
    function _stake(address user, uint256 amount)
        private
        validAddress(user)
        nonZero(amount)
        nonReentrant
    {
        uint256 sharesToMint = _getSharesByKlay(amount);

        _mintShares(user, sharesToMint);
        totalStaking += amount;

        nodeManager.stake{value: amount}(user);

        emit Transfer(ZERO_ADDRESS, user, amount);
    }

    /**
     * @notice Requests unstaking of staked tokens
     * @param amount amount to unstake
     * Emits a `Transfer` event from msgSender to zero address
     */
    function _unstake(uint256 amount) private nonZero(amount) nonReentrant {
        address user = _msgSender();

        uint256 sharesToBurn = _getSharesByKlay(amount);
        _burnShares(user, sharesToBurn);

        totalStaking -= amount;

        nodeManager.unstake(user, amount);

        emit Transfer(user, ZERO_ADDRESS, amount);
    }

    /**
     * @notice Claims unstaking requested tokens
     * @param user address to claim unstaked
     */
    function _claim(address user) private validAddress(user) nonReentrant {
        //slither-disable-next-line reentrancy-benign
        (, uint256 expired) = nodeManager.claim(user);

        // if expired, reset expired amount
        if (expired > 0) {
            uint256 sharesToMint = _getSharesByKlay(expired);

            _mintShares(user, sharesToMint);
            totalStaking += expired;

            emit Transfer(ZERO_ADDRESS, user, expired);
        }
    }

    /**
     * @notice Mints new shares of the token to a certain user
     * @param user address to mint shares to
     * @param amount amount to mint
     * Emits a `SharesChanged` event
     */
    function _mintShares(address user, uint256 amount)
        private
        validAddress(user)
        nonZero(amount)
    {
        totalShares += amount;
        uint256 prevShares = sharesOf(user);
        shares[user] = prevShares + amount;

        emit SharesChanged(user, prevShares, shares[user]);
    }

    /**
     * @notice Burns shares of the token
     * @param user address to burn for
     * @param amount amount to burn
     * Emits a `SharesChanged` event
     */
    function _burnShares(address user, uint256 amount)
        private
        validAddress(user)
        nonZero(amount)
    {
        uint256 prevShares = sharesOf(user);
        require(prevShares >= amount, "StKlay:: insufficient shares");

        totalShares -= amount;
        shares[user] = prevShares - amount;

        emit SharesChanged(user, prevShares, shares[user]);
    }

    /**
     * @notice Transfers shares from one address to another
     * @param from address to transfer from
     * @param to address to transfer to
     * @param amount amount to transfer
     * Emits a `SharesChanged` event
     */
    function _transferShares(
        address from,
        address to,
        uint256 amount
    ) private validAddress(from) validAddress(to) {
        uint256 fromShares = sharesOf(from);
        require(fromShares >= amount, "StKlay:: insufficient shares");

        shares[from] = fromShares - amount;
        uint256 toShares = sharesOf(to);
        shares[to] = toShares + amount;

        emit SharesChanged(from, fromShares, shares[from]);
        emit SharesChanged(to, toShares, shares[to]);
    }

    /**
     * @notice Returns amount of stKlay for corresponding shares
     * @dev Shares --> Klay
     * @param sharesAmount amount of shares to convert
     */
    function _getKlayByShares(uint256 sharesAmount)
        private
        view
        returns (uint256)
    {
        return (sharesAmount * stakingSharesRatio) / 10**27;
    }

    /**
     * @notice Returns amount of shares for corresponding stKlay
     * @dev Klay --> Shares
     * @param klayAmount amount of stKlay to convert
     */
    function _getSharesByKlay(uint256 klayAmount)
        private
        view
        returns (uint256)
    {
        return
            (klayAmount * 10**27 + stakingSharesRatio - 1) / stakingSharesRatio;
    }
}
