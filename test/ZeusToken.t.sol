// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZeusToken} from "../src/ZeusToken.sol";
import {DeployZeusToken} from "../script/DeployZeusToken.s.sol";

/// @notice Behavioural tests for Pegzeus (ZEUS): metadata, the one-time mint, transfers, allowances,
///         the absence of any privileged surface, and bytecode properties the launch requires.
/// @dev Tests read no environment variables and do not depend on the address running them: the
///      deployer is an explicit, pranked address.
contract ZeusTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal constant DEPLOYER = address(0xDE91);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4DE4);
    address internal constant STRANGER = address(0xBEEF);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    ZeusToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new ZeusToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Pegzeus");
        assertEq(token.symbol(), "ZEUS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), DEPLOYER, SUPPLY);
        vm.prank(DEPLOYER);
        ZeusToken fresh = new ZeusToken();

        assertEq(fresh.balanceOf(DEPLOYER), SUPPLY, "deployer does not hold the whole supply");
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0, "the test contract received tokens it should not have");
    }

    function test_deployerIsWhoeverCreatesTheContract() public {
        // Whoever runs the constructor holds the supply: on the launch that is the factory.
        vm.prank(STRANGER);
        ZeusToken fresh = new ZeusToken();
        assertEq(fresh.balanceOf(STRANGER), SUPPLY);
        assertEq(fresh.balanceOf(DEPLOYER), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, ALICE, 1_000 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 1_000 ether));

        assertEq(token.balanceOf(ALICE), 1_000 ether, "receiver got a different amount");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1_000 ether, "sender paid a different amount");
        assertEq(token.totalSupply(), SUPPLY, "transfer changed the supply");
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 5 ether));
        assertEq(token.balanceOf(ALICE), 5 ether);
    }

    function test_transferWholeBalanceLeavesZero() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, 10 ether, 10 ether + 1));
        vm.prank(ALICE);
        token.transfer(BOB, 10 ether + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, STRANGER, 0, 1));
        vm.prank(STRANGER);
        token.transfer(BOB, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / allowance / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, SPENDER, 100 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, 100 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 100 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 100 ether);
        token.approve(SPENDER, 7 ether);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 7 ether);
    }

    function test_approveZeroClearsAllowance() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 100 ether);
        token.approve(SPENDER, 0);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
    }

    function test_RevertWhen_approveZeroAddressSpender() public {
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceAndEmits() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, SPENDER, 60 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 40 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 40 ether));

        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 40 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 60 ether, "allowance was not decremented");
        assertEq(token.balanceOf(SPENDER), 0, "the spender kept something");
    }

    function test_transferFromWithUnlimitedAllowanceDoesNotDecrement() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 123 ether);

        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(BOB), 123 ether);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, SPENDER, 10 ether, 10 ether + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 10 ether + 1);
    }

    function test_RevertWhen_transferFromWithoutAnyAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, STRANGER, 0, 1));
        vm.prank(STRANGER);
        token.transferFrom(DEPLOYER, STRANGER, 1);
    }

    function test_RevertWhen_transferFromExceedsOwnerBalanceDespiteAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 6 ether);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1 ether);
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface
    // ---------------------------------------------------------------------------------------------

    /// @dev The contract exposes no mint, owner, pause, blocklist or upgrade entry point. Every such
    ///      selector reverts (no fallback) for a stranger and for the deployer alike, and the supply
    ///      and balances are untouched.
    function test_noAdminSelectorExists() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1 ether);

        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        address[2] memory callers = [STRANGER, DEPLOYER];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1 ether);
    }

    function test_RevertWhen_sendingEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
    }

    function test_deployerCannotMoveAnotherHoldersBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, ALICE, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Bytecode properties
    // ---------------------------------------------------------------------------------------------

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Deploying the raw creation code with nothing appended succeeds and mints to the creator.
        bytes memory code = type(ZeusToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "constructor failed");
        assertEq(ZeusToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptMintsToTheBroadcaster() public {
        DeployZeusToken deployer = new DeployZeusToken();
        // The script contract itself is msg.sender of the creation when called directly.
        ZeusToken deployed = deployer.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.name(), "Pegzeus");
        assertEq(deployed.symbol(), "ZEUS");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of supply and exact accounting
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = bound(amount, 0, SUPPLY);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - held);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, held, held + excess));
        vm.prank(ALICE);
        token.transfer(BOB, held + excess);
    }

    function testFuzz_transferFromDecrementsAllowanceExactly(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, type(uint256).max - 1); // not unlimited
        spent = bound(spent, 0, allowed < SUPPLY ? allowed : SUPPLY);

        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, spent));

        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - spent);
        assertEq(token.balanceOf(BOB), spent);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_randomSelectorsNeverChangeSupply(bytes4 selector, bytes32 arg1, bytes32 arg2) public {
        vm.assume(
            selector != ZeusToken.transfer.selector && selector != ZeusToken.approve.selector
                && selector != ZeusToken.transferFrom.selector
        );
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(abi.encodePacked(selector, arg1, arg2));
        ok;
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }
}
