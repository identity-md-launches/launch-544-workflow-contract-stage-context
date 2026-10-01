// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LaunchToken internal token;
    address internal deployer;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployer = address(this);
        token = new LaunchToken();
    }

    // --- supply and metadata ---

    function test_mintsExactlyOneBillionTokensToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_metadata() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Guestbook Token");
        assertEq(token.symbol(), "GUEST");
    }

    function test_deployerIsWhoeverDeploys() public {
        vm.prank(alice);
        LaunchToken other = new LaunchToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
    }

    // --- transfers ---

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromWithinAllowance() public {
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 60e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 60e18));
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        token.transfer(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // --- burning: supply can only go down ---

    function test_burnReducesSupplyAndBalance() public {
        token.transfer(alice, 50e18);
        vm.prank(alice);
        token.burn(20e18);
        assertEq(token.balanceOf(alice), 30e18);
        assertEq(token.totalSupply(), SUPPLY - 20e18);
    }

    function test_burnFromSpendsAllowance() public {
        token.transfer(alice, 50e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        token.burnFrom(alice, 10e18);
        assertEq(token.balanceOf(alice), 40e18);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_burnFromRevertsWithoutAllowance() public {
        token.transfer(alice, 50e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 10e18));
        token.burnFrom(alice, 10e18);
    }

    function test_burnRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    // --- no admin surface ---

    function test_noMintOrAdminSelectorIncreasesSupply() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
        // Not even the deployer can mint.
        (bool deployerOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(deployerOk);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF, "forbidden opcode");
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
