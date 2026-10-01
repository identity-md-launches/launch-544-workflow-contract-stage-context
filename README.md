# Onchain Guestbook

An onchain guestbook paid in the launch token. Signing burns 10 tokens and stores a message of at
most 280 bytes. A website (built in a later stage) lists the latest entries and lets a connected
wallet sign.

This repository is the contract stage: the launch token, the guestbook contract, their tests, ABI
exports and the deployment facts the manifest and review steps need.

## Contracts

| Contract      | File                   | Role                                                         |
|---------------|------------------------|--------------------------------------------------------------|
| `LaunchToken` | `src/LaunchToken.sol`  | Fixed-supply ERC-20 the launch deploys and seeds the pool with |
| `Guestbook`   | `src/Guestbook.sol`    | The application: burns the fee and stores entries              |

ABIs: `docs/abi/LaunchToken.json`, `docs/abi/Guestbook.json` (output of `forge inspect <Contract> abi`).

### LaunchToken

- Name `Guestbook Token`, symbol `GUEST`, 18 decimals. The brief names no token, so these are the
  project's short name.
- Exactly 1,000,000,000 tokens (10^27 minor units) minted once, to `msg.sender`, in the constructor.
  No constructor arguments.
- No owner, mint, pause, blocklist, transfer fee or upgrade function. Plain OpenZeppelin 5.4.0
  `ERC20`.
- The one addition is OpenZeppelin's `ERC20Burnable`: `burn(uint256)` and
  `burnFrom(address,uint256)`. Both act only on tokens the caller holds or has been approved for.
  Supply can only decrease. The guestbook pays its fee through `burnFrom`, which is what makes the
  brief's "signing burns 10 tokens" a true burn (supply goes down) rather than a transfer to a dead
  address.
- What the brief asked that the token does not do: nothing. The brief asks for no supply, decimals,
  fees, limits, allocations or minting, and none exist.

### Guestbook

Constructor: `Guestbook(address token)`. The token must already be deployed (the constructor checks
for code) and is stored as an immutable. No other parameters, no owner, no privileged role of any
kind. The factory, which is `msg.sender` of the constructor, gets nothing.

| Item                 | Value                                                       |
|----------------------|-------------------------------------------------------------|
| `SIGNING_FEE`        | 10 tokens (`10e18` minor units), burned per signature       |
| `MAX_MESSAGE_BYTES`  | 280 bytes (bytes, not characters)                           |
| Empty messages       | rejected (`EmptyMessage`)                                   |
| Entry ids            | sequential from 0, never reused                             |
| Entries              | append-only; nothing can edit or delete them                |

Functions:

- `sign(string message) returns (uint256 id)`: stores the entry, emits `Signed`, then calls
  `TOKEN.burnFrom(msg.sender, SIGNING_FEE)`. Reverts with the token's `ERC20InsufficientAllowance`
  or `ERC20InsufficientBalance` if the signer did not approve or does not hold the fee.
- `entryCount()`, `getEntry(uint256 id)`.
- `latestEntries(uint256 count)`: newest first, clamped to what exists.
- `entriesBefore(uint256 beforeId, uint256 count)`: entries with id below `beforeId`, newest
  first. Page backwards by passing the smallest id of the previous page.

Event: `Signed(uint256 indexed id, address indexed signer, uint256 timestamp, string message)`.

The contract holds no tokens and no ETH. It has no `receive` or `fallback`; sending ETH reverts.

## Signing flow (for the website)

1. `GUEST.approve(guestbook, 10e18)`. Approve exactly 10 tokens per intended signature, or a small
   bounded multiple. Do not request unlimited approvals.
2. `guestbook.sign(message)` with a message of 1 to 280 UTF-8 bytes. Measure bytes client-side
   with `new TextEncoder().encode(message).length`.
3. List entries with `latestEntries(n)` and page older ones with `entriesBefore(minId, n)`, or
   index the `Signed` event.

