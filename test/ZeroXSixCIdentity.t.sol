// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ZeroXSixCIdentity} from "../src/ZeroXSixCIdentity.sol";

contract ZeroXSixCIdentityV2 is ZeroXSixCIdentity {
    function version() public pure override returns (uint256) {
        return 2;
    }
}

contract ZeroXSixCIdentityTest is Test {
    event ProfileUpdated(address indexed account, uint8 mask);
    event UsernameChanged(address indexed account);
    event SbtChanged(address indexed account);
    event SbtTemplateCreated(uint32 indexed sbtTypeId, string name);

    uint8 internal constant NAME = 1;
    uint8 internal constant AVATAR = 2;
    uint8 internal constant INFO = 4;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    ZeroXSixCIdentity internal main;

    function setUp() public {
        ZeroXSixCIdentity implementation = new ZeroXSixCIdentity();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(ZeroXSixCIdentity.initialize, (owner))
        );
        main = ZeroXSixCIdentity(address(proxy));
    }

    // Helpers

    function _info() internal pure returns (bytes memory) {
        ZeroXSixCIdentity.InfoLink[]
            memory links = new ZeroXSixCIdentity.InfoLink[](1);
        links[0] = ZeroXSixCIdentity.InfoLink("site", "https://example.com");
        return abi.encode("hello", links);
    }

    function _avatar(
        uint8 heightCm,
        bytes3 color
    ) internal pure returns (ZeroXSixCIdentity.Avatar memory) {
        return ZeroXSixCIdentity.Avatar(heightCm, color);
    }

    function _visibleName(
        address account
    ) internal view returns (string memory visibleName) {
        (visibleName, , , , ) = main.getProfile(account);
    }

    function _avatarOf(
        address account
    ) internal view returns (ZeroXSixCIdentity.Avatar memory avatar) {
        (, avatar, , , ) = main.getProfile(account);
    }

    function _infoOf(
        address account
    ) internal view returns (bytes memory info) {
        (, , info, , ) = main.getProfile(account);
    }

    function _usernameOf(
        address account
    ) internal view returns (string memory username) {
        (, , , username, ) = main.getProfile(account);
    }

    function _sbtsOf(
        address account
    ) internal view returns (ZeroXSixCIdentity.IssuedSBT[] memory issued) {
        (, , , , issued) = main.getProfile(account);
    }

    function _fillProfile(address account) internal {
        vm.prank(account);
        main.setProfile(
            NAME | AVATAR | INFO,
            "Alice",
            _avatar(180, 0x112233),
            _info()
        );
    }

    // Init and upgrade

    function test_initializeSetsOwnerAndVersion() public view {
        assertEq(main.owner(), owner);
        assertEq(main.version(), 1);
    }

    function test_storageUsesErc7201Namespace() public {
        vm.prank(alice);
        main.setUsername("alice");

        bytes32 namespace =
            keccak256(abi.encode(uint256(keccak256("zeroxsixc.storage.Identity")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 usernameOwnersSlot = bytes32(uint256(namespace) + 4);
        bytes32 aliceSlot = keccak256(abi.encodePacked("alice", usernameOwnersSlot));
        assertEq(address(uint160(uint256(vm.load(address(main), aliceSlot)))), alice);
        assertEq(vm.load(address(main), bytes32(0)), bytes32(0));
    }

    function test_initializeCannotBeCalledTwice() public {
        vm.expectRevert();
        main.initialize(alice);
    }

    function test_strangerCannotUpgrade() public {
        ZeroXSixCIdentityV2 next = new ZeroXSixCIdentityV2();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        main.upgradeToAndCall(address(next), "");
    }

    function test_upgradePreservesStorage() public {
        _fillProfile(alice);
        vm.prank(alice);
        main.setUsername("alice");
        vm.startPrank(owner);
        main.createSbtTemplate(7, "Member");
        main.issueSbt(alice, 7, 1_900_000_000);

        ZeroXSixCIdentityV2 next = new ZeroXSixCIdentityV2();
        main.upgradeToAndCall(address(next), "");
        vm.stopPrank();

        assertEq(main.version(), 2);
        assertEq(main.owner(), owner);
        (
            string memory visibleName,
            ZeroXSixCIdentity.Avatar memory avatar,
            bytes memory info,
            string memory username,
            ZeroXSixCIdentity.IssuedSBT[] memory issued
        ) = main.getProfile(alice);
        assertEq(visibleName, "Alice");
        assertEq(avatar.heightCm, 180);
        assertEq(avatar.color, bytes3(0x112233));
        assertEq(info, _info());
        assertEq(username, "alice");
        assertEq(main.usernameOwners("alice"), alice);
        assertEq(issued.length, 1);
        assertEq(issued[0].sbtTypeId, 7);
        assertEq(issued[0].expirationDate, 1_900_000_000);
        assertEq(main.sbtTemplates(7), "Member");
    }

    // Profile: single fields

    function test_emptyProfileByDefault() public view {
        (
            string memory visibleName,
            ZeroXSixCIdentity.Avatar memory avatar,
            bytes memory info,
            string memory username,
            ZeroXSixCIdentity.IssuedSBT[] memory issued
        ) = main.getProfile(alice);
        assertEq(bytes(visibleName).length, 0);
        assertEq(avatar.heightCm, 0);
        assertEq(avatar.color, bytes3(0));
        assertEq(info.length, 0);
        assertEq(bytes(username).length, 0);
        assertEq(issued.length, 0);
    }

    function test_setVisibleNameOnlyTouchesName() public {
        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, NAME);
        vm.prank(alice);
        main.setVisibleName("Alice");

        assertEq(_visibleName(alice), "Alice");
        assertEq(_avatarOf(alice).heightCm, 0);
        assertEq(_infoOf(alice).length, 0);
        assertEq(bytes(_visibleName(bob)).length, 0);
    }

    function test_setAvatarOnlyTouchesAvatar() public {
        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, AVATAR);
        vm.prank(alice);
        main.setAvatar(150, 0xFFFFFF);

        assertEq(_avatarOf(alice).heightCm, 150);
        assertEq(_avatarOf(alice).color, bytes3(0xFFFFFF));
        assertEq(bytes(_visibleName(alice)).length, 0);
        assertEq(_infoOf(alice).length, 0);
    }

    function test_setInfoOnlyTouchesInfo() public {
        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, INFO);
        vm.prank(alice);
        main.setInfo(_info());

        assertEq(_infoOf(alice), _info());
        assertEq(bytes(_visibleName(alice)).length, 0);
        assertEq(_avatarOf(alice).heightCm, 0);
    }

    function test_clearEachFieldIndependently() public {
        _fillProfile(alice);

        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, NAME);
        vm.prank(alice);
        main.clearProfile(NAME);
        assertEq(bytes(_visibleName(alice)).length, 0);
        assertEq(_avatarOf(alice).heightCm, 180);
        assertEq(_infoOf(alice), _info());

        vm.prank(alice);
        main.clearProfile(AVATAR);
        assertEq(_avatarOf(alice).heightCm, 0);
        assertEq(_avatarOf(alice).color, bytes3(0));
        assertEq(_infoOf(alice), _info());

        vm.prank(alice);
        main.clearProfile(INFO);
        assertEq(_infoOf(alice).length, 0);
    }

    function test_clearSeveralFieldsAtOnce() public {
        _fillProfile(alice);

        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, NAME | INFO);
        vm.prank(alice);
        main.clearProfile(NAME | INFO);

        assertEq(bytes(_visibleName(alice)).length, 0);
        assertEq(_avatarOf(alice).heightCm, 180);
        assertEq(_infoOf(alice).length, 0);
    }

    function test_clearDoesNotTouchOtherAccounts() public {
        _fillProfile(alice);
        _fillProfile(bob);

        vm.prank(alice);
        main.clearProfile(NAME | AVATAR | INFO);

        assertEq(_visibleName(bob), "Alice");
        assertEq(_avatarOf(bob).heightCm, 180);
        assertEq(_infoOf(bob), _info());
    }

    // Profile: setProfile masks

    function test_setProfileAllFields() public {
        vm.expectEmit(true, false, false, true, address(main));
        emit ProfileUpdated(alice, NAME | AVATAR | INFO);
        _fillProfile(alice);

        assertEq(_visibleName(alice), "Alice");
        assertEq(_avatarOf(alice).heightCm, 180);
        assertEq(_infoOf(alice), _info());
    }

    function test_setProfileIgnoresFieldsOutsideMask() public {
        vm.prank(alice);
        main.setProfile(AVATAR, "", _avatar(160, 0x0000FF), "");

        assertEq(bytes(_visibleName(alice)).length, 0);
        assertEq(_avatarOf(alice).heightCm, 160);
        assertEq(_infoOf(alice).length, 0);
    }

    function test_setProfileKeepsUnmaskedFields() public {
        _fillProfile(alice);

        vm.prank(alice);
        main.setProfile(
            NAME | INFO,
            "Bob",
            _avatar(0, 0),
            abi.encode("bio", new ZeroXSixCIdentity.InfoLink[](0))
        );

        assertEq(_visibleName(alice), "Bob");
        assertEq(_avatarOf(alice).heightCm, 180);
        assertEq(
            _infoOf(alice),
            abi.encode("bio", new ZeroXSixCIdentity.InfoLink[](0))
        );
    }

    function test_setProfileValidatesOnlyMaskedFields() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidAvatarHeight.selector,
                uint8(0)
            )
        );
        main.setProfile(NAME | AVATAR, "Alice", _avatar(0, 0), "");
    }

    function test_invalidMaskReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidMask.selector,
                uint8(0)
            )
        );
        main.setProfile(0, "Alice", _avatar(180, 0), _info());
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidMask.selector,
                uint8(8)
            )
        );
        main.setProfile(8, "Alice", _avatar(180, 0), _info());
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidMask.selector,
                uint8(0)
            )
        );
        main.clearProfile(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidMask.selector,
                uint8(0x0F)
            )
        );
        main.clearProfile(0x0F);
        vm.stopPrank();
    }

    // Profile: limits

    function test_visibleNameLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(ZeroXSixCIdentity.InvalidVisibleName.selector);
        main.setVisibleName("");
        vm.expectRevert(ZeroXSixCIdentity.InvalidVisibleName.selector);
        main.setVisibleName("123456789012345678901234567890123");

        main.setVisibleName("a");
        main.setVisibleName("12345678901234567890123456789012");
        vm.stopPrank();
        assertEq(_visibleName(alice), "12345678901234567890123456789012");
    }

    function test_visibleNameLimitIsInBytes() public {
        vm.prank(alice);
        vm.expectRevert(ZeroXSixCIdentity.InvalidVisibleName.selector);
        main.setVisibleName(unicode"ééééééééééééééééé"); // 17 × 2 bytes
    }

    function test_avatarHeightLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidAvatarHeight.selector,
                uint8(149)
            )
        );
        main.setAvatar(149, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidAvatarHeight.selector,
                uint8(201)
            )
        );
        main.setAvatar(201, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.InvalidAvatarHeight.selector,
                uint8(0)
            )
        );
        main.setAvatar(0, 0);

        main.setAvatar(150, 0);
        main.setAvatar(200, 0);
        vm.stopPrank();
        assertEq(_avatarOf(alice).heightCm, 200);
    }

    function test_infoLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(ZeroXSixCIdentity.InvalidInfo.selector);
        main.setInfo("");
        vm.expectRevert(ZeroXSixCIdentity.InvalidInfo.selector);
        main.setInfo(new bytes(2049));

        main.setInfo(new bytes(2048));
        vm.stopPrank();
        assertEq(_infoOf(alice).length, 2048);
    }

    // Username

    function test_setUsername() public {
        vm.expectEmit(true, false, false, false, address(main));
        emit UsernameChanged(alice);
        vm.prank(alice);
        main.setUsername("alice_01");

        assertEq(_usernameOf(alice), "alice_01");
        assertEq(main.usernameOwners("alice_01"), alice);
    }

    function test_usernameLengthLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(ZeroXSixCIdentity.InvalidUsername.selector);
        main.setUsername("ab");
        vm.expectRevert(ZeroXSixCIdentity.InvalidUsername.selector);
        main.setUsername("abcdefghijabcdefghijabcdefghijabc");

        main.setUsername("abc");
        main.setUsername("abcdefghijabcdefghijabcdefghijab");
        vm.stopPrank();
        assertEq(_usernameOf(alice), "abcdefghijabcdefghijabcdefghijab");
    }

    function test_usernameCharset() public {
        string[8] memory invalid = [
            "Alice",
            "ali ce",
            "ali-ce",
            "ali.ce",
            unicode"café",
            "ali@e",
            "ali\x00e",
            "{ab}"
        ];
        vm.startPrank(alice);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ZeroXSixCIdentity.InvalidUsername.selector);
            main.setUsername(invalid[i]);
        }
        main.setUsername("az_09");
        vm.stopPrank();
        assertEq(_usernameOf(alice), "az_09");
    }

    function test_usernameIsUnique() public {
        vm.prank(alice);
        main.setUsername("alice");

        vm.prank(bob);
        vm.expectRevert(ZeroXSixCIdentity.UsernameTaken.selector);
        main.setUsername("alice");

        vm.prank(alice);
        vm.expectRevert(ZeroXSixCIdentity.UsernameTaken.selector);
        main.setUsername("alice");
    }

    function test_changeUsernameIsAtomic() public {
        vm.startPrank(alice);
        main.setUsername("alice");
        main.setUsername("alice2");
        vm.stopPrank();

        assertEq(_usernameOf(alice), "alice2");
        assertEq(main.usernameOwners("alice2"), alice);
        assertEq(main.usernameOwners("alice"), address(0));

        vm.prank(bob);
        main.setUsername("alice");
        assertEq(main.usernameOwners("alice"), bob);
    }

    function test_failedChangeKeepsOldUsername() public {
        vm.prank(bob);
        main.setUsername("bob");
        vm.startPrank(alice);
        main.setUsername("alice");

        vm.expectRevert(ZeroXSixCIdentity.UsernameTaken.selector);
        main.setUsername("bob");
        vm.expectRevert(ZeroXSixCIdentity.InvalidUsername.selector);
        main.setUsername("X");
        vm.stopPrank();

        assertEq(_usernameOf(alice), "alice");
        assertEq(main.usernameOwners("alice"), alice);
        assertEq(main.usernameOwners("bob"), bob);
    }

    function test_clearUsernameReleasesName() public {
        vm.prank(alice);
        main.setUsername("alice");

        vm.expectEmit(true, false, false, false, address(main));
        emit UsernameChanged(alice);
        vm.prank(alice);
        main.clearUsername();

        assertEq(bytes(_usernameOf(alice)).length, 0);
        assertEq(main.usernameOwners("alice"), address(0));

        vm.prank(bob);
        main.setUsername("alice");
        assertEq(_usernameOf(bob), "alice");
    }

    function test_clearUsernameWithoutUsernameReverts() public {
        vm.prank(alice);
        vm.expectRevert(ZeroXSixCIdentity.UsernameNotSet.selector);
        main.clearUsername();
    }

    function test_clearProfileKeepsUsername() public {
        _fillProfile(alice);
        vm.startPrank(alice);
        main.setUsername("alice");
        main.clearProfile(NAME | AVATAR | INFO);
        vm.stopPrank();
        assertEq(_usernameOf(alice), "alice");
    }

    // SBT

    function test_onlyOwnerManagesSbt() public {
        bytes memory unauthorized = abi.encodeWithSelector(
            OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
            alice
        );

        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        main.createSbtTemplate(1, "Member");
        vm.stopPrank();

        vm.prank(owner);
        main.createSbtTemplate(1, "Member");

        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        main.issueSbt(alice, 1, 0);
        vm.stopPrank();

        vm.prank(owner);
        main.issueSbt(bob, 1, 0);

        vm.prank(alice);
        vm.expectRevert(unauthorized);
        main.revokeSbt(bob, 1);
        assertEq(_sbtsOf(bob).length, 1);
    }

    function test_createSbtTemplate() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(main));
        emit SbtTemplateCreated(1, "Member");
        main.createSbtTemplate(1, "Member");
        assertEq(main.sbtTemplates(1), "Member");

        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.SbtTemplateExists.selector,
                uint32(1)
            )
        );
        main.createSbtTemplate(1, "Other");
        vm.expectRevert(ZeroXSixCIdentity.InvalidSbtTemplateName.selector);
        main.createSbtTemplate(2, "");
        vm.stopPrank();
    }

    function test_issueSbtWithoutProfile() public {
        vm.startPrank(owner);
        main.createSbtTemplate(1, "Member");
        main.createSbtTemplate(2, "Speaker");

        vm.expectEmit(true, false, false, false, address(main));
        emit SbtChanged(alice);
        main.issueSbt(alice, 1, 0);
        main.issueSbt(alice, 2, 1_800_000_000);
        vm.stopPrank();

        ZeroXSixCIdentity.IssuedSBT[] memory issued = _sbtsOf(alice);
        assertEq(issued.length, 2);
        assertEq(issued[0].sbtTypeId, 1);
        assertEq(issued[0].expirationDate, 0);
        assertEq(issued[1].sbtTypeId, 2);
        assertEq(issued[1].expirationDate, 1_800_000_000);
        assertEq(bytes(_visibleName(alice)).length, 0);
    }

    function test_issueSbtValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.SbtTemplateNotFound.selector,
                uint32(1)
            )
        );
        main.issueSbt(alice, 1, 0);

        main.createSbtTemplate(1, "Member");
        vm.expectRevert(ZeroXSixCIdentity.ZeroAddress.selector);
        main.issueSbt(address(0), 1, 0);
        vm.stopPrank();
    }

    function test_reissueSbtReplacesExpiration() public {
        vm.startPrank(owner);
        main.createSbtTemplate(1, "Member");
        main.issueSbt(alice, 1, 1_800_000_000);

        vm.expectEmit(true, false, false, false, address(main));
        emit SbtChanged(alice);
        main.issueSbt(alice, 1, 0);
        vm.stopPrank();

        ZeroXSixCIdentity.IssuedSBT[] memory issued = _sbtsOf(alice);
        assertEq(issued.length, 1);
        assertEq(issued[0].expirationDate, 0);
    }

    function test_revokeSbt() public {
        vm.startPrank(owner);
        main.createSbtTemplate(1, "Member");
        main.createSbtTemplate(2, "Speaker");
        main.createSbtTemplate(3, "Host");
        main.issueSbt(alice, 1, 0);
        main.issueSbt(alice, 2, 0);
        main.issueSbt(alice, 3, 0);
        main.issueSbt(bob, 1, 0);

        vm.expectEmit(true, false, false, false, address(main));
        emit SbtChanged(alice);
        main.revokeSbt(alice, 1);
        vm.stopPrank();

        ZeroXSixCIdentity.IssuedSBT[] memory issued = _sbtsOf(alice);
        assertEq(issued.length, 2);
        assertEq(issued[0].sbtTypeId, 3);
        assertEq(issued[1].sbtTypeId, 2);
        assertEq(_sbtsOf(bob).length, 1);
    }

    function test_revokeMissingSbtReverts() public {
        vm.startPrank(owner);
        main.createSbtTemplate(1, "Member");
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroXSixCIdentity.SbtNotIssued.selector,
                alice,
                uint32(1)
            )
        );
        main.revokeSbt(alice, 1);
        vm.stopPrank();
    }
}
