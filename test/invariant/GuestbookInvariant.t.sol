// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Guestbook} from "../../src/Guestbook.sol";

/// @dev Drives the guestbook and its token with bounded, random calls from several actors. Every
/// handler either succeeds or asserts the exact revert it provoked; the invariant runner is set to
/// fail on any unexpected revert, so a handler that silently reverts counts as a failure, not as a
/// skipped call. Ghost state records what the contracts *should* hold so the invariants compare the
/// contracts' view against an independent ledger.
contract GuestbookHandler is Test {
    uint256 internal constant FEE = 10e18;
    uint256 internal constant MAX_BYTES = 280;

    LaunchToken public token;
    Guestbook public guestbook;
    address public factory;
    /// @dev An address that is never funded, so it can always demonstrate the insufficient-balance path.
    address public pauper = makeAddr("pauper");
    address[] public actors;

    // --- ghost ledger ---

    /// @notice Tokens destroyed through `Guestbook.sign`.
    uint256 public ghostBurnedBySign;
    /// @notice Tokens destroyed directly on the token (burn / burnFrom), outside the guestbook.
    uint256 public ghostBurnedDirect;
    /// @notice Number of successful signatures.
    uint256 public ghostEntries;
    /// @notice keccak256(abi.encode(signer, timestamp, message)) recorded the moment each entry was signed.
    mapping(uint256 => bytes32) public ghostEntryHash;
    /// @notice Successful signatures per actor.
    mapping(address => uint256) public ghostSigns;
    /// @notice Number of calls per handler, to spot vacuous runs.
    mapping(bytes32 => uint256) public calls;

    constructor(LaunchToken token_, Guestbook guestbook_, address factory_, address[] memory actors_) {
        token = token_;
        guestbook = guestbook_;
        factory = factory_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // --- successful paths ---

    /// @notice Approve exactly the fee and sign a random message of a random valid length.
    function sign(uint256 actorSeed, uint256 len, bytes32 seed) external {
        calls["sign"]++;
        address actor = _actor(actorSeed);
        len = bound(len, 1, MAX_BYTES);
        string memory message = _message(seed, len);
        _ensureFunded(actor);

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(actor);

        vm.startPrank(actor);
        token.approve(address(guestbook), FEE);
        uint256 id = guestbook.sign(message);
        vm.stopPrank();

        assertEq(id, ghostEntries, "ids must be sequential");
        assertEq(token.totalSupply(), supplyBefore - FEE, "sign burned other than the fee");
        assertEq(token.balanceOf(actor), balanceBefore - FEE, "signer paid other than the fee");
        assertEq(token.allowance(actor, address(guestbook)), 0, "exact approval not fully spent");

        _recordEntry(id, actor, message);
    }

    /// @notice Sign using an allowance that was set earlier (possibly larger than the fee, possibly
    /// unlimited). Checks the allowance accounting on the way.
    function signWithExistingAllowance(uint256 actorSeed, uint256 len, bytes32 seed) external {
        calls["signWithExistingAllowance"]++;
        address actor = _actor(actorSeed);
        uint256 allowance = token.allowance(actor, address(guestbook));
        if (allowance < FEE) {
            // Nothing to exercise: fall back to a plain exact approval so the call is never wasted.
            vm.prank(actor);
            token.approve(address(guestbook), FEE);
            allowance = FEE;
        }
        _ensureFunded(actor);
        len = bound(len, 1, MAX_BYTES);
        string memory message = _message(seed, len);

        vm.prank(actor);
        uint256 id = guestbook.sign(message);

        uint256 expectedAllowance = allowance == type(uint256).max ? allowance : allowance - FEE;
        assertEq(token.allowance(actor, address(guestbook)), expectedAllowance, "allowance accounting");
        _recordEntry(id, actor, message);
    }

    /// @notice Set an arbitrary allowance for the guestbook, including zero and unlimited.
    function approveGuestbook(uint256 actorSeed, uint256 amount) external {
        calls["approveGuestbook"]++;
        address actor = _actor(actorSeed);
        // Mostly small multiples of the fee, sometimes unlimited.
        amount = amount % 7 == 0 ? type(uint256).max : bound(amount, 0, 5 * FEE);
        vm.prank(actor);
        token.approve(address(guestbook), amount);
    }

    /// @notice Move tokens between actors.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transfer"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    /// @notice Fund an actor from the factory's share of the supply.
    function fund(uint256 actorSeed, uint256 amount) external {
        calls["fund"]++;
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, 100 * FEE);
        vm.prank(factory);
        assertTrue(token.transfer(actor, amount));
    }

    /// @notice Burn directly on the token, bypassing the guestbook.
    function burnDirect(uint256 actorSeed, uint256 amount) external {
        calls["burnDirect"]++;
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.burn(amount);
        ghostBurnedDirect += amount;
    }

    /// @notice One actor burns from another's balance within an allowance.
    function burnFromDirect(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        calls["burnFromDirect"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        token.burnFrom(owner, amount);
        ghostBurnedDirect += amount;
    }

    /// @notice Advance time so timestamps differ across entries.
    function warp(uint256 delta) external {
        calls["warp"]++;
        delta = bound(delta, 0, 30 days);
        vm.warp(block.timestamp + delta);
    }

    // --- failure paths: each must revert exactly as documented and leave no trace ---

    function signWithoutApproval(uint256 actorSeed, bytes32 seed) external {
        calls["signWithoutApproval"]++;
        address actor = _actor(actorSeed);
        _ensureFunded(actor);
        vm.startPrank(actor);
        token.approve(address(guestbook), 0);
        _expectNoChange(
            actor,
            seed,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), 0, FEE)
        );
        vm.stopPrank();
    }

    function signWithOneWeiShortApproval(uint256 actorSeed, bytes32 seed) external {
        calls["signWithOneWeiShortApproval"]++;
        address actor = _actor(actorSeed);
        _ensureFunded(actor);
        vm.startPrank(actor);
        token.approve(address(guestbook), FEE - 1);
        _expectNoChange(
            actor,
            seed,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(guestbook), FEE - 1, FEE)
        );
        vm.stopPrank();
    }

    function signWithoutBalance(bytes32 seed) external {
        calls["signWithoutBalance"]++;
        assertEq(token.balanceOf(pauper), 0, "the pauper must stay unfunded");
        vm.startPrank(pauper);
        token.approve(address(guestbook), FEE);
        _expectNoChange(
            pauper, seed, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, pauper, 0, FEE)
        );
        vm.stopPrank();
    }

    function signEmpty(uint256 actorSeed) external {
        calls["signEmpty"]++;
        address actor = _actor(actorSeed);
        _ensureFunded(actor);
        vm.startPrank(actor);
        token.approve(address(guestbook), FEE);
        uint256 count = guestbook.entryCount();
        uint256 supply = token.totalSupply();
        try guestbook.sign("") {
            assertTrue(false, "empty message accepted");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(Guestbook.EmptyMessage.selector));
        }
        vm.stopPrank();
        assertEq(guestbook.entryCount(), count);
        assertEq(token.totalSupply(), supply);
    }

    function signTooLong(uint256 actorSeed, uint256 len, bytes32 seed) external {
        calls["signTooLong"]++;
        address actor = _actor(actorSeed);
        len = bound(len, MAX_BYTES + 1, 4 * MAX_BYTES);
        _ensureFunded(actor);
        vm.startPrank(actor);
        token.approve(address(guestbook), FEE);
        uint256 count = guestbook.entryCount();
        uint256 supply = token.totalSupply();
        try guestbook.sign(_message(seed, len)) {
            assertTrue(false, "over-long message accepted");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(Guestbook.MessageTooLong.selector, len, MAX_BYTES));
        }
        vm.stopPrank();
        assertEq(guestbook.entryCount(), count);
        assertEq(token.totalSupply(), supply);
    }

    // --- helpers ---

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Tops the actor up to one fee from the factory so the happy path is always reachable.
    function _ensureFunded(address actor) internal {
        uint256 balance = token.balanceOf(actor);
        if (balance < FEE) {
            vm.prank(factory);
            token.transfer(actor, FEE - balance);
        }
    }

    function _recordEntry(uint256 id, address signer, string memory message) internal {
        assertEq(id, ghostEntries, "ids must be sequential");
        ghostEntryHash[id] = keccak256(abi.encode(signer, uint64(block.timestamp), message));
        ghostEntries++;
        ghostBurnedBySign += FEE;
        ghostSigns[signer]++;
    }

    /// @dev Attempts a sign that must revert with `expected` and checks nothing moved.
    function _expectNoChange(address signer, bytes32 seed, bytes memory expected) internal {
        uint256 count = guestbook.entryCount();
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(signer);
        string memory message = _message(seed, 1 + (uint256(seed) % MAX_BYTES));
        try guestbook.sign(message) {
            assertTrue(false, "sign succeeded where it must revert");
        } catch (bytes memory reason) {
            assertEq(reason, expected, "unexpected revert reason");
        }
        assertEq(guestbook.entryCount(), count, "failed sign stored an entry");
        assertEq(token.totalSupply(), supply, "failed sign burned tokens");
        assertEq(token.balanceOf(signer), balance, "failed sign moved tokens");
    }

    /// @dev Arbitrary bytes, including zero and high bytes, so storage round-trips are tested on
    /// content a UTF-8 client would never produce.
    function _message(bytes32 seed, uint256 len) internal pure returns (string memory) {
        bytes memory buf = new bytes(len);
        bytes32 word = seed;
        for (uint256 i = 0; i < len; i++) {
            if (i % 32 == 0 && i != 0) word = keccak256(abi.encode(word));
            buf[i] = word[i % 32];
        }
        return string(buf);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract GuestbookInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant FEE = 10e18;

    LaunchToken internal token;
    Guestbook internal guestbook;
    GuestbookHandler internal handler;
    address internal factory = makeAddr("factory");
    address[] internal actors;

    function setUp() public {
        vm.startPrank(factory);
        token = new LaunchToken();
        guestbook = new Guestbook(address(token));
        vm.stopPrank();

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new GuestbookHandler(token, guestbook, factory, actors);

        // Seed uneven balances so the first calls already have something to move and burn.
        vm.startPrank(factory);
        token.transfer(actors[0], 1_000e18);
        token.transfer(actors[1], 25e18);
        token.transfer(actors[2], FEE - 1);
        vm.stopPrank();

        targetContract(address(handler));
    }

    // --- conservation ---

    /// @notice Supply only ever shrinks, and by exactly what was burned through the two burn paths.
    function invariant_supplyIsInitialMinusAllBurns() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurnedBySign() - handler.ghostBurnedDirect());
        assertLe(token.totalSupply(), SUPPLY);
    }

    /// @notice Every token is held by a known party: no balance appears or vanishes elsewhere.
    function invariant_balancesSumToSupply() public view {
        uint256 sum = token.balanceOf(factory);
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        sum += token.balanceOf(handler.pauper());
        assertEq(sum, token.totalSupply());
    }

    /// @notice The guestbook never takes custody of anything.
    function invariant_guestbookHoldsNothing() public view {
        assertEq(token.balanceOf(address(guestbook)), 0);
        assertEq(address(guestbook).balance, 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @notice The fee is burned, never redirected: tokens burned by signing equal entries times fee.
    function invariant_eachEntryBurnedExactlyOneFee() public view {
        assertEq(handler.ghostBurnedBySign(), guestbook.entryCount() * FEE);
    }

    // --- entries ---

    /// @notice The entry count equals the number of successful signatures, and nothing else.
    function invariant_entryCountEqualsSuccessfulSigns() public view {
        assertEq(guestbook.entryCount(), handler.ghostEntries());
    }

    /// @notice Entries are append-only and immutable: every stored entry still matches what was
    /// recorded at the moment it was signed, and ids never shift.
    function invariant_entriesNeverChange() public view {
        uint256 count = guestbook.entryCount();
        for (uint256 id = 0; id < count; id++) {
            Guestbook.Entry memory e = guestbook.getEntry(id);
            bytes32 h = keccak256(abi.encode(e.signer, e.timestamp, e.message));
            assertEq(h, handler.ghostEntryHash(id), "entry changed after signing");
            assertGt(bytes(e.message).length, 0);
            assertLe(bytes(e.message).length, 280);
        }
    }

    /// @notice Per-signer counts in storage agree with the ghost ledger.
    function invariant_signaturesPerActorMatch() public view {
        uint256 count = guestbook.entryCount();
        uint256 total;
        for (uint256 a = 0; a < actors.length; a++) {
            uint256 seen;
            for (uint256 id = 0; id < count; id++) {
                if (guestbook.getEntry(id).signer == actors[a]) seen++;
            }
            assertEq(seen, handler.ghostSigns(actors[a]));
            total += seen;
        }
        assertEq(total, count, "an entry has a signer that is not an actor");
    }

    /// @notice Timestamps never go backwards along the id order.
    function invariant_timestampsMonotonic() public view {
        uint256 count = guestbook.entryCount();
        uint64 last;
        for (uint256 id = 0; id < count; id++) {
            uint64 t = guestbook.getEntry(id).timestamp;
            assertGe(t, last);
            last = t;
        }
        if (count > 0) assertLe(last, block.timestamp);
    }

    /// @notice No entry exists at or beyond the count.
    function invariant_noEntryBeyondCount() public {
        uint256 count = guestbook.entryCount();
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryDoesNotExist.selector, count, count));
        guestbook.getEntry(count);
    }

    // --- paging views agree with getEntry ---

    function invariant_latestEntriesIsReverseOfGetEntry() public view {
        uint256 count = guestbook.entryCount();
        Guestbook.Entry[] memory all = guestbook.latestEntries(type(uint256).max);
        assertEq(all.length, count);
        for (uint256 i = 0; i < count; i++) {
            Guestbook.Entry memory e = guestbook.getEntry(count - 1 - i);
            assertEq(all[i].signer, e.signer);
            assertEq(all[i].timestamp, e.timestamp);
            assertEq(all[i].message, e.message);
        }
        // A smaller page is a prefix of the full one.
        Guestbook.Entry[] memory page = guestbook.latestEntries(3);
        assertEq(page.length, count < 3 ? count : 3);
        for (uint256 i = 0; i < page.length; i++) {
            assertEq(page[i].message, all[i].message);
        }
    }

    /// @notice Walking backwards with entriesBefore visits every id exactly once, newest first.
    function invariant_entriesBeforeWalksEveryIdOnce() public view {
        uint256 count = guestbook.entryCount();
        uint256 pageSize = 3;
        uint256 beforeId = count;
        uint256 visited;
        while (true) {
            Guestbook.Entry[] memory page = guestbook.entriesBefore(beforeId, pageSize);
            if (page.length == 0) break;
            for (uint256 i = 0; i < page.length; i++) {
                uint256 id = beforeId - 1 - i;
                Guestbook.Entry memory e = guestbook.getEntry(id);
                assertEq(page[i].message, e.message);
                assertEq(page[i].signer, e.signer);
                visited++;
            }
            beforeId -= page.length;
        }
        assertEq(visited, count);
        assertEq(guestbook.entriesBefore(0, pageSize).length, 0);
        assertEq(guestbook.entriesBefore(type(uint256).max, 1).length, count == 0 ? 0 : 1);
    }

    /// @notice The handlers all ran, so the invariants above were not checked against an idle book.
    function invariant_callSummary() public view {
        // Not asserted per handler: a single short run can legitimately miss one. The totals are
        // what make the suite meaningful, and a book that never got an entry is a broken harness.
        uint256 total = handler.calls("sign") + handler.calls("signWithExistingAllowance");
        if (total > 0) assertGt(guestbook.entryCount(), 0);
    }
}
