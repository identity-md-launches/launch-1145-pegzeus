// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ZeusToken} from "../src/ZeusToken.sol";

/// @notice Edge and failure-path tests for Pegzeus (ZEUS) that the behavioural suite does not pin:
///         boundaries of the allowance sentinel, failed calls leaving no trace, exact event counts,
///         ABI return shapes, malformed calldata, and fuzz properties with bounded (never discarded)
///         inputs.
/// @dev Complements test/ZeusToken.t.sol; nothing here is repeated from it.
contract ZeusTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant MAX = type(uint256).max;

    address internal constant DEPLOYER = address(0xDE91);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4DE4);

    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_SIG = keccak256("Approval(address,address,uint256)");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    ZeusToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new ZeusToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance sentinel boundaries
    // ---------------------------------------------------------------------------------------------

    /// @dev Only exactly type(uint256).max is unlimited. One below it is an ordinary allowance and
    ///      is decremented like any other.
    function test_allowanceOneBelowMaxIsNotUnlimited() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX - 1);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);

        assertEq(token.allowance(DEPLOYER, SPENDER), MAX - 2, "max-1 was treated as unlimited");
    }

    /// @dev Spending exactly the allowance drives it to zero and emits Approval(…, 0); the next
    ///      wei then fails with the zero allowance in the error.
    function test_spendingExactAllowanceLeavesZeroThenRefusesMore() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10 ether);

        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(DEPLOYER, SPENDER, 0);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 10 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    /// @dev Unlimited allowance survives many pulls, including pulling the owner's whole balance.
    function test_unlimitedAllowanceSurvivesDrainingTheOwner() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);

        vm.startPrank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, SUPPLY / 2);
        token.transferFrom(DEPLOYER, BOB, SUPPLY / 4);
        token.transferFrom(DEPLOYER, BOB, SUPPLY - SUPPLY / 2 - SUPPLY / 4);
        vm.stopPrank();

        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(BOB), SUPPLY);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX, "unlimited allowance was decremented");
    }

    /// @dev An unlimited allowance with an empty owner still fails on balance, with the balance error.
    function test_RevertWhen_unlimitedAllowanceButOwnerIsEmpty() public {
        vm.prank(ALICE);
        token.approve(SPENDER, MAX);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.allowance(ALICE, SPENDER), MAX);
    }

    /// @dev The owner calling transferFrom on its own balance is not exempt from the allowance.
    function test_RevertWhen_ownerPullsOwnBalanceWithoutSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    /// @dev Self-approval works like any other approval, and self-transferFrom spends it.
    function test_selfApprovalThenSelfTransferFromSpendsAllowance() public {
        vm.startPrank(DEPLOYER);
        token.approve(DEPLOYER, 5 ether);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 2 ether));
        vm.stopPrank();

        assertEq(token.allowance(DEPLOYER, DEPLOYER), 3 ether);
        assertEq(token.balanceOf(BOB), 2 ether);
    }

    /// @dev Allowances are per (owner, spender): approving one spender grants nothing to another,
    ///      and one owner's approval says nothing about another owner.
    function test_allowanceIsIsolatedPerPair() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 100 ether);

        assertEq(token.allowance(DEPLOYER, BOB), 0);
        assertEq(token.allowance(SPENDER, DEPLOYER), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Failed calls leave no trace
    // ---------------------------------------------------------------------------------------------

    function test_failedTransferFromDoesNotConsumeAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 10 ether);

        // Balance too low: allowance check passes, balance check fails.
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 6 ether);

        assertEq(token.allowance(ALICE, SPENDER), 10 ether, "a reverted transferFrom spent allowance");
        assertEq(token.balanceOf(ALICE), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_failedTransferEmitsNothing() public {
        vm.recordLogs();
        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeCall(ZeusToken.transfer, (BOB, 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0, "a reverted transfer left an event");
    }

    /// @dev The largest possible amount is refused by the balance check and never reaches arithmetic.
    function test_RevertWhen_transferMaxUint() public {
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, MAX);
    }

    function test_RevertWhen_transferFromMaxUintWithUnlimitedAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, MAX);
    }

    /// @dev Zero to zero address is still refused: the receiver check comes before the amount.
    function test_RevertWhen_transferZeroToZeroAddress() public {
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.transfer(address(0), 0);
    }

    function test_RevertWhen_approveZeroToZeroAddressSpender() public {
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.approve(address(0), 0);
    }

    /// @dev Pulling zero from the zero address is accepted by the arithmetic (nothing to check
    ///      fails) and moves no value. The event it emits is reported separately, not asserted here.
    function test_transferFromZeroAddressOfZeroMovesNothing() public {
        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeCall(ZeusToken.transferFrom, (address(0), ALICE, 0)));
        ok;
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// @dev Pulling one wei from the zero address is refused: it has no allowance to give.
    function test_RevertWhen_transferFromZeroAddressOfOneWei() public {
        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, address(0), ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(0), ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Exact event counts
    // ---------------------------------------------------------------------------------------------

    function test_transferEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_SIG);
        assertEq(logs[0].emitter, address(token));
    }

    function test_approveEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], APPROVAL_SIG);
    }

    /// @dev A finite allowance spend emits Approval (new allowance) then Transfer, in that order.
    function test_transferFromWithFiniteAllowanceEmitsApprovalThenTransfer() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10 ether);

        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], APPROVAL_SIG);
        assertEq(abi.decode(logs[0].data, (uint256)), 6 ether);
        assertEq(logs[1].topics[0], TRANSFER_SIG);
        assertEq(abi.decode(logs[1].data, (uint256)), 4 ether);
    }

    /// @dev An unlimited allowance spend emits only Transfer: no Approval, since nothing changed.
    function test_transferFromWithUnlimitedAllowanceEmitsOnlyTransfer() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);

        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_SIG);
    }

    function test_constructorEmitsExactlyOneMintEvent() public {
        vm.recordLogs();
        vm.prank(ALICE);
        ZeusToken fresh = new ZeusToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], TRANSFER_SIG);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(ALICE))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ABI shape: return data and malformed calldata
    // ---------------------------------------------------------------------------------------------

    /// @dev Integrators that check `returndata.length` and decode a bool must get exactly one word.
    function test_mutatorsReturnExactlyOneTrueWord() public {
        vm.prank(DEPLOYER);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(ZeusToken.transfer, (ALICE, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));

        vm.prank(DEPLOYER);
        (ok, ret) = address(token).call(abi.encodeCall(ZeusToken.approve, (SPENDER, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));

        vm.prank(SPENDER);
        (ok, ret) = address(token).call(abi.encodeCall(ZeusToken.transferFrom, (DEPLOYER, BOB, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));
    }

    function test_viewsReturnOneWordEach() public view {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeCall(ZeusToken.totalSupply, ()));
        assertTrue(ok);
        assertEq(ret.length, 32);
        (ok, ret) = address(token).staticcall(abi.encodeCall(ZeusToken.balanceOf, (DEPLOYER)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint8)), 18);
    }

    /// @dev Short calldata for transfer (selector plus one word) must revert, not transfer with a
    ///      zero-filled amount or address.
    function test_RevertWhen_transferCalldataIsTruncated() public {
        bytes memory full = abi.encodeCall(ZeusToken.transfer, (ALICE, 1 ether));
        bytes memory truncated = new bytes(36);
        for (uint256 i; i < 36; ++i) {
            truncated[i] = full[i];
        }
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok, "truncated transfer calldata was accepted");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// @dev Dirty high bits in an address argument are refused by the ABI decoder.
    function test_RevertWhen_addressArgumentHasDirtyHighBits() public {
        bytes memory data = abi.encodePacked(
            ZeusToken.transfer.selector, bytes32(uint256(uint160(ALICE)) | (uint256(1) << 160)), uint256(1 ether)
        );
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a non-canonical address was accepted");
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Empty calldata without value has nowhere to go: no receive, no fallback.
    function test_RevertWhen_emptyCalldata() public {
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata was accepted");
    }

    /// @dev Value sent to an otherwise valid call is refused: no function is payable.
    function test_RevertWhen_transferCalledWithValue() public {
        vm.deal(DEPLOYER, 1 ether);
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call{value: 1 wei}(abi.encodeCall(ZeusToken.transfer, (ALICE, 1)));
        assertFalse(ok, "a payable transfer was accepted");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment edge cases
    // ---------------------------------------------------------------------------------------------

    /// @dev Two deployments are independent books: moving in one does not touch the other, and a
    ///      token may hold another token's units like any address.
    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        ZeusToken other = new ZeusToken();

        vm.prank(DEPLOYER);
        token.transfer(address(other), 1 ether);

        assertEq(other.balanceOf(DEPLOYER), 0);
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(other)), 1 ether);
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Tokens sent to the token's own address are accepted and stay there; there is no
    ///      special case for it and no way to get them back (documented, standard ERC-20 behaviour).
    function test_transferToTokenContractIsAcceptedAndStranded() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        // The token contract cannot call transfer on itself, so nobody can move it.
        assertEq(token.allowance(address(token), DEPLOYER), 0);
    }

    /// @dev Deploying from a contract constructor (as a factory does) mints to that contract.
    function test_factoryStyleDeploymentMintsToTheFactory() public {
        Factory factory = new Factory();
        ZeusToken deployed = factory.token();
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        // The factory can forward exactly what it holds, as the launch does.
        factory.forward(BOB, SUPPLY / 10);
        assertEq(deployed.balanceOf(BOB), SUPPLY / 10);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY - SUPPLY / 10);
    }

    /// @dev Creation code with extra bytes appended (as if constructor arguments were passed) still
    ///      deploys and still mints to the creator: the constructor ignores them.
    function test_creationCodeIgnoresAppendedBytes() public {
        bytes memory code = abi.encodePacked(type(ZeusToken).creationCode, abi.encode(address(0xBAD), uint256(1)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "constructor failed with appended bytes");
        assertEq(ZeusToken(deployed).balanceOf(address(this)), SUPPLY);
        assertEq(ZeusToken(deployed).balanceOf(address(0xBAD)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz with bounded inputs (nothing discarded)
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveSetsExactly(address spender, uint256 amount) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        vm.prank(DEPLOYER);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(DEPLOYER, spender), amount);
        if (spender != DEPLOYER) {
            assertEq(token.allowance(spender, DEPLOYER), 0, "allowance leaked to the reverse pair");
        }
        assertEq(token.allowance(DEPLOYER, ALICE == spender ? BOB : ALICE), 0, "allowance leaked to another spender");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveOverwritesNotAccumulates(uint256 first, uint256 second) public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, first);
        token.approve(SPENDER, second);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), second);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferChainConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(DEPLOYER, c);

        assertEq(token.balanceOf(DEPLOYER), SUPPLY - a + c);
        assertEq(token.balanceOf(ALICE), a - b);
        assertEq(token.balanceOf(BOB), b - c);
        assertEq(token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripReturnsExactly(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "a round trip lost or gained value");
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitThenMergeEqualsSingleTransfer(uint256 amount, uint256 split) public {
        amount = bound(amount, 0, SUPPLY);
        split = bound(split, 0, amount);

        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, split);
        token.transfer(ALICE, amount - split);
        vm.stopPrank();

        assertEq(token.balanceOf(ALICE), amount, "two transfers do not add up to one");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAboveFiniteAllowanceReverts(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, MAX - 1);
        excess = bound(excess, 1, MAX - allowed);
        uint256 amount = allowed + excess;

        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);

        vm.expectRevert(
            abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, DEPLOYER, SPENDER, allowed, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, amount);

        assertEq(token.allowance(DEPLOYER, SPENDER), allowed, "a failed pull changed the allowance");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAboveBalanceWithEnoughAllowanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, SUPPLY);
        uint256 amount = held + excess;

        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(SPENDER, amount);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);

        assertEq(token.allowance(ALICE, SPENDER), amount, "a failed pull changed the allowance");
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unlimitedAllowanceNeverDecrements(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);

        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.startPrank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, first);
        token.transferFrom(DEPLOYER, BOB, second);
        vm.stopPrank();

        assertEq(token.allowance(DEPLOYER, SPENDER), MAX);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferToAnyNonZeroAddressDeliversWhole(address to, uint256 amount) public {
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));

        if (to == DEPLOYER) {
            assertEq(token.balanceOf(to), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), before + amount, "receiver got a different amount");
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCanNeverMoveAnything(address stranger, address victim, uint256 amount) public {
        stranger = address(uint160(bound(uint256(uint160(stranger)), 1, type(uint160).max)));
        victim = address(uint160(bound(uint256(uint160(victim)), 1, type(uint160).max)));
        amount = bound(amount, 1, MAX);
        if (stranger == victim) victim = DEPLOYER;
        if (stranger == DEPLOYER) stranger = ALICE;
        uint256 victimBefore = token.balanceOf(victim);

        vm.prank(stranger);
        (bool ok,) = address(token).call(abi.encodeCall(ZeusToken.transferFrom, (victim, stranger, amount)));
        assertFalse(ok, "a stranger pulled from a holder");
        assertEq(token.balanceOf(victim), victimBefore);
        assertEq(token.balanceOf(stranger), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_randomCalldataNeverChangesBalancesOrAllowances(bytes calldata data, address caller) public {
        caller = address(uint160(bound(uint256(uint160(caller)), 1, type(uint160).max)));
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 7 ether);

        // Exclude only the three mutators called by the deployer or the spender, which are allowed
        // to move things; anyone else, or any other selector, must leave the state as it was.
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        bool mutator = selector == ZeusToken.transfer.selector || selector == ZeusToken.approve.selector
            || selector == ZeusToken.transferFrom.selector;
        if (mutator && (caller == DEPLOYER || caller == SPENDER)) caller = ALICE;

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, SPENDER), 7 ether);
    }
}

/// @dev Stand-in for a factory: deploys the token in its constructor and forwards from its balance.
contract Factory {
    ZeusToken public immutable token;

    constructor() {
        token = new ZeusToken();
    }

    function forward(address to, uint256 amount) external {
        require(token.transfer(to, amount), "forward failed");
    }
}
