# FairOpenHook

A Uniswap V4 hook that makes Community Coin launches manipulation-resistant.
Built for the **Identity MD Hackathon** (Oct 2026).

## The problem

On-chain analysis of the 12 latest Community Coin launches showed two real attack patterns:

- **Zero-capital extraction** — one transaction at block+1 swung a launch's price ~121M-x; the attacker walked away with 4.39% of supply for dust + gas.
- **Fast sniping** — bots grabbed ~6.3% of supply within the first 14 blocks (same operator across launches).

Meanwhile the IMD flywheel is stalling on both ends: launches get extracted so nobody trades (8/12 launches had zero swaps), and the POOL4 burn engine sits idle with dry staking rewards.

## The fix — one hook, three mechanisms

1. **Dynamic price-impact fee** — `fee = 0.30% + 150 × impactBps`, capped at 90%. Manipulation becomes economically irrational: LPs always earn the base fee, the surcharge is captured by the hook.
2. **Circuit breaker** — reverts any swap moving the price >25% inside the 100-block opening window (measured in true price bps off a rolling reference).
3. **Wallet caps + cooldown** — max 0.5% of supply per wallet, one swap per 3 blocks during the window. Sells don't count toward the cap.

Every manipulation attempt becomes fuel for the ecosystem: captured surcharges are routed via `harvest()` to an immutable treasury — a new reward stream for burns/stakers that doesn't depend on POOL4 sell pressure.

## Proof, not promises

- **Attack replay on a mainnet fork** (real IMD PoolManager + real $IMD, block 26158808): the exact SWARMLER attack (118.88 IMD → 2,129 tokens, 22,059x price swing) **succeeds without the hook** and **reverts with `BreakerTripped()` with the hook**. Legit small swaps pass untouched. See [ATTACK_REPLAY.md](ATTACK_REPLAY.md).
- **29/29 tests passing** — `forge test`.

## Repo layout

- `src/FairOpenHook.sol` — the hook
- `src/FairLaunchFactory.sol` — demo factory: deploys token + hook + seeds single-sided liquidity, mimicking the Community Coins launch flow
- `test/` — unit tests, fork attack-replay (`AttackReplay.t.sol`), factory tests
- `script/Deploy.s.sol` — deployment script (`PRIVATE_KEY`, `HOOK_SALT`, `TREASURY_ADDRESS` env)
- `DESIGN.md` — full design doc, parameters, tradeoffs

## Quick start

```bash
forge build
forge test            # 29/29 (unit)
forge test --match-contract AttackReplay -vv   # mainnet-fork replay (needs RPC)
```

Built solo for the Identity MD Hackathon. Fair launches trade cheap; manipulation subsidizes burns.
