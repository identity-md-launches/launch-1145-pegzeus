# Pegzeus (ZEUS)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Property | Value |
| --- | --- |
| Solidity contract | `ZeusToken` (`src/ZeusToken.sol`) |
| `name()` | `Pegzeus` |
| `symbol()` | `ZEUS` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18 minor units) |
| Constructor arguments | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

The whole supply is minted exactly once, in the constructor, to `msg.sender` (the deployer). After
that the contract has no privileged caller of any kind.

## Behaviour

- Standard EIP-20: `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`, `totalSupply`,
  `name`, `symbol`, `decimals`, and the `Transfer` / `Approval` events.
- `totalSupply()` is a compile-time constant. No function can mint, so the supply can never grow.
  There is also no `burn`, so it can never shrink either (tokens may still be sent to any non-zero
  address and effectively abandoned there, as with any ERC-20).
- Transfers move exactly the amount requested: no fee, no tax, no reflection, no burn on transfer.
  This is what the launch requires: the factory's transfer of the swarm share, the distributor's
  claims, the Uniswap v4 seed and every swap all arrive whole.
- Transfers to the zero address and approvals of the zero-address spender revert (`ZeroAddress`).
- An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
- No owner, no minter, no pause, no blocklist, no freeze, no `burnFrom`, no seize, no upgrade path,
  no fallback or receive function. The runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`. The contract calls no other contract and imports no library.
- Custom errors: `InsufficientBalance(sender, balance, needed)`,
  `InsufficientAllowance(owner, spender, allowance, needed)`, `ZeroAddress()`.

## Assumptions

- The requester wants a plain token. The brief names a name, symbol and fixed supply and nothing
  else, so no taxes, vesting, reflections, governance or exemptions were added. Because transfers
  are untaxed, the token does not need the factory, pool manager or distributor addresses and takes
  no constructor arguments.
- The "deployer" in the brief is whoever runs the constructor. On the IdentityMD launch that is
  `ProjectFactory.launchCustom`, which then distributes the supply per the launch policy (see
  below). On a manual deployment it is the broadcasting key.
- The standard EIP-20 approval race (changing a non-zero allowance to another non-zero value) is
  left as in the standard; integrators that care should set the allowance to zero first or use
  exact-amount approvals.

## Deployment parameters

The token has no constructor arguments and no settings to configure after launch. There is no
"After launch" checklist: nothing is owner-settable because there is no owner.

Launch terms decided by the IdentityMD launch (recorded by the manifest step, not by this
repository; do not add a `launch.json` here):

- Chain: Ethereum mainnet (chain id 1).
- Paired currency: IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals).
- Pool: fee 12500 (1.25%), tick spacing 60, Uniswap v4 PoolManager.
- Economics (requester's, copied verbatim by the manifest step):
  `{"poolBps":8800,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xd6302976e590b9b947da8774b7f1246164e0ce98"}`.
- Supply flow at launch: the factory receives 100% from the constructor, forwards 10% to the
  launch's MerkleDistributor (contributor and seat shares), seeds the pool with 88% at the price
  derived from a 2,500 IMD market cap for the whole supply, and sends the remaining 2% to
  `remainderTo`.

### Manual / test deployment

```bash
forge build
forge script script/DeployZeusToken.s.sol:DeployZeusToken --rpc-url <RPC> --broadcast --private-key <KEY>
```

The script's `deploy()` does a single `new ZeusToken()`; `run()` wraps it in a broadcast. It reads
no environment variables. Whoever broadcasts receives the whole supply.

## Operational responsibilities

- **No admin exists.** Nobody can pause, freeze, mint, burn others' tokens, or upgrade. If a holder
  loses a key or sends tokens to a wrong address, nothing in the contract can recover them.
- **Supply distribution is the factory's job** on the launch, per the policy above. After the
  launch, the only ZEUS held by anyone is what the launch flows and trading gave them.
- **Explorer verification** after deployment belongs to the deployer: the token should be verified
  with `forge verify-contract` using this repository's `foundry.toml` settings (solc 0.8.26,
  optimizer 200 runs, cancun, no metadata hash) so the bytecode matches.
- **Pool and liquidity** are owned by the launch's contracts, not by this token.
- This repository's tests are not an audit. The contract is small and self-contained, but a
  separate adversarial review before release is still the responsible course for anything holding
  other people's value.

## Security notes (eth-security checklist applied)

- Access control: no privileged functions exist, so there is nothing to restrict.
- Reentrancy: the contract makes no external calls.
- Decimals: 18, fixed; the manifest must state `18`.
- Integer math: balances are updated in an `unchecked` block only after an explicit
  `fromBalance < value` check; the sum of balances is bounded by the constant supply.
- Return values: `transfer`, `approve` and `transferFrom` always return `true` or revert.
- Input validation: zero-address receiver and spender are rejected; zero amounts are allowed, as the
  standard permits.
- Events: every balance and allowance change emits `Transfer` or `Approval`.
- No proxies, no delegatecall, no signatures, no oracles, no swaps inside the token.
- Tools run: `forge build`, `forge test` (including fuzz tests at 256 runs), `forge fmt --check`.
  Slither and Mythril were not available in this environment and were not run.

## Repository layout

```
foundry.toml                 compiler pins and build settings (solc 0.8.26, bytecode_hash none)
remappings.txt               forge-std/ -> lib/forge-std/src/
src/ZeusToken.sol            the token
script/DeployZeusToken.s.sol deploy script (deploy() is called directly by tests)
test/ZeusToken.t.sol         unit and fuzz tests
lib/forge-std/               forge-std v1.9.7, vendored as plain files (MIT/Apache-2.0)
```

## Development

```bash
forge build
forge test -vv
forge fmt --check
```
