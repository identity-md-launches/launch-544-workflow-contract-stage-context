// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook} from "../src/Guestbook.sol";

/// @title Deploy
/// @notice Local and development deployment of the guestbook project.
/// @dev The production launch is performed by the ProjectFactory from launch.json, not by this script:
/// the factory deploys LaunchToken, splits its supply by policy, and then deploys Guestbook with the
/// token address. This script reproduces that wiring on a local chain so the website and tests can run
/// against real bytecode. `run()` reads the environment; everything it does is delegated to functions
/// that take their configuration as arguments and are called directly from tests.
contract Deploy is Script {
    /// @notice Deploy the launch token and a guestbook bound to it, as the factory would.
    function deployAll() public returns (LaunchToken token, Guestbook guestbook) {
        token = new LaunchToken();
        guestbook = deployGuestbook(address(token));
    }

    /// @notice Deploy only the guestbook against an existing token.
    function deployGuestbook(address token) public returns (Guestbook guestbook) {
        guestbook = new Guestbook(token);
    }

    /// @notice Broadcast entry point. Set GUESTBOOK_TOKEN to deploy the guestbook against an existing
    /// token; leave it unset to deploy both contracts.
    function run() external {
        address existingToken = vm.envOr("GUESTBOOK_TOKEN", address(0));
        vm.startBroadcast();
        if (existingToken == address(0)) {
            deployAll();
        } else {
            deployGuestbook(existingToken);
        }
        vm.stopBroadcast();
    }
}
