// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title ZeroXSixC identity registry
/// @notice Stores a self-managed profile and a unique username for each address,
/// plus non-transferable badges (SBT records) issued by the owner.
/// @dev UUPS implementation behind an ERC-1967 proxy. All state lives in an ERC-7201 namespace.
/// Profile and username writes always target `msg.sender`; the owner controls badges and upgrades.
contract ZeroXSixCIdentity is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Avatar appearance.
    /// @param heightCm Height in centimetres, `150..200`; `0` means the avatar is not set.
    /// @param color RGB color.
    struct Avatar {
        uint8 heightCm;
        bytes3 color;
    }

    /// @notice One profile link inside the `info` blob.
    /// @dev Not stored or decoded on-chain. Clients encode `info` as `abi.encode(string bio, InfoLink[] links)`.
    struct InfoLink {
        string linkName;
        string href;
    }

    /// @notice Badge held by an account.
    /// @param sbtTypeId Template id.
    /// @param expirationDate Unix seconds, or `0` for a badge that never expires. Not enforced on-chain.
    struct IssuedSBT {
        uint32 sbtTypeId;
        uint32 expirationDate;
    }

    /// @notice Badge template.
    /// @param name Display name; an empty name means the template does not exist.
    struct SBTMetadata {
        string name;
    }

    /// @custom:storage-location erc7201:zeroxsixc.storage.Identity
    struct IdentityStorage {
        mapping(address => string) visibleNames;
        mapping(address => Avatar) avatars;
        mapping(address => bytes) infos;
        mapping(address => string) usernames;
        mapping(string => address) usernameOwners;
        mapping(address => IssuedSBT[]) sbts;
        mapping(uint32 => SBTMetadata) sbtTemplates;
    }

    // keccak256(abi.encode(uint256(keccak256("zeroxsixc.storage.Identity")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTITY_STORAGE_LOCATION =
        0x6b17ff38724524b5995680d069c7e8146b9efb562b2fad2e3dde7456e0cc6b00;

    /// @notice Mask bit for the visible name.
    uint8 public constant FIELD_VISIBLE_NAME = 1;
    /// @notice Mask bit for the avatar.
    uint8 public constant FIELD_AVATAR = 2;
    /// @notice Mask bit for the info blob.
    uint8 public constant FIELD_INFO = 4;
    uint8 internal constant ALL_FIELDS = FIELD_VISIBLE_NAME | FIELD_AVATAR | FIELD_INFO;

    /// @notice Maximum visible name length in bytes.
    uint256 public constant MAX_VISIBLE_NAME_BYTES = 32;
    /// @notice Minimum avatar height in centimetres.
    uint8 public constant MIN_HEIGHT_CM = 150;
    /// @notice Maximum avatar height in centimetres.
    uint8 public constant MAX_HEIGHT_CM = 200;
    /// @notice Maximum info blob length in bytes.
    uint256 public constant MAX_INFO_BYTES = 2048;
    /// @notice Minimum username length.
    uint256 public constant MIN_USERNAME_LENGTH = 3;
    /// @notice Maximum username length.
    uint256 public constant MAX_USERNAME_LENGTH = 32;

    /// @notice Emitted when profile fields of `account` are written or cleared.
    /// @param mask Bitmask of the affected fields.
    event ProfileUpdated(address indexed account, uint8 mask);
    /// @notice Emitted when `account` sets, changes or clears its username.
    event UsernameChanged(address indexed account);
    /// @notice Emitted when a badge of `account` is issued, renewed or revoked.
    event SbtChanged(address indexed account);
    /// @notice Emitted when the owner creates a badge template.
    event SbtTemplateCreated(uint32 indexed sbtTypeId, string name);

    /// @notice The mask is zero or has bits outside the profile fields.
    error InvalidMask(uint8 mask);
    /// @notice The visible name is empty or longer than `MAX_VISIBLE_NAME_BYTES`.
    error InvalidVisibleName();
    /// @notice The avatar height is outside `MIN_HEIGHT_CM..MAX_HEIGHT_CM`.
    error InvalidAvatarHeight(uint8 heightCm);
    /// @notice The info blob is empty or longer than `MAX_INFO_BYTES`.
    error InvalidInfo();
    /// @notice The username has an invalid length or characters outside `[a-z0-9_]`.
    error InvalidUsername();
    /// @notice The username belongs to an account already.
    error UsernameTaken();
    /// @notice The caller has no username to clear.
    error UsernameNotSet();
    /// @notice The template name is empty.
    error InvalidSbtTemplateName();
    /// @notice A template with this id exists already.
    error SbtTemplateExists(uint32 sbtTypeId);
    /// @notice No template with this id.
    error SbtTemplateNotFound(uint32 sbtTypeId);
    /// @notice `account` does not hold a badge of this template.
    error SbtNotIssued(address account, uint32 sbtTypeId);
    /// @notice The account is the zero address.
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy.
    /// @param initialOwner Account that controls badges and upgrades.
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }

    /// @notice Implementation version.
    function version() public pure virtual returns (uint256) {
        return 1;
    }

    /// @notice Sets the caller's visible name.
    /// @param visibleName `1..MAX_VISIBLE_NAME_BYTES` bytes of UTF-8.
    function setVisibleName(string calldata visibleName) external {
        _writeVisibleName(visibleName);

        emit ProfileUpdated(msg.sender, FIELD_VISIBLE_NAME);
    }

    /// @notice Sets the caller's avatar.
    /// @param heightCm Height in centimetres, `MIN_HEIGHT_CM..MAX_HEIGHT_CM`.
    /// @param color RGB color.
    function setAvatar(uint8 heightCm, bytes3 color) external {
        _writeAvatar(Avatar(heightCm, color));

        emit ProfileUpdated(msg.sender, FIELD_AVATAR);
    }

    /// @notice Sets the caller's info blob.
    /// @param info `abi.encode(string bio, InfoLink[] links)`, `1..MAX_INFO_BYTES` bytes. Only the length is checked.
    function setInfo(bytes calldata info) external {
        _writeInfo(info);

        emit ProfileUpdated(msg.sender, FIELD_INFO);
    }

    /// @notice Writes the profile fields selected by `mask` in one call. Values of unselected fields are ignored.
    /// @param mask Bitmask of `FIELD_VISIBLE_NAME`, `FIELD_AVATAR` and `FIELD_INFO`.
    /// @param visibleName See {setVisibleName}.
    /// @param avatar See {setAvatar}.
    /// @param info See {setInfo}.
    function setProfile(uint8 mask, string calldata visibleName, Avatar calldata avatar, bytes calldata info) external {
        _checkMask(mask);

        if (mask & FIELD_VISIBLE_NAME != 0) {
            _writeVisibleName(visibleName);
        }
        if (mask & FIELD_AVATAR != 0) {
            _writeAvatar(avatar);
        }
        if (mask & FIELD_INFO != 0) {
            _writeInfo(info);
        }

        emit ProfileUpdated(msg.sender, mask);
    }

    /// @notice Clears the caller's profile fields selected by `mask`.
    /// @param mask Bitmask of `FIELD_VISIBLE_NAME`, `FIELD_AVATAR` and `FIELD_INFO`.
    function clearProfile(uint8 mask) external {
        _checkMask(mask);

        IdentityStorage storage $ = _getIdentityStorage();

        if (mask & FIELD_VISIBLE_NAME != 0) {
            delete $.visibleNames[msg.sender];
        }
        if (mask & FIELD_AVATAR != 0) {
            delete $.avatars[msg.sender];
        }
        if (mask & FIELD_INFO != 0) {
            delete $.infos[msg.sender];
        }

        emit ProfileUpdated(msg.sender, mask);
    }

    /// @notice Sets or changes the caller's username and releases the previous one.
    /// @param username `MIN_USERNAME_LENGTH..MAX_USERNAME_LENGTH` characters of `[a-z0-9_]`, not taken by anyone.
    function setUsername(string calldata username) external {
        if (!_isValidUsername(bytes(username))) {
            revert InvalidUsername();
        }

        IdentityStorage storage $ = _getIdentityStorage();

        if ($.usernameOwners[username] != address(0)) {
            revert UsernameTaken();
        }

        string storage current = $.usernames[msg.sender];

        if (bytes(current).length != 0) {
            delete $.usernameOwners[current];
        }

        $.usernames[msg.sender] = username;
        $.usernameOwners[username] = msg.sender;

        emit UsernameChanged(msg.sender);
    }

    /// @notice Clears the caller's username and releases it.
    function clearUsername() external {
        IdentityStorage storage $ = _getIdentityStorage();
        string storage current = $.usernames[msg.sender];

        if (bytes(current).length == 0) {
            revert UsernameNotSet();
        }

        delete $.usernameOwners[current];
        delete $.usernames[msg.sender];

        emit UsernameChanged(msg.sender);
    }

    /// @notice Creates a badge template. Templates cannot be renamed or removed.
    /// @param sbtTypeId New template id.
    /// @param name Non-empty display name.
    function createSbtTemplate(uint32 sbtTypeId, string calldata name) external onlyOwner {
        if (bytes(name).length == 0) {
            revert InvalidSbtTemplateName();
        }
        if (_sbtTemplateExists(sbtTypeId)) {
            revert SbtTemplateExists(sbtTypeId);
        }

        _getIdentityStorage().sbtTemplates[sbtTypeId] = SBTMetadata(name);

        emit SbtTemplateCreated(sbtTypeId, name);
    }

    /// @notice Issues a badge to `account`, or updates its expiration if it is held already.
    /// @param account Recipient; a profile is not required.
    /// @param sbtTypeId Existing template id.
    /// @param expirationDate Unix seconds, or `0` for a badge that never expires.
    function issueSbt(address account, uint32 sbtTypeId, uint32 expirationDate) external onlyOwner {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (!_sbtTemplateExists(sbtTypeId)) {
            revert SbtTemplateNotFound(sbtTypeId);
        }

        IssuedSBT[] storage issued = _getIdentityStorage().sbts[account];

        (bool found, uint256 index) = _findSbt(issued, sbtTypeId);

        if (found) {
            issued[index].expirationDate = expirationDate;
        } else {
            issued.push(IssuedSBT(sbtTypeId, expirationDate));
        }

        emit SbtChanged(account);
    }

    /// @notice Revokes a badge from `account`. The order of the remaining badges may change.
    /// @param account Holder.
    /// @param sbtTypeId Template id of the badge.
    function revokeSbt(address account, uint32 sbtTypeId) external onlyOwner {
        IssuedSBT[] storage issued = _getIdentityStorage().sbts[account];

        (bool found, uint256 index) = _findSbt(issued, sbtTypeId);

        if (!found) {
            revert SbtNotIssued(account, sbtTypeId);
        }

        issued[index] = issued[issued.length - 1];
        issued.pop();

        emit SbtChanged(account);
    }

    /// @notice Returns everything stored for `account`. Unset fields are empty or zero.
    function getProfile(address account)
        external
        view
        returns (
            string memory visibleName,
            Avatar memory avatar,
            bytes memory info,
            string memory username,
            IssuedSBT[] memory issuedSbts
        )
    {
        IdentityStorage storage $ = _getIdentityStorage();
        return ($.visibleNames[account], $.avatars[account], $.infos[account], $.usernames[account], $.sbts[account]);
    }

    /// @notice Returns the owner of `username`, or the zero address if it is free.
    function usernameOwners(string calldata username) external view returns (address) {
        return _getIdentityStorage().usernameOwners[username];
    }

    /// @notice Returns the name of template `sbtTypeId`, or an empty string if it does not exist.
    function sbtTemplates(uint32 sbtTypeId) external view returns (string memory name) {
        return _getIdentityStorage().sbtTemplates[sbtTypeId].name;
    }

    function _writeVisibleName(string calldata visibleName) internal {
        uint256 length = bytes(visibleName).length;
        if (length == 0 || length > MAX_VISIBLE_NAME_BYTES) {
            revert InvalidVisibleName();
        }

        _getIdentityStorage().visibleNames[msg.sender] = visibleName;
    }

    function _writeAvatar(Avatar memory avatar) internal {
        if (avatar.heightCm < MIN_HEIGHT_CM || avatar.heightCm > MAX_HEIGHT_CM) {
            revert InvalidAvatarHeight(avatar.heightCm);
        }

        _getIdentityStorage().avatars[msg.sender] = avatar;
    }

    function _writeInfo(bytes calldata info) internal {
        if (info.length == 0 || info.length > MAX_INFO_BYTES) {
            revert InvalidInfo();
        }

        _getIdentityStorage().infos[msg.sender] = info;
    }

    function _checkMask(uint8 mask) internal pure {
        if (mask == 0 || mask & ~ALL_FIELDS != 0) {
            revert InvalidMask(mask);
        }
    }

    function _isValidUsername(bytes calldata username) internal pure returns (bool) {
        uint256 length = username.length;

        if (length < MIN_USERNAME_LENGTH || length > MAX_USERNAME_LENGTH) {
            return false;
        }

        for (uint256 i; i < length; ++i) {
            bytes1 char = username[i];
            bool isLower = char >= "a" && char <= "z";
            bool isDigit = char >= "0" && char <= "9";

            if (!isLower && !isDigit && char != "_") {
                return false;
            }
        }

        return true;
    }

    function _sbtTemplateExists(uint32 sbtTypeId) internal view returns (bool) {
        return bytes(_getIdentityStorage().sbtTemplates[sbtTypeId].name).length != 0;
    }

    function _findSbt(IssuedSBT[] storage issued, uint32 sbtTypeId) internal view returns (bool, uint256) {
        uint256 length = issued.length;

        for (uint256 i; i < length; ++i) {
            if (issued[i].sbtTypeId == sbtTypeId) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _getIdentityStorage() private pure returns (IdentityStorage storage $) {
        assembly {
            $.slot := IDENTITY_STORAGE_LOCATION
        }
    }
}
