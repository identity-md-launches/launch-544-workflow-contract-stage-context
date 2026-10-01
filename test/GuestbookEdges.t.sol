// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook, IBurnableToken} from "../src/Guestbook.sol";

/// @dev A contract that signs on its own behalf, to show the entry records the caller, not tx.origin.
contract ContractSigner {
    function signVia(Guestbook guestbook, LaunchToken token, string calldata message) external returns (uint256) {
        token.approve(address(guestbook), guestbook.SIGNING_FEE());
        return guestbook.sign(message);
    }
}

/// @dev A token whose burnFrom always reverts: the guestbook must then store nothing (atomicity).
contract RevertingToken is IBurnableToken {
    error Nope();

    function burnFrom(address, uint256) external pure {
        revert Nope();
    }
}

/// @dev A token that re-enters `sign` repeatedly from `burnFrom`, up to a depth, to probe id
/// assignment under nested calls deeper than one level.
contract DeepReenteringToken is IBurnableToken {
    Guestbook public guestbook;
    uint256 public depth;
    uint256 public maxDepth;
    uint256[] public idsSeen;

    constructor(uint256 maxDepth_) {
        maxDepth = maxDepth_;
    }

    function setGuestbook(Guestbook g) external {
        guestbook = g;
    }

    function burnFrom(address, uint256) external {
        if (depth < maxDepth) {
            depth++;
            idsSeen.push(guestbook.sign(string(abi.encodePacked("depth", depth))));
        }
    }

    function idsSeenLength() external view returns (uint256) {
        return idsSeen.length;
    }
}

