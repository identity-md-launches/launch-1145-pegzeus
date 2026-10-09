// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Pegzeus (ZEUS)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 ZEUS (18 decimals) is minted
///         once, in the constructor, to the deployer. There is no owner, no minter, no pause, no
///         blocklist, no fee and no upgrade path: after deployment the contract has no privileged
///         caller and the supply can never grow.
/// @dev Self-contained implementation of EIP-20 (no external library). Every function is
///      internal to this contract, so the bytecode links to nothing. Transfers and approvals to the
///      zero address are refused; an unlimited allowance (type(uint256).max) is not decremented.
contract ZeusToken {
    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    /// @notice The token name returned by `name()`.
    string public constant name = "Pegzeus";

    /// @notice The token symbol returned by `symbol()`.
    string public constant symbol = "ZEUS";

    /// @notice The number of decimals the token uses.
    uint8 public constant decimals = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(decimals);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ---------------------------------------------------------------------------------------------
    // Events (EIP-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to spend `needed` of `owner`'s balance but was allowed only `allowance`.
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);

    /// @notice A transfer or approval named the zero address as receiver or spender.
    error ZeroAddress();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the whole fixed supply to the deployer (`msg.sender`) exactly once.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The total supply, fixed at deployment. Nothing can change it.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice The balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice The remaining amount `spender` may move out of `owner`'s balance via `transferFrom`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------------------------------
    // Mutations
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves `value` from the caller to `to`.
    /// @dev Reverts with {ZeroAddress} if `to` is the zero address and with {InsufficientBalance}
    ///      if the caller holds less than `value`. Always returns true otherwise.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `value`.
    /// @dev Reverts with {ZeroAddress} if `spender` is the zero address. Overwrites, so callers
    ///      changing a non-zero allowance should be aware of the standard EIP-20 approval race.
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` from `from` to `to` using the caller's allowance.
    /// @dev Reverts with {InsufficientAllowance} if the caller's allowance is below `value`. An
    ///      allowance of type(uint256).max is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
        unchecked {
            // Cannot underflow: checked above. Cannot overflow: the sum of all balances is
            // TOTAL_SUPPLY, which is far below type(uint256).max.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert InsufficientAllowance(owner, spender, current, value);
        unchecked {
            _allowances[owner][spender] = current - value;
        }
        emit Approval(owner, spender, current - value);
    }
}
