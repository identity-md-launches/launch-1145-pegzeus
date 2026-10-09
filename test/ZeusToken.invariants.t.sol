// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZeusToken} from "../src/ZeusToken.sol";

/// @notice Drives Pegzeus (ZEUS) with random call sequences from several actors and checks, after
///         every call, that the token keeps its books: the fixed supply never changes, what every
///         holder owns is exactly what was moved to it, allowances are spent exactly, failed calls
///         change nothing, and no address outside the set the handler has paid ever holds anything.
/// @dev Every handler is a clamped entry point that must not revert (the runner is configured to
///      fail on an unexpected revert), so every expected failure is asserted in place with
///      `vm.expectRevert` and the exact custom error. Ghost variables record what the token should
///      hold; the invariants compare the token to the ghosts, never the token to itself.
contract ZeusTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    ZeusToken public immutable token;
    address public immutable deployer;

    /// @dev Named actors with keys (conceptually): the deployer and five holders. Approvals are
    ///      only ever made between these, which keeps the allowance ghost finite to enumerate.
    address[] public actors;

    /// @dev Every address that has ever been named as a receiver, actors included. Only addresses
    ///      in this list can hold a balance, so their balances must sum to the whole supply.
    address[] public tracked;
    mapping(address => bool) public isTracked;

    // Ghosts: what the token should report.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    // Running totals, used to check the suite is not vacuous and to describe a failing sequence.
    uint256 public ghostMoved; // total value moved by successful transfers (counts self-transfers)
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public successfulApprovals;
    uint256 public expectedReverts;
    uint256 public strangersPaid;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(ZeusToken token_, address deployer_, address[] memory holders) {
        token = token_;
        deployer = deployer_;
        _track(deployer_);
        actors.push(deployer_);
        for (uint256 i; i < holders.length; ++i) {
            _track(holders[i]);
            actors.push(holders[i]);
        }
        ghostBalance[deployer_] = SUPPLY;
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    /// @notice A transfer that must succeed: amount bounded by the sender's balance.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _pickTracked(fromSeed);
        address to = _pickTracked(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transferOk(from, to, amount);
    }

    /// @notice The sender's whole balance in one call, leaving exactly zero behind.
    function transferFullBalance(uint256 fromSeed, uint256 toSeed) public {
        address from = _pickTracked(fromSeed);
        address to = _pickTracked(toSeed);
        _transferOk(from, to, token.balanceOf(from));
        if (from != to) assertEq(token.balanceOf(from), 0, "full transfer left something behind");
    }

    /// @notice A self-transfer of any amount the actor holds: nothing may change.
    function transferToSelf(uint256 seed, uint256 amount) public {
        address who = _pickTracked(seed);
        uint256 before = token.balanceOf(who);
        amount = bound(amount, 0, before);
        _transferOk(who, who, amount);
        assertEq(token.balanceOf(who), before, "self-transfer changed the balance");
    }

    /// @notice One wei, the smallest non-zero move, from a holder that has at least one.
    function transferOneWei(uint256 fromSeed, uint256 toSeed) public {
        address from = _pickTracked(fromSeed);
        if (token.balanceOf(from) == 0) from = _richest();
        _transferOk(from, _pickTracked(toSeed), 1);
    }

    /// @notice A transfer to an address the fuzzer picks (never the zero address). The receiver
    ///         joins the tracked set so the conservation invariant still sees every balance.
    function transferToStranger(uint256 fromSeed, address to, uint256 amount) public {
        address from = _pickTracked(fromSeed);
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        if (!isTracked[to]) ++strangersPaid;
        _track(to);
        amount = bound(amount, 0, token.balanceOf(from));
        _transferOk(from, to, amount);
    }

    /// @notice More than the sender holds: must revert with the exact error and move nothing.
    function transferExceedingBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) public {
        address from = _pickTracked(fromSeed);
        address to = _pickTracked(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++expectedReverts;

        assertEq(token.balanceOf(from), ghostBalance[from], "failed transfer changed the sender");
        assertEq(token.balanceOf(to), ghostBalance[to], "failed transfer changed the receiver");
    }

    /// @notice Any amount to the zero address: must revert with ZeroAddress and move nothing.
    function transferToZeroAddress(uint256 fromSeed, uint256 amount) public {
        address from = _pickTracked(fromSeed);
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(from);
        token.transfer(address(0), amount);
        ++expectedReverts;
        assertEq(token.balanceOf(from), ghostBalance[from], "failed transfer changed the sender");
    }

    // ---------------------------------------------------------------------------------------------
    // approve
    // ---------------------------------------------------------------------------------------------

    /// @notice Set an allowance to any value, the unlimited sentinel included, between two actors.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        _approveOk(_pickActor(ownerSeed), _pickActor(spenderSeed), amount);
    }

    /// @notice Set the unlimited allowance explicitly, so the sentinel path is hit often.
    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) public {
        _approveOk(_pickActor(ownerSeed), _pickActor(spenderSeed), type(uint256).max);
    }

    /// @notice Clear an allowance.
    function approveZero(uint256 ownerSeed, uint256 spenderSeed) public {
        _approveOk(_pickActor(ownerSeed), _pickActor(spenderSeed), 0);
    }

    /// @notice The zero address as spender: must revert and leave every allowance alone.
    function approveZeroAddressSpender(uint256 ownerSeed, uint256 amount) public {
        address owner = _pickActor(ownerSeed);
        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(owner);
        token.approve(address(0), amount);
        ++expectedReverts;
        assertEq(token.allowance(owner, address(0)), 0, "zero-address spender got an allowance");
    }

    // ---------------------------------------------------------------------------------------------
    // transferFrom
    // ---------------------------------------------------------------------------------------------

    /// @notice A transferFrom that must succeed: amount bounded by both allowance and balance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        address to = _pickTracked(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);
        _transferFromOk(spender, owner, to, amount);
    }

    /// @notice Spend an allowance to exactly zero, the boundary where "enough" becomes "not enough".
    function transferFromWholeAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        address to = _pickTracked(toSeed);
        amount = bound(amount, 0, token.balanceOf(owner));
        _approveOk(owner, spender, amount);
        _transferFromOk(spender, owner, to, amount);
        assertEq(token.allowance(owner, spender), 0, "whole allowance spent but not zero");
    }

    /// @notice Spend more than allowed (finite allowance): must revert with the exact error and
    ///         leave balances and the allowance untouched.
    function transferFromExceedingAllowance(
        uint256 spenderSeed,
        uint256 ownerSeed,
        uint256 toSeed,
        uint256 allowed,
        uint256 excess
    ) public {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        address to = _pickTracked(toSeed);
        allowed = bound(allowed, 0, SUPPLY);
        excess = bound(excess, 1, SUPPLY);
        _approveOk(owner, spender, allowed);
        uint256 amount = allowed + excess;

        vm.expectRevert(
            abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, owner, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++expectedReverts;

        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom consumed allowance");
        assertEq(token.balanceOf(owner), ghostBalance[owner], "failed transferFrom moved the owner's balance");
        assertEq(token.balanceOf(to), ghostBalance[to], "failed transferFrom paid the receiver");
    }

    /// @notice Allowance is sufficient but the owner's balance is not: must revert with
    ///         InsufficientBalance and the allowance must not be consumed by the failure.
    function transferFromExceedingBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        public
    {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        address to = _pickTracked(toSeed);
        uint256 held = token.balanceOf(owner);
        excess = bound(excess, 1, SUPPLY);
        uint256 amount = held + excess;
        _approveOk(owner, spender, amount);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientBalance.selector, owner, held, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++expectedReverts;

        assertEq(token.allowance(owner, spender), amount, "failed transferFrom consumed allowance");
        assertEq(token.balanceOf(owner), held, "failed transferFrom moved the owner's balance");
    }

    /// @notice transferFrom to the zero address with enough allowance and balance: must revert
    ///         with ZeroAddress and consume no allowance.
    function transferFromToZeroAddress(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) public {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        amount = bound(amount, 0, token.balanceOf(owner));
        _approveOk(owner, spender, amount);

        vm.expectRevert(ZeusToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ++expectedReverts;

        assertEq(token.allowance(owner, spender), amount, "failed transferFrom consumed allowance");
        assertEq(token.balanceOf(owner), ghostBalance[owner], "failed transferFrom moved the owner's balance");
    }

    /// @notice A spender with no allowance at all (the common "stranger tries to pull" case).
    function transferFromWithoutAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        public
    {
        address spender = _pickActor(spenderSeed);
        address owner = _pickActor(ownerSeed);
        address to = _pickTracked(toSeed);
        _approveOk(owner, spender, 0);
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ZeusToken.InsufficientAllowance.selector, owner, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++expectedReverts;
        assertEq(token.balanceOf(owner), ghostBalance[owner], "a spender without allowance moved a balance");
    }

    // ---------------------------------------------------------------------------------------------
    // Hostile input that must do nothing
    // ---------------------------------------------------------------------------------------------

    /// @notice Any selector that is not one of the three mutators, with arbitrary arguments, from
    ///         any actor: the call may fail or succeed (views succeed) but no state may change.
    ///         The invariants check that; this only forbids the three selectors so the ghosts stay valid.
    function callArbitrarySelector(uint256 seed, bytes4 selector, bytes32 arg1, bytes32 arg2) public {
        if (
            selector == ZeusToken.transfer.selector || selector == ZeusToken.approve.selector
                || selector == ZeusToken.transferFrom.selector
        ) {
            selector = bytes4(keccak256("mint(address,uint256)"));
        }
        vm.prank(_pickTracked(seed));
        (bool ok,) = address(token).call(abi.encodePacked(selector, arg1, arg2));
        ok;
    }

    /// @notice Ether sent to the token with empty or arbitrary calldata must be refused.
    function sendEther(uint256 seed, uint256 amount, bytes4 selector) public {
        address from = _pickTracked(seed);
        amount = bound(amount, 1, 1_000 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}(selector == bytes4(0) ? bytes("") : abi.encodePacked(selector));
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transferOk(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(from, to, amount);
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender paid a different amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver got a different amount");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
        }
        ghostMoved += amount;
        ++successfulTransfers;
    }

    function _approveOk(address owner, address spender, uint256 amount) private {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(owner, spender, amount);
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "allowance not set to the approved value");
        ghostAllowance[owner][spender] = amount;
        ++successfulApprovals;
    }

    function _transferFromOk(address spender, address owner, address to, uint256 amount) private {
        uint256 allowedBefore = token.allowance(owner, spender);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(owner, to, amount);
        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (allowedBefore == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowedBefore - amount, "allowance not spent exactly");
            ghostAllowance[owner][spender] = allowedBefore - amount;
        }
        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "transferFrom to self changed the balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner paid a different amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver got a different amount");
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
        }
        if (spender != owner && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender's own balance moved");
        }
        ghostMoved += amount;
        ++successfulTransferFroms;
    }

    function _track(address who) private {
        if (!isTracked[who]) {
            isTracked[who] = true;
            tracked.push(who);
        }
    }

    function _pickActor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickTracked(uint256 seed) private view returns (address) {
        return tracked[seed % tracked.length];
    }

    function _richest() private view returns (address best) {
        uint256 most;
        for (uint256 i; i < tracked.length; ++i) {
            uint256 b = token.balanceOf(tracked[i]);
            if (b >= most) {
                most = b;
                best = tracked[i];
            }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract ZeusTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant DEPLOYER = address(0xDE91);

    ZeusToken internal token;
    ZeusTokenHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new ZeusToken();

        address[] memory holders = new address[](5);
        holders[0] = address(0xA11CE);
        holders[1] = address(0xB0B);
        holders[2] = address(0xCA201);
        holders[3] = address(0xDA4E);
        holders[4] = address(0xE4E);
        handler = new ZeusTokenHandler(token, DEPLOYER, holders);

        // Only the handler is called by the runner; the token is driven through it.
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------------------------------

    /// @dev The fixed supply: the number the manifest states, after any sequence of calls.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "the constant changed");
    }

    /// @dev Conservation: every balance the handler could have created, summed, is exactly the
    ///      supply. Nothing is minted, nothing is burned, nothing leaks to an address nobody paid.
    function invariant_trackedBalancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.tracked(i));
        }
        assertEq(sum, token.totalSupply(), "tracked balances do not sum to the supply");
    }

    /// @dev Nobody has more than they were paid and nobody has less than they kept.
    function invariant_balancesMatchGhosts() public view {
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.tracked(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "balance differs from what was moved");
        }
    }

    /// @dev No single holder can exceed the supply (implied by the sum, stated for a clear failure).
    function invariant_noHolderExceedsSupply() public view {
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.tracked(i)), SUPPLY, "a holder has more than the supply");
        }
    }

    /// @dev The zero address is refused as a receiver, so it never accumulates anything.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @dev The token contract itself and the handler are not paid by any handler path, and no
    ///      path moves value to them implicitly (no fee, no tax, no reflection).
    function invariant_noImplicitRecipients() public view {
        if (!handler.isTracked(address(token))) assertEq(token.balanceOf(address(token)), 0, "token holds itself");
        if (!handler.isTracked(address(handler))) assertEq(token.balanceOf(address(handler)), 0, "handler paid");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    /// @dev Every allowance between actors is exactly what was approved minus what was spent, and
    ///      the unlimited sentinel is never decremented.
    function invariant_allowancesMatchGhosts() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance differs from approved minus spent"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0, "zero-address spender has an allowance");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata never changes
    // ---------------------------------------------------------------------------------------------

    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "Pegzeus");
        assertEq(token.symbol(), "ZEUS");
        assertEq(token.decimals(), 18);
    }

    // ---------------------------------------------------------------------------------------------
    // Non-vacuity: the campaign exercised the paths the invariants are about
    // ---------------------------------------------------------------------------------------------

    /// @dev Runs once at the end of the campaign on the last sequence's state. With 100 calls over
    ///      twenty handlers, a sequence with no successful transfer, no approval and no expected
    ///      revert does not happen by chance; if it does, the handler selection is broken.
    function afterInvariant() public view {
        assertGt(handler.successfulTransfers() + handler.successfulTransferFroms(), 0, "no value ever moved");
        assertGt(handler.successfulApprovals(), 0, "no allowance was ever set");
        assertGt(handler.expectedReverts(), 0, "no failure path was ever hit");
    }
}