Frontends must use the exact pool key from the deployment handoff. The pool opens at the network's
trading fee read from the chain's LaunchFees contract (1.25% by default: 1% to the wallet that paid
for the launch, 0.25% to IMD). It is not a 0.3% pool; the manifest's `fee: 3000` is an admission
value only.

## Deployment parameters (for the manifest step)

The launch deploys `LaunchToken` first, then `Guestbook` with the token's address. In manifest terms:

| Field              | Value                                   |
|--------------------|-----------------------------------------|
| kind               | `evm_project`                           |
| token              | `LaunchToken`                           |
| contracts[0].name  | `Guestbook`                             |
| constructorArgs    | `["$token"]`                            |
| pool fee / spacing | 3000 / 60 (admission values)            |
| initialPrice       | `79228162514264337593543950336`         |

`Guestbook` has one constructor argument, of type `address`, and it is the launch token. No `$owner`
is needed: the contract has no owner. Dependency order is token then guestbook; the guestbook
constructor reverts if the token address has no code.

The factory holds the whole supply after the token constructor and splits it by policy (10% to the
swarm, the rest to the requester's pool seed and wallet). Nothing in this repository mints, holds or
forwards any of it; the guestbook only ever burns tokens that signers already hold and approved.

## Assumptions

- The 10-token fee is a constant, by design. There is no admin to change it, pause signing or
  remove entries. If the requester later wants a different fee, that is a new contract.
- The fee is burned (supply decreases), not sent to a treasury or a dead address.
- Message length is bytes, not characters: a 71-emoji message of 284 bytes is rejected.
- Empty messages are rejected as useless burns. A single byte is the minimum.
- Timestamps are `block.timestamp` truncated to 64 bits, which is safe for the lifetime of the chain.
- The token is the trusted launch token with no transfer hooks, so `sign` needs no reentrancy guard.
  It still follows checks-effects-interactions. The test suite shows that a hostile token that
  re-enters `sign` can only append another entry with its own fee call; ids and ordering stay
  consistent.
- Signing is pseudonymous and permanent. Messages are public forever; the contract does no content
  moderation and the website should state that.

## Operational responsibilities

- **Factory / deployer (service stage):** publish source, attest, admit and deploy from
  `launch.json`; verify both contracts on the explorer with `forge verify-contract`. No upgrade
  rights exist to hand over.
- **Requester:** fund the pool and wallet per policy; nothing to configure on the guestbook.
- **Website:** request exact approvals, enforce the 280-byte limit before sending, show the latest
  entries via `latestEntries` or the `Signed` event, and use the handoff pool key.
- **Users:** need GUEST tokens from the pool and an approval before signing. A failed `sign` burns
  nothing and stores nothing.
- This stage does not deploy, broadcast, hold keys or control a wallet. `script/Deploy.s.sol` is for
  local development only; the production deployment is the factory's.

## Security notes

Checked against the eth-security checklist: no access control (nothing privileged exists), CEI
ordering with no ETH or arbitrary-token custody, exact-amount approvals documented, input bounds on
every public function, events on every state change, no proxy, delegatecall, callcode or
selfdestruct (asserted in tests by scanning runtime bytecode), no oracle, no swap. `SafeERC20` is
not used because the only token call is `burnFrom` on the project's own OpenZeppelin token, which
reverts on failure and returns nothing.

Tools run: `forge build`, `forge test` (45 tests including fuzz runs at 256 iterations), `forge fmt
--check`, and a local run of the protected token and project floor tests against the real creation
code. Slither and Mythril were not run. Tests passing is not an audit; the independent review step
follows this stage.

## Build and test

```bash
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"`, `ffi = false` and no filesystem
permissions. Dependencies are vendored as plain files in `lib/`: forge-std (`src/` only) and the six
OpenZeppelin 5.4.0 files the token needs. Tests read no environment variables and pass in any order
and in parallel.
