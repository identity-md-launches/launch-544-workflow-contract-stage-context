// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @dev Random transfers, approvals and burns among a set of holders, plus attempts at every admin
/// selector a backdoored token would expose. Every call either succeeds within the bounds or is an
/// attempt that is expected to fail and is checked for leaving no trace.
contract LaunchTokenHandler is Test {
    LaunchToken public token;
    address[] public actors;

    uint256 public ghostBurned;
    mapping(bytes32 => uint256) public calls;

    constructor(LaunchToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transfer"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed a balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender lost a different amount");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient got a different amount");
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transferFrom"]++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.allowance(from, spender), 0, "allowance not fully spent");
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls["approve"]++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        calls["burn"]++;
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.burn(amount);
        ghostBurned += amount;
    }

    function burnFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        calls["burnFrom"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        token.burnFrom(owner, amount);
        ghostBurned += amount;
    }

    /// @notice Over-spend attempts: transferring one wei more than held must fail and move nothing.
    function transferTooMuch(uint256 fromSeed, uint256 toSeed) external {
        calls["transferTooMuch"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 supply = token.totalSupply();
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, balance + 1)));
        assertFalse(ok, "transferred more than held");
        assertEq(token.balanceOf(from), balance);
        assertEq(token.totalSupply(), supply);
    }

    /// @notice Burning more than held, or more than allowed, must fail and move nothing.
    function burnTooMuch(uint256 actorSeed) external {
        calls["burnTooMuch"]++;
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        uint256 supply = token.totalSupply();
        vm.prank(actor);
        (bool ok,) = address(token).call(abi.encodeCall(token.burn, (balance + 1)));
        assertFalse(ok, "burned more than held");
        assertEq(token.balanceOf(actor), balance);
        assertEq(token.totalSupply(), supply);
    }

    function burnFromWithoutAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        calls["burnFromWithoutAllowance"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        token.approve(spender, 0);
        amount = bound(amount, 1, type(uint128).max);
        uint256 balance = token.balanceOf(owner);
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.burnFrom, (owner, amount)));
        assertFalse(ok, "burned without allowance");
        assertEq(token.balanceOf(owner), balance);
    }

    /// @notice Hit the usual admin / mint selectors from a random actor; none may exist.
    function tryAdminCall(uint256 actorSeed, uint256 which, uint256 amount) external {
        calls["tryAdminCall"]++;
        address actor = _actor(actorSeed);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        string memory sig = signatures[bound(which, 0, signatures.length - 1)];
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(actor);
        vm.prank(actor);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, actor, amount));
        assertFalse(ok, sig);
        assertEq(token.totalSupply(), supply, sig);
        assertEq(token.balanceOf(actor), balance, sig);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LaunchToken internal token;
    LaunchTokenHandler internal handler;
    address internal deployer = makeAddr("deployer");
    address[] internal actors;

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        vm.startPrank(deployer);
        token.transfer(actors[1], 1_000_000e18);
        token.transfer(actors[2], 1);
        vm.stopPrank();

        handler = new LaunchTokenHandler(token, actors);
        targetContract(address(handler));
    }

    /// @notice The supply never rises above what the constructor minted.
    function invariant_supplyNeverIncreases() public view {
        assertLe(token.totalSupply(), SUPPLY);
    }

    /// @notice The supply equals the mint minus every burn: nothing else creates or destroys tokens.
    function invariant_supplyIsMintMinusBurns() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned());
    }

    /// @notice All balances sum to the supply: transfers conserve, burns reduce both sides equally.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @notice No holder can end up with more than the whole supply, whatever the sequence.
    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(token.balanceOf(actors[i]), token.totalSupply());
        }
    }

    /// @notice Metadata is immutable.
    function invariant_metadataFixed() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.name(), "Guestbook Token");
        assertEq(token.symbol(), "GUEST");
    }
}
