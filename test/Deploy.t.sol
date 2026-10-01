// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook} from "../src/Guestbook.sol";

contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function test_deployAllWiresGuestbookToFreshToken() public {
        (LaunchToken token, Guestbook guestbook) = deployer.deployAll();
        assertEq(address(guestbook.TOKEN()), address(token));
        assertEq(token.totalSupply(), 1_000_000_000e18);
        // The script contract deployed the token, so it holds the supply, as the factory would.
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000e18);
        assertEq(guestbook.entryCount(), 0);
    }

    function test_deployGuestbookAgainstExistingToken() public {
        LaunchToken token = new LaunchToken();
        Guestbook guestbook = deployer.deployGuestbook(address(token));
        assertEq(address(guestbook.TOKEN()), address(token));

        token.approve(address(guestbook), 10e18);
        guestbook.sign("deployed");
        assertEq(guestbook.entryCount(), 1);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 10e18);
    }

    function test_deployGuestbookRejectsBadToken() public {
        vm.expectRevert(Guestbook.ZeroToken.selector);
        deployer.deployGuestbook(address(0));
    }
}
