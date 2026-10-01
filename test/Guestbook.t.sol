// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook, IBurnableToken} from "../src/Guestbook.sol";

/// @dev A token that re-enters the guestbook from inside `burnFrom`, to show a hostile token could
/// only append an extra entry and never corrupt ids or ordering. The real launch token has no hooks.
contract ReenteringToken is IBurnableToken {
    Guestbook public guestbook;
    uint256 public burnCalls;
    bool private reentered;

    function setGuestbook(Guestbook g) external {
        guestbook = g;
    }

    function burnFrom(address, uint256) external {
        burnCalls++;
        if (!reentered) {
            reentered = true;
            guestbook.sign("reentered");
        }
    }
}

contract GuestbookTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant FEE = 10e18;

    LaunchToken internal token;
    Guestbook internal guestbook;

    /// @dev Stands in for the launch factory: deploys the token (receiving the supply) and then the
    /// guestbook, exactly as the manifest orders it.
    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Signed(uint256 indexed id, address indexed signer, uint256 timestamp, string message);

    function setUp() public {
        vm.startPrank(factory);
        token = new LaunchToken();
        guestbook = new Guestbook(address(token));
        vm.stopPrank();

        // Fund two users from the supply the factory holds.
        vm.startPrank(factory);
        token.transfer(alice, 100e18);
        token.transfer(bob, 25e18);
        vm.stopPrank();
    }

    // --- constructor ---

    function test_constructorWiresTokenAndConstants() public view {
        assertEq(address(guestbook.TOKEN()), address(token));
        assertEq(guestbook.SIGNING_FEE(), 10 ether);
        assertEq(guestbook.MAX_MESSAGE_BYTES(), 280);
        assertEq(guestbook.entryCount(), 0);
    }

    function test_constructorDoesNotTouchTheSupply() public {
        vm.startPrank(factory);
        LaunchToken fresh = new LaunchToken();
        new Guestbook(address(fresh));
        vm.stopPrank();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(factory), SUPPLY);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(Guestbook.ZeroToken.selector);
        new Guestbook(address(0));
    }

    function test_constructorRejectsTokenWithoutCode() public {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(Guestbook.TokenNotAContract.selector, noCode));
        new Guestbook(noCode);
    }

    // --- signing: success ---

    function test_signBurnsFeeAndStoresEntry() public {
        vm.warp(1_700_000_000);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);

        vm.expectEmit(true, true, true, true, address(guestbook));
        emit Signed(0, alice, 1_700_000_000, "hello world");
        uint256 id = guestbook.sign("hello world");
        vm.stopPrank();

        assertEq(id, 0);
        assertEq(guestbook.entryCount(), 1);

        Guestbook.Entry memory e = guestbook.getEntry(0);
        assertEq(e.signer, alice);
        assertEq(e.timestamp, 1_700_000_000);
        assertEq(e.message, "hello world");

        // Fee burned: signer lost 10, nobody gained, supply shrank.
        assertEq(token.balanceOf(alice), 90e18);
        assertEq(token.balanceOf(address(guestbook)), 0);
        assertEq(token.totalSupply(), SUPPLY - FEE);
        assertEq(token.allowance(alice, address(guestbook)), 0);
    }

    function test_signAcceptsExactly280Bytes() public {
        string memory msg280 = _repeat("a", 280);
        assertEq(bytes(msg280).length, 280);
        _approveAndSign(alice, msg280);
        assertEq(bytes(guestbook.getEntry(0).message).length, 280);
    }

    function test_signCountsBytesNotCharacters() public {
        // 70 copies of a 4-byte emoji = 280 bytes: accepted.
        string memory ok = _repeat(unicode"🙂", 70);
        assertEq(bytes(ok).length, 280);
        _approveAndSign(alice, ok);
        // 71 copies = 284 bytes: rejected, even though it is only 71 characters.
        string memory tooLong = _repeat(unicode"🙂", 71);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 284, 280));
        guestbook.sign(tooLong);
        vm.stopPrank();
    }

    function test_multipleSignersGetSequentialIds() public {
        _approveAndSign(alice, "first");
        _approveAndSign(bob, "second");
        _approveAndSign(alice, "third");

        assertEq(guestbook.entryCount(), 3);
        assertEq(guestbook.getEntry(0).message, "first");
        assertEq(guestbook.getEntry(1).signer, bob);
        assertEq(guestbook.getEntry(2).message, "third");
        assertEq(token.balanceOf(alice), 80e18);
        assertEq(token.balanceOf(bob), 15e18);
        assertEq(token.totalSupply(), SUPPLY - 3 * FEE);
    }

    function test_signWithExactBalanceSucceeds() public {
        address carol = makeAddr("carol");
        vm.prank(factory);
        token.transfer(carol, FEE);
        _approveAndSign(carol, "all in");
        assertEq(token.balanceOf(carol), 0);
    }

    function test_largerApprovalIsSpentOnlyByTheFee() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), 30e18);
        guestbook.sign("one");
        guestbook.sign("two");
        vm.stopPrank();
        assertEq(token.allowance(alice, address(guestbook)), 10e18);
        assertEq(token.balanceOf(alice), 80e18);
    }

    function testFuzz_signConservesTokens(uint8 signatures, uint16 length) public {
        signatures = uint8(bound(signatures, 1, 10));
        length = uint16(bound(length, 1, 280));
        string memory message = _repeat("x", length);

        vm.startPrank(alice);
        token.approve(address(guestbook), uint256(signatures) * FEE);
        for (uint256 i = 0; i < signatures; i++) {
            assertEq(guestbook.sign(message), i);
        }
        vm.stopPrank();

        uint256 burned = uint256(signatures) * FEE;
        assertEq(guestbook.entryCount(), signatures);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(factory), SUPPLY - burned);
        assertEq(token.balanceOf(address(guestbook)), 0);
    }

    // --- signing: failure ---

    function test_signRevertsWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), 0, FEE)
        );
        guestbook.sign("no approval");
        assertEq(guestbook.entryCount(), 0);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_signRevertsWithPartialApproval() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), FEE - 1, FEE)
        );
        guestbook.sign("almost");
        vm.stopPrank();
        assertEq(guestbook.entryCount(), 0);
    }

    function test_signRevertsWithInsufficientBalance() public {
        address poor = makeAddr("poor");
        vm.prank(factory);
        token.transfer(poor, FEE - 1);
        vm.startPrank(poor);
        token.approve(address(guestbook), FEE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, FEE - 1, FEE));
        guestbook.sign("broke");
        vm.stopPrank();
        assertEq(guestbook.entryCount(), 0);
        assertEq(token.balanceOf(poor), FEE - 1);
    }

    function test_signRevertsOnEmptyMessage() public {
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        vm.expectRevert(Guestbook.EmptyMessage.selector);
        guestbook.sign("");
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_signRevertsOn281Bytes() public {
        string memory msg281 = _repeat("b", 281);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 281, 280));
        guestbook.sign(msg281);
        vm.stopPrank();
        assertEq(guestbook.entryCount(), 0);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function testFuzz_signRevertsAboveMax(uint16 length) public {
        length = uint16(bound(length, 281, 2000));
        string memory message = _repeat("c", length);
        vm.startPrank(alice);
        token.approve(address(guestbook), FEE);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, length, 280));
        guestbook.sign(message);
        vm.stopPrank();
    }

    function test_failedSignLeavesNoEntryAndBurnsNothing() public {
        _approveAndSign(alice, "kept");
        vm.prank(bob);
        vm.expectRevert();
        guestbook.sign("unpaid");
        assertEq(guestbook.entryCount(), 1);
        assertEq(token.totalSupply(), SUPPLY - FEE);
    }

    // --- reading ---

    function test_getEntryRevertsForUnknownId() public {
        _approveAndSign(alice, "only");
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryDoesNotExist.selector, 1, 1));
        guestbook.getEntry(1);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryDoesNotExist.selector, type(uint256).max, 1));
        guestbook.getEntry(type(uint256).max);
    }

    function test_latestEntriesNewestFirst() public {
        _approveAndSign(alice, "m0");
        _approveAndSign(bob, "m1");
        _approveAndSign(alice, "m2");

        Guestbook.Entry[] memory page = guestbook.latestEntries(2);
        assertEq(page.length, 2);
        assertEq(page[0].message, "m2");
        assertEq(page[1].message, "m1");
        assertEq(page[1].signer, bob);
    }

    function test_latestEntriesClampsToCount() public {
        assertEq(guestbook.latestEntries(5).length, 0);
        assertEq(guestbook.latestEntries(0).length, 0);
        _approveAndSign(alice, "m0");
        _approveAndSign(alice, "m1");
        Guestbook.Entry[] memory page = guestbook.latestEntries(50);
        assertEq(page.length, 2);
        assertEq(page[0].message, "m1");
        assertEq(page[1].message, "m0");
        assertEq(guestbook.latestEntries(0).length, 0);
    }

    function test_entriesBeforePagesBackwards() public {
        for (uint256 i = 0; i < 5; i++) {
            _approveAndSign(alice, string(abi.encodePacked("m", vm.toString(i))));
        }
        // Page 1: the newest two.
        Guestbook.Entry[] memory p1 = guestbook.entriesBefore(5, 2);
        assertEq(p1.length, 2);
        assertEq(p1[0].message, "m4");
        assertEq(p1[1].message, "m3");
        // Page 2: ids below 3.
        Guestbook.Entry[] memory p2 = guestbook.entriesBefore(3, 2);
        assertEq(p2[0].message, "m2");
        assertEq(p2[1].message, "m1");
        // Page 3: only m0 remains.
        Guestbook.Entry[] memory p3 = guestbook.entriesBefore(1, 2);
        assertEq(p3.length, 1);
        assertEq(p3[0].message, "m0");
        // Past the beginning: empty.
        assertEq(guestbook.entriesBefore(0, 2).length, 0);
        // beforeId above the count clamps to the count.
        Guestbook.Entry[] memory p4 = guestbook.entriesBefore(type(uint256).max, 1);
        assertEq(p4.length, 1);
        assertEq(p4[0].message, "m4");
    }

    // --- no privileged surface, no custody ---

    function test_factoryHasNoSpecialPowers() public {
        // The deployer (factory) cannot sign for free, delete or edit entries.
        vm.prank(factory);
        vm.expectRevert();
        guestbook.sign("free?");

        bytes[3] memory attempts = [
            abi.encodeWithSignature("transferOwnership(address)", factory),
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i = 0; i < attempts.length; i++) {
            vm.prank(factory);
            (bool ok,) = address(guestbook).call(attempts[i]);
            assertFalse(ok);
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(guestbook).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(guestbook).balance, 0);
    }

    function test_runtimeWithinSizeLimitAndNoEscapeOpcodes() public view {
        bytes memory code = address(guestbook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j = 0; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden project opcode");
        }
    }

    // --- adversarial token (not the launch token) ---

    function test_reentrantTokenOnlyAppendsAnotherEntry() public {
        ReenteringToken hostile = new ReenteringToken();
        Guestbook g = new Guestbook(address(hostile));
        hostile.setGuestbook(g);

        vm.prank(alice);
        uint256 id = g.sign("outer");

        assertEq(id, 0);
        assertEq(g.entryCount(), 2);
        assertEq(g.getEntry(0).message, "outer");
        assertEq(g.getEntry(0).signer, alice);
        assertEq(g.getEntry(1).message, "reentered");
        assertEq(g.getEntry(1).signer, address(hostile));
        assertEq(hostile.burnCalls(), 2, "each entry still paid its own fee call");
    }

    // --- helpers ---

    function _approveAndSign(address who, string memory message) internal returns (uint256 id) {
        vm.startPrank(who);
        token.approve(address(guestbook), FEE);
        id = guestbook.sign(message);
        vm.stopPrank();
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        bytes memory u = bytes(unit);
        bytes memory buf = new bytes(u.length * times);
        for (uint256 i = 0; i < times; i++) {
            for (uint256 j = 0; j < u.length; j++) {
                buf[i * u.length + j] = u[j];
            }
        }
        out = string(buf);
    }
}
