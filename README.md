# 0x6C identity

Rooms are independent servers. Each one keeps its own sessions, presence, and simulation, and none of them replicates that state to the others. Identity is the data that has to match in every room: display name, avatar, profile info, username, and badges.

The chain is the only source of truth for that data. A wallet writes it once, to `ZeroXSixCIdentity`. Every room reads the same contract. A change lands in one transaction; each room learns it from the logs and updates every local session of that address. Rooms do not sync identity with each other.

## Contract

`ZeroXSixCIdentity` is the UUPS implementation. The address rooms and clients call is the ERC-1967 proxy, not the implementation. The implementation holds no state. `initialize(initialOwner)` runs once, from the proxy constructor calldata, and sets the owner. The implementation constructor disables initializers, so the logic contract itself cannot be initialized.

All state sits in one ERC-7201 namespace, `zeroxsixc.storage.Identity`, rooted at `IDENTITY_STORAGE_LOCATION`. New fields are appended to `IdentityStorage`. That keeps existing slots stable across upgrades. `_authorizeUpgrade` is `onlyOwner`.

### Profile

Three fields, each stored per address and written only for `msg.sender`:

| Field         | Type     | Limits                                         |
| ------------- | -------- | ---------------------------------------------- |
| `visibleName` | `string` | 1–32 bytes of UTF-8                            |
| `avatar`      | `Avatar` | `heightCm` in 150–200, `color` as `bytes3` RGB |
| `info`        | `bytes`  | 1–2048 bytes                                   |

`Avatar.heightCm == 0`, an empty `visibleName`, and empty `info` mean the field is not set.

`info` is opaque on-chain. Clients encode it as `abi.encode(string bio, InfoLink[] links)`. `InfoLink` is `{ linkName, href }`. The contract checks the byte length and does not decode the blob.

Each field can be written on its own (`setVisibleName`, `setAvatar`, `setInfo`) or together. `setProfile(mask, visibleName, avatar, info)` writes only the fields selected by `mask` and ignores the rest. `clearProfile(mask)` deletes the selected fields.

Mask bits:

| Constant             | Value |
| -------------------- | ----- |
| `FIELD_VISIBLE_NAME` | `1`   |
| `FIELD_AVATAR`       | `2`   |
| `FIELD_INFO`         | `4`   |

A zero mask, or any bit outside those three, reverts with `InvalidMask`.

Every write and every clear emits `ProfileUpdated(account, mask)`. `account` is indexed.

### Username

The username is not part of the profile mask. It is a separate mapping, one name per address, unique across the registry.

The character set is `[a-z0-9_]`. Length is 3–32. `setUsername` reverts with `InvalidUsername` on a bad string and `UsernameTaken` if `usernameOwners` already points at an account. A change deletes the previous `usernameOwners` entry and writes the new pair in the same transaction. A failed change leaves the old name in place. `clearUsername` releases the name and reverts with `UsernameNotSet` when the caller has none.

`UsernameChanged(account)` is emitted on set, change, and clear. `account` is indexed. `usernameOwners(username)` returns the holder, or `address(0)` when the name is free.

### Badges

Badges are non-transferable records. They are not tokens and have no transfer function. The owner creates templates and issues or revokes records. The holder does not need a profile.

`createSbtTemplate(sbtTypeId, name)` stores `SBTMetadata`. The name must be non-empty. An id whose name is empty does not exist. Templates cannot be renamed or removed. `SbtTemplateCreated(sbtTypeId, name)` is emitted with `sbtTypeId` indexed.

`issueSbt(account, sbtTypeId, expirationDate)` appends an `IssuedSBT`, or replaces `expirationDate` when that template is already held. `expirationDate` is unix seconds. `0` means the badge does not expire. The contract stores the value and does not enforce it. `account` must not be the zero address, and the template must exist.

`revokeSbt(account, sbtTypeId)` removes the record. Removal is swap-and-pop, so the order of the remaining badges can change.

Issue, renewal, and revoke emit `SbtChanged(account)` with `account` indexed.

### Reads

`getProfile(account)` returns `visibleName`, `avatar`, `info`, `username`, and the `IssuedSBT` array in one call. Unset fields come back empty or zero.

`sbtTemplates(sbtTypeId)` returns the template name, or an empty string when the id does not exist.

## What a room does with it

On connect, a room calls `getProfile` for the wallet and copies the result into that connection. A later log for the same address is applied to every connection of that wallet on that server.

`ProfileUpdated`, `UsernameChanged`, and `SbtChanged` are the signals. The account is an indexed topic, so a room filters logs by the addresses it currently holds.

A profile field that is set on-chain is closed for edits inside the room. A field that is still unset can be changed locally; clearing it on-chain returns the room to its default. Username and badges have no room-local copy of record. Badge expiry and room entry rules are evaluated by the room against the stored `expirationDate`. The contract does not gate entry.

## Development

Foundry. Solidity 0.8.28. OpenZeppelin is pinned as git submodules under `lib/`.

```shell
forge build
forge test -vvv
forge fmt --check
```

CI on push and pull request runs `forge fmt --check`, `forge build --sizes`, and `forge test -vvv`.

After an ABI change, regenerate the ABI consumed by rooms and write it to `rooms-backend/src/config/profile-contract.abi.ts`:

```shell
forge inspect ZeroXSixCIdentity abi --json
```

## Network

Arbitrum Sepolia, chain id `421614`. Proxy: `0x3b3FFf72126Fb9dB2d0530809ccd3CaE2a077313`.

Rooms read this proxy. A second deployment is a different registry and does not replace it.
