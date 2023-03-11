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

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UnstakingReceiver is Ownable {
    using Address for address payable;

    mapping(address => bool) private isNodeHandler;

    constructor() {}

    receive() external payable {}

    function setHandler(address handler, bool isNodeHandler_)
        external
        onlyOwner
    {
        isNodeHandler[handler] = isNodeHandler_;
    }

    function withdraw(address to) external {
        require(
            isNodeHandler[msg.sender],
            "UnstakingReceiver:: Not nodeHandler"
        );
        uint256 amount = address(this).balance;
        if (amount > 0) payable(to).sendValue(amount);
    }
}
