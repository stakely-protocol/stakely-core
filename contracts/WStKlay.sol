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
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "./library/KIP7Upgradeable.sol";
import "./interfaces/IStKlay.sol";
import "./interfaces/IWStKlay.sol";

/**
 * @title WStKlay Token Contract
 * @author Team Stakely
 * @notice Wraps and unwraps stKlay <=> wstKlay
 */
contract WStKlay is IKIP7, IWStKlay, KIP7Upgradeable, PausableUpgradeable {
    using AddressUpgradeable for address payable;

    /// @notice StKlay token contract
    IStKlay private stKlay;

    ///////////////////////////////////////////////////////////////////
    //     Initializer / Modifiers
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Initializer for WStKlay contract
     * @param stKlayAddress address for StKlay contract
     */
    function initialize(address stKlayAddress)
        external
        initializer
        validAddress(stKlayAddress)
    {
        __Pausable_init_unchained();
        __KIP7_init_unchained("Stake.ly Wrapped stKLAY", "wstKLAY");

        stKlay = IStKlay(stKlayAddress);
    }

    /**
     * @notice Checks if value is not zero
     * @param value uint256 to check
     */
    modifier nonZero(uint256 value) {
        require(value > 0, "WStKlay:: value is zero");
        _;
    }

    /**
     * @notice Checks if address is valid
     * @param value address to check
     */
    modifier validAddress(address value) {
        require(value != address(0), "WStKlay:: address is zero");
        _;
    }

    ///////////////////////////////////////////////////////////////////
    //     External Functions
    ///////////////////////////////////////////////////////////////////

    /**
     * @notice Wraps stKlay to wstKlay
     * @param amount amount of stKlay to wrap
     * @return wrappedAmount amount of wstKlay sent to user
     * Emits a `Transfer` event from zero address to msgSender
     */
    function wrap(uint256 amount)
        external
        override
        nonZero(amount)
        returns (uint256 wrappedAmount)
    {
        wrappedAmount = getWrappedAmount(amount);

        _mint(_msgSender(), wrappedAmount);

        bool success = stKlay.transferFrom(_msgSender(), address(this), amount);
        require(success, "WStKlay:: transfer failed");
    }

    /**
     * @notice Unwraps wstKlay to stKlay
     * @param amount amount of wstKlay to unwrap
     * @return unwrappedAmount amount of stKlay sent to user
     * Emits a `Transfer` event from msgSender to zero address
     */
    function unwrap(uint256 amount)
        external
        override
        nonZero(amount)
        returns (uint256 unwrappedAmount)
    {
        unwrappedAmount = getUnwrappedAmount(amount);

        _burn(_msgSender(), amount);

        bool success = stKlay.transfer(_msgSender(), unwrappedAmount);
        require(success, "WStKlay:: transfer failed");
    }

    /**
     * @notice Returns amount of wstKlay for corresponding stKlay
     */
    function getWrappedAmount(uint256 amount)
        public
        view
        returns (uint256 wrappedAmount)
    {
        wrappedAmount = stKlay.getSharesByKlay(amount) / 10**9;
    }

    /**
     * @notice Returns amount of stKlay for corresponding wstKlay
     */
    function getUnwrappedAmount(uint256 amount)
        public
        view
        returns (uint256 unwrappedAmount)
    {
        unwrappedAmount = stKlay.getKlayByShares(amount * 10**9);
    }
}
