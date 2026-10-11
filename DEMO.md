# FairOpenHook — Demo

> Bots siphon 4.39% of every Community Coin launch for dust + gas, while the
> POOL4 burn engine sits idle and staking rewards run dry. FairOpenHook stops
> the extraction — and turns every manipulation attempt into fuel for burns
> and rewards.

## 1. The attack (before)

Reproduced on a **mainnet fork at block 26158808** (the SWARMLER #1212 launch),
using the **real IMD PoolManager** and **real $IMD**, with the pool recreated
faithfully (2.5e-6 IMD/token opening price, 900M single-sided out-of-range,
dust in-range):

| Metric | Value |
|---|---|
| Attacker buy | 118.88 IMD |
| Tokens extracted | **2,129.36** |
| Price swing | **22,059x** |
| Fee paid by attacker | 1.486 IMD (1.25%) |
| Result | **ATTACK SUCCEEDS** |

Manipulation at this scale costs pocket change. The 1.25% flat fee is no deterrent.

## 2. The defense (after)

The **identical pool** with FairOpenHook attached. The **identical attack**:

| Metric | Value |
|---|---|
| Result | **REVERTS — `BreakerTripped()`** |
| Attacker's profit | 0 (minus gas) |

The circuit breaker kills the 22,059x swing outright. Sub-breaker manipulation
fares no better: the dynamic fee (`0.30% + 150 × impact`) charges 37.8% at the
25% breaker boundary — economically irrational.

## 3. Normal trading is untouched

A legit 0.01 IMD buy on a healthy hooked pool: **succeeds** at a fair price
(−0.3%), zero surcharge. Fair launches trade cheap; only manipulation pays.

## 4. Where the captured fees go

Every surcharge is minted as ERC6909 claims on the hook and routed via
`harvest()` to an immutable treasury — a **new reward stream for the IMD
flywheel** (burns / staker & seat rewards) that doesn't depend on POOL4 sell
pressure.

## Reproduce it

```bash
# 22 unit tests
forge test

# Mainnet-fork attack replay (needs an Ethereum RPC)
forge test --match-contract AttackReplay -vv
```

Full numbers: [ATTACK_REPLAY.md](ATTACK_REPLAY.md) · Design: [DESIGN.md](DESIGN.md)
