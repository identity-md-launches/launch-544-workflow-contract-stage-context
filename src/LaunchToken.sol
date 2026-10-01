// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title LaunchToken
/// @notice The fixed-supply launch token of the onchain guestbook.
/// @dev The whole supply (1,000,000,000 tokens, 18 decimals) is minted once, to the deployer, in the
/// constructor. The launch factory is that deployer and splits the supply by policy; nothing here
/// mints, holds or forwards any of it.
///
/// There is no owner, no mint path, no pause, no blocklist, no transfer fee and no upgrade hook.
/// The only non-standard surface is `burn` / `burnFrom` from OpenZeppelin's ERC20Burnable: a holder
/// (or a spender inside its allowance) can destroy tokens it already controls. Supply can only go
/// down, never up. The guestbook relies on `burnFrom` to burn the signing fee.
contract LaunchToken is ERC20Burnable {
    /// @notice Total supply in minor units: 10^9 tokens * 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Guestbook Token", "GUEST") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
