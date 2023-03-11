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
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./interfaces/ITreasury.sol";

/**
 * @title DAO Treasury Contract
 * @author Team Stakely
 * @notice Keeps and spends treasury tokens
 */
contract Treasury is
    ITreasury,
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using AddressUpgradeable for address;
    using AddressUpgradeable for address payable;

    /// @notice Log to keep track of treasury balance usage
    mapping(uint256 => WithdrawLog) public log;
    /// @notice Number of entries logged
    uint256 public logCount;

    ///////////////////////////////////////////////////////////////////
    //     Events
    ///////////////////////////////////////////////////////////////////

    event Withdraw(address token, uint256 amount, address to, string reason);

    ///////////////////////////////////////////////////////////////////
    //     Initializer / Modifiers
    ///////////////////////////////////////////////////////////////////

    /// @notice Initializer
    function initialize() external initializer {
        __Ownable_init_unchained();
        logCount = 0;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    receive() external payable {}

    ///////////////////////////////////////////////////////////////////
    //     External Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Withdraws KLAY from treasury to designated address
     * @param amount amount to withdraw
     * @param to address to withdraw to
     * @param comment reason for withdrawal
     */
    function withdrawKlay(
        uint256 amount,
        address to,
        string calldata comment
    ) external onlyOwner nonReentrant {
        require(
            amount <= payable(address(this)).balance,
            "Treasury:: not enough KLAY"
        );
        require(amount > 0, "Treasury:: amount is zero");
        log[logCount] = WithdrawLog(
            block.timestamp,
            amount,
            address(0),
            _msgSender(),
            to,
            comment
        );
        logCount++;

        emit Withdraw(address(0), amount, to, comment);

        //slither-disable-next-line missing-zero-check
        payable(to).transfer(amount);
    }

    /**
     * @notice Withdraws KIP7 token to designated address
     * @param tokenAddress address of token
     * @param amount amount to withdraw
     * @param to address to withdraw to
     * @param comment reason for withdrawal
     */
    function withdrawToken(
        address tokenAddress,
        uint256 amount,
        address to,
        string calldata comment
    ) external onlyOwner nonReentrant {
        require(
            amount <= IKIP7(tokenAddress).balanceOf(address(this)),
            "Treasury:: not enough TOKEN"
        );
        log[logCount] = WithdrawLog(
            block.timestamp,
            amount,
            tokenAddress,
            _msgSender(),
            to,
            comment
        );
        logCount++;

        require(
            IKIP7(tokenAddress).transfer(to, amount),
            "Treasury:: transfer failed"
        );
        emit Withdraw(tokenAddress, amount, to, comment);
    }

    /**
     * @notice Gets log at designated page of pageSize
     * @param pageSize page size (0 for all)
     * @param pageNum page number to query (starts at 1)
     * @return totalPages number of pages total for pageNum
     * @return logResult log result for the page queried
     */
    function getLog(uint256 pageSize, uint256 pageNum)
        external
        view
        returns (uint256 totalPages, WithdrawLog[] memory logResult)
    {
        if (logCount == 0) return (0, new WithdrawLog[](0));
        if (pageSize == 0) pageSize = logCount;
        if (pageNum == 0) pageNum = 1;

        totalPages = (logCount % pageSize != 0)
            ? logCount / pageSize + 1
            : logCount / pageSize;

        if (pageNum > totalPages) pageNum = totalPages;

        uint256 startIndex = pageSize * (pageNum - 1);
        uint256 endIndex = (logCount >= pageSize * pageNum)
            ? pageSize * pageNum
            : logCount;

        logResult = new WithdrawLog[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            logResult[i - startIndex] = log[i];
        }
    }
}
