// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The only token surface the guestbook needs: destroy tokens from an account within the
/// caller's allowance. LaunchToken implements it via OpenZeppelin's ERC20Burnable.
interface IBurnableToken {
    function burnFrom(address account, uint256 value) external;
}

/// @title Guestbook
/// @notice An onchain guestbook paid in the launch token. Signing burns exactly 10 tokens from the
/// signer and stores a message of at most 280 bytes, forever, in contract storage.
/// @dev Design notes
///
/// - The fee is burned, not collected: `burnFrom` reduces the token's total supply. The guestbook
///   never holds tokens, never holds ETH, and has no owner, pause, withdraw or upgrade path.
/// - Entries are append-only. Nothing can edit or delete an entry once signed.
/// - A signer must first approve the guestbook for at least `SIGNING_FEE` on the token. The approval
///   should be exact (10 tokens per intended signature), never unlimited.
/// - The token address is immutable and set by the launch factory from the manifest (`$token`).
///   The factory is `msg.sender` of the constructor, and the guestbook deliberately grants it no role.
/// - Message length is measured in bytes, not characters. Multi-byte UTF-8 counts per byte.
/// - Checks-effects-interactions: the entry is stored and the event emitted before the external
///   burn call. The token is the trusted launch token with no transfer hooks, so a reentrancy guard
///   is unnecessary; even a reentrant `sign` would only append another, independently paid, entry.
contract Guestbook {
    /// @notice One guestbook entry.
    /// @param signer The wallet that signed and paid the fee.
    /// @param timestamp The block timestamp at which the entry was signed.
    /// @param message The stored message (1..280 bytes).
    struct Entry {
        address signer;
        uint64 timestamp;
        string message;
    }

    /// @notice Tokens burned per signature, in minor units (10 tokens at 18 decimals).
    uint256 public constant SIGNING_FEE = 10 ether;

    /// @notice Maximum message length in bytes.
    uint256 public constant MAX_MESSAGE_BYTES = 280;

    /// @notice The launch token whose `burnFrom` pays for each signature.
    IBurnableToken public immutable TOKEN;

    Entry[] private _entries;

    /// @notice Emitted once per signature.
    /// @param id The entry's index; ids are sequential from zero and never reused.
    /// @param signer The wallet that signed.
    /// @param timestamp The block timestamp of the signature.
    /// @param message The stored message.
    event Signed(uint256 indexed id, address indexed signer, uint256 timestamp, string message);

    error ZeroToken();
    error TokenNotAContract(address token);
    error EmptyMessage();
    error MessageTooLong(uint256 length, uint256 maxLength);
    error EntryDoesNotExist(uint256 id, uint256 count);

    /// @param token_ The launch token. Must already be deployed; the manifest passes `$token`.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        if (token_.code.length == 0) revert TokenNotAContract(token_);
        TOKEN = IBurnableToken(token_);
    }

    /// @notice Sign the guestbook. Burns `SIGNING_FEE` tokens from the caller and stores `message`.
    /// @dev Reverts if the message is empty or longer than `MAX_MESSAGE_BYTES`, or if the caller has
    /// not approved the guestbook for the fee or does not hold it (the token reverts in both cases).
    /// @param message The message to store, at most 280 bytes.
    /// @return id The index of the new entry.
    function sign(string calldata message) external returns (uint256 id) {
        uint256 length = bytes(message).length;
        if (length == 0) revert EmptyMessage();
        if (length > MAX_MESSAGE_BYTES) revert MessageTooLong(length, MAX_MESSAGE_BYTES);

        id = _entries.length;
        // casting to 'uint64' is safe because block.timestamp fits in 64 bits for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        _entries.push(Entry({signer: msg.sender, timestamp: uint64(block.timestamp), message: message}));
        emit Signed(id, msg.sender, block.timestamp, message);

        TOKEN.burnFrom(msg.sender, SIGNING_FEE);
    }

    /// @notice Number of entries signed so far.
    function entryCount() external view returns (uint256) {
        return _entries.length;
    }

    /// @notice One entry by id. Reverts for ids that do not exist yet.
    function getEntry(uint256 id) external view returns (Entry memory) {
        uint256 count = _entries.length;
        if (id >= count) revert EntryDoesNotExist(id, count);
        return _entries[id];
    }

    /// @notice The newest entries, newest first.
    /// @param count How many to return; clamped to the number of entries that exist.
    function latestEntries(uint256 count) external view returns (Entry[] memory) {
        return _newestBefore(_entries.length, count);
    }

    /// @notice Entries with an id strictly below `beforeId`, newest first. Use for paging: pass the
    /// smallest id from the previous page as `beforeId` to fetch the next, older, page.
    /// @param beforeId Exclusive upper bound on the ids returned; clamped to the entry count.
    /// @param count How many to return; clamped to the number of entries below `beforeId`.
    function entriesBefore(uint256 beforeId, uint256 count) external view returns (Entry[] memory) {
        uint256 total = _entries.length;
        return _newestBefore(beforeId < total ? beforeId : total, count);
    }

    /// @dev Returns up to `count` entries with ids in [end - n, end), ordered from id end-1 downwards.
    /// `end` must not exceed the entry count.
    function _newestBefore(uint256 end, uint256 count) private view returns (Entry[] memory page) {
        uint256 n = count < end ? count : end;
        page = new Entry[](n);
        for (uint256 i = 0; i < n; ++i) {
            page[i] = _entries[end - 1 - i];
        }
    }
}