/// @notice Edges the base suite does not reach: unlimited approvals, arbitrary message bytes,
/// caller identity, third-party approvals, timestamp extremes and atomicity against hostile tokens.
/// forge-config: default.fuzz.runs = 1000
contract GuestbookEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant FEE = 10e18;

    LaunchToken internal token;
    Guestbook internal guestbook;

    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Signed(uint256 indexed id, address indexed signer, uint256 timestamp, string message);

    function setUp() public {
        vm.startPrank(factory);
        token = new LaunchToken();
        guestbook = new Guestbook(address(token));
        token.transfer(alice, 1_000e18);
        token.transfer(bob, 1_000e18);
        vm.stopPrank();
    }

    // --- approvals ---

    /// @dev OpenZeppelin treats a max allowance as unlimited and does not decrement it. The README
    /// tells the website to approve exactly; this pins the behaviour it is warning about.
    function test_unlimitedApprovalIsNotDecremented() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), type(uint256).max);
        guestbook.sign("one");
        guestbook.sign("two");
        vm.stopPrank();
        assertEq(token.allowance(alice, address(guestbook)), type(uint256).max);
        assertEq(token.balanceOf(alice), 1_000e18 - 2 * FEE);
        assertEq(guestbook.entryCount(), 2);
    }

    function test_maxMinusOneApprovalIsDecremented() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), type(uint256).max - 1);
        guestbook.sign("one");
        vm.stopPrank();
        assertEq(token.allowance(alice, address(guestbook)), type(uint256).max - 1 - FEE);
    }

    /// @dev Approving someone other than the guestbook does not pay for a signature.
    function test_approvalToThirdPartyDoesNotPay() public {
        vm.startPrank(alice);
        token.approve(bob, FEE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), 0, FEE)
        );
        guestbook.sign("wrong spender");
        vm.stopPrank();
        assertEq(guestbook.entryCount(), 0);
    }

    /// @dev Alice's approval cannot be spent by Bob calling sign: the fee always comes from msg.sender.
    function test_callerPaysNotTheApprover() public {
        vm.prank(alice);
        token.approve(address(guestbook), FEE);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), 0, FEE)
        );
        guestbook.sign("on alice's dime?");

        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.allowance(alice, address(guestbook)), FEE);
        assertEq(guestbook.entryCount(), 0);
    }

    /// @dev An approval of 2 fees pays for exactly two signatures and the third fails.
    function test_approvalExhaustsAfterExactMultiple() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), 2 * FEE);
        guestbook.sign("a");
        guestbook.sign("b");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), 0, FEE)
        );
        guestbook.sign("c");
        vm.stopPrank();
        assertEq(guestbook.entryCount(), 2);
    }

    // --- message content ---

    /// @dev Arbitrary bytes, including NUL and 0xFF, round-trip unchanged. The contract measures
    /// bytes and stores bytes; it does not validate UTF-8.
    function testFuzz_arbitraryBytesRoundTrip(bytes memory raw) public {
        uint256 len = bound(raw.length, 1, 280);
        bytes memory buf = new bytes(len);
        bytes32 filler = keccak256(raw);
        for (uint256 i = 0; i < len; i++) {
            // Use the fuzzed bytes where they exist; past the input's end, fill from a hash so the
            // short-input case still exercises non-trivial content.
            buf[i] = i < raw.length ? raw[i] : filler[i % 32];
        }
        string memory message = string(buf);

        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        uint256 id = guestbook.sign(message);
        vm.stopPrank();

        assertEq(keccak256(bytes(guestbook.getEntry(id).message)), keccak256(buf));
        assertEq(bytes(guestbook.getEntry(id).message).length, len);
    }

    function test_singleNulByteIsAValidMessage() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        guestbook.sign(string(abi.encodePacked(bytes1(0))));
        vm.stopPrank();
        assertEq(bytes(guestbook.getEntry(0).message).length, 1);
        assertEq(bytes(guestbook.getEntry(0).message)[0], bytes1(0));
    }

    function test_sameMessageTwiceGetsTwoEntries() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), 2 * FEE);
        uint256 a = guestbook.sign("same");
        uint256 b = guestbook.sign("same");
        vm.stopPrank();
        assertEq(a, 0);
        assertEq(b, 1);
        assertEq(guestbook.getEntry(0).message, guestbook.getEntry(1).message);
        assertEq(token.totalSupply(), SUPPLY - 2 * FEE);
    }

    /// @dev Every length from 1 to 280 is accepted; the boundary is inclusive on both sides.
    function testFuzz_everyLengthInRangeAccepted(uint16 len) public {
        len = uint16(bound(len, 1, 280));
        bytes memory buf = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            buf[i] = bytes1(uint8(0x20 + (i % 90)));
        }
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        guestbook.sign(string(buf));
        vm.stopPrank();
        assertEq(bytes(guestbook.getEntry(0).message).length, len);
    }

    // --- caller identity ---

    function test_contractCallerIsRecordedAsSigner() public {
        ContractSigner signer = new ContractSigner();
        vm.prank(factory);
        token.transfer(address(signer), FEE);

        uint256 id = signer.signVia(guestbook, token, "from a contract");
        assertEq(guestbook.getEntry(id).signer, address(signer));
        assertEq(token.balanceOf(address(signer)), 0);
    }

    function test_eventIdMatchesReturnedIdAcrossSigners() public {
        vm.prank(alice);
        token.approve(address(guestbook), FEE);
        vm.prank(bob);
        token.approve(address(guestbook), FEE);

        vm.expectEmit(true, true, true, true, address(guestbook));
        emit Signed(0, alice, block.timestamp, "a");
        vm.prank(alice);
        assertEq(guestbook.sign("a"), 0);

        vm.expectEmit(true, true, true, true, address(guestbook));
        emit Signed(1, bob, block.timestamp, "b");
        vm.prank(bob);
        assertEq(guestbook.sign("b"), 1);
    }

    // --- timestamps ---

    function test_timestampStoredAtUint64Max() public {
        vm.warp(type(uint64).max);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        vm.expectEmit(true, true, true, true, address(guestbook));
        emit Signed(0, alice, type(uint64).max, "far future");
        guestbook.sign("far future");
        vm.stopPrank();
        assertEq(guestbook.getEntry(0).timestamp, type(uint64).max);
    }

    function test_timestampAtZero() public {
        vm.warp(0);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        guestbook.sign("genesis");
        vm.stopPrank();
        assertEq(guestbook.getEntry(0).timestamp, 0);
    }

    function testFuzz_timestampRoundTrips(uint64 ts) public {
        vm.warp(ts);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        guestbook.sign("t");
        vm.stopPrank();
        assertEq(guestbook.getEntry(0).timestamp, ts);
    }

    // --- reads on an empty book ---

    function test_emptyBookReads() public {
        assertEq(guestbook.entryCount(), 0);
        assertEq(guestbook.latestEntries(type(uint256).max).length, 0);
        assertEq(guestbook.entriesBefore(0, 0).length, 0);
        assertEq(guestbook.entriesBefore(type(uint256).max, type(uint256).max).length, 0);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryDoesNotExist.selector, 0, 0));
        guestbook.getEntry(0);
    }

    /// @dev For any book size and any page request, the page agrees with getEntry element-wise.
    function testFuzz_pagingAgreesWithGetEntry(uint8 size, uint256 beforeId, uint256 count) public {
        size = uint8(bound(size, 0, 12));
        vm.startPrank(alice);
        token.approve(address(guestbook), uint256(size) * FEE);
        for (uint256 i = 0; i < size; i++) {
            guestbook.sign(string(abi.encodePacked("e", vm.toString(i))));
        }
        vm.stopPrank();

        uint256 end = beforeId < size ? beforeId : size;
        uint256 expected = count < end ? count : end;
        Guestbook.Entry[] memory page = guestbook.entriesBefore(beforeId, count);
        assertEq(page.length, expected);
        for (uint256 i = 0; i < page.length; i++) {
            assertEq(page[i].message, guestbook.getEntry(end - 1 - i).message);
        }

        Guestbook.Entry[] memory latest = guestbook.latestEntries(count);
        assertEq(latest.length, count < size ? count : size);
        for (uint256 i = 0; i < latest.length; i++) {
            assertEq(latest[i].message, guestbook.getEntry(size - 1 - i).message);
        }
    }

    // --- atomicity against hostile tokens (not the launch token) ---

    /// @dev If the burn reverts, the whole sign reverts: the entry pushed before the external call
    /// is rolled back and nothing is emitted.
    function test_revertingTokenStoresNothing() public {
        Guestbook g = new Guestbook(address(new RevertingToken()));
        vm.prank(alice);
        vm.expectRevert(RevertingToken.Nope.selector);
        g.sign("never stored");
        assertEq(g.entryCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryDoesNotExist.selector, 0, 0));
        g.getEntry(0);
    }

    /// @dev Nested re-entry three levels deep: ids are still 0,1,2,3 and the outer call's id is 0.
    function test_deepReentryKeepsIdsSequential() public {
        DeepReenteringToken hostile = new DeepReenteringToken(3);
        Guestbook g = new Guestbook(address(hostile));
        hostile.setGuestbook(g);

        vm.prank(alice);
        uint256 outer = g.sign("outer");

        assertEq(outer, 0);
        assertEq(g.entryCount(), 4);
        assertEq(hostile.idsSeenLength(), 3);
        // Inner-most sign finishes first, so the token sees ids 3, 2, 1 in push order.
        assertEq(hostile.idsSeen(0), 3);
        assertEq(hostile.idsSeen(1), 2);
        assertEq(hostile.idsSeen(2), 1);
        assertEq(g.getEntry(0).signer, alice);
        for (uint256 id = 1; id < 4; id++) {
            assertEq(g.getEntry(id).signer, address(hostile));
        }
        Guestbook.Entry[] memory latest = g.latestEntries(4);
        assertEq(latest[3].message, "outer");
    }

    // --- no selector that is not in the ABI ---

    function test_unknownSelectorsRevert() public {
        bytes[6] memory attempts = [
            abi.encodeWithSignature("deleteEntry(uint256)", 0),
            abi.encodeWithSignature("editEntry(uint256,string)", 0, "x"),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("setToken(address)", alice),
            abi.encodeWithSignature("owner()"),
            bytes("")
        ];
        for (uint256 i = 0; i < attempts.length; i++) {
            vm.prank(alice);
            (bool ok,) = address(guestbook).call(attempts[i]);
            assertFalse(ok);
        }
    }
}
