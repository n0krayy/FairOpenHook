# FairOpenHook — Technical Design

**Status:** scope locked 2026-10-10 · **Hackathon:** Identity MD (submissions 7–21 Oct 2026)
**Stack:** Solidity 0.8.26 · Foundry · Uniswap V4 (deployed on IMD's PoolManager, not the canonical one)

---

## 1. Problem (validated on-chain, 2026-10-10)

Analysis of 12 latest Community Coin launches (blocks 9–10 Oct 2026), full report in
`~/workspace/imd-validation/LAPORAN.md`:

- **Pattern #1 — zero-capital extraction.** SWARMLER #1212: one tx at block+1 after launch
  swung the price 2.5e-6 → 303 → 2.78e-6 IMD/SWARMLER (~121M-x swing). Attacker walked away
  with 43.9M SWARMLER (4.39% of supply) for dust + gas. Root cause: the opening tick has
  near-zero liquidity, so the marginal price is degenerate and trivially manipulable.
- **Pattern #2 — fast sniping.** SC #1175: 17 txs in the first 14 blocks, a bot scooped
  ~63.3M SC (~6.3% of supply). The same EOA appears in both cases → a bot network sweeping
  across launches.
- 8 of 12 launches had ZERO swaps (no organic market). Launcher gets 0% of supply
  (not the cheater). The 10% MerkleDistributor is healthy (86–138 unique claimants).

**Launchpad mechanics (verified):** factory mints 1B tokens → 900M (90%) seeded as
single-sided liquidity in a Uniswap V4 pool paired with $IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee 1.25%), 100M (10%) to a
MerkleDistributor, 0% to the launcher. Fixed opening price (~2500 IMD market cap).
IMD runs its **own PoolManager** `0x000000000004444c5dc75cb358380d2e3de08a90`
and two factories (`0x12c63b58…`, `0xff03410d…`).

## 2. Product

**FairOpenHook** — a Uniswap V4 hook that makes the opening of every Community Coin pool
manipulation-resistant, without changing the launchpad's permissionless UX after the
opening window closes. Three mechanisms, one hook:

1. **Dynamic price-impact fee** — kills pattern #1 economically.
2. **Circuit breaker** — kills pattern #1 absolutely (backstop).
3. **Opening-window wallet caps + cooldown** — kills pattern #2.

Stretch goal (not core): identity-gated opening (identity.md NFT / staker / ERC-8004
agent allowlist for the first N blocks).

## 3. Architecture

```
FairOpenHook.sol        — the V4 hook (core product)
FairLaunchFactory.sol   — demo factory mimicking IMD's launch flow, attaches the hook
FeeTreasury.sol         — (optional v1: keep inside hook) accrues surcharge, harvest() routes it
test/                   — Foundry unit + fork tests, incl. attack replay
script/                 — deploy + demo scripts
```

**Hook permissions (flags):** `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`
(`BEFORE_SWAP_RETURNS_DELTA` for the dynamic fee override).
Hook address must be mined to match the flag bits (standard `HookMiner` flow).

**Pool config:** pools are initialized with the **dynamic-fee flag**
(`LPFeeLibrary.DYNAMIC_FEE_FLAG`) instead of IMD's static 1.25% — the hook returns
`fee | OVERRIDE_FEE_FLAG` from `beforeSwap`. Currency pair stays `IMD / <new token>`.

**Deployment target:** IMD's PoolManager `0x000000000004444c5dc75cb358380d2e3de08a90`
(mainnet). Demo: deploy hook + `FairLaunchFactory`, launch one demo coin through the
IMD explorer flow (hackathon criterion: launch through the IMD Protocol).

## 4. Mechanism specs

### 4.1 Dynamic price-impact fee (`beforeSwap`)

- Estimate the swap's price impact pre-execution from `slot0.sqrtPriceX96`, pool
  `liquidity`, and `params.amountSpecified` (standard V4 swap-step approximation;
  documented as an estimate — the circuit breaker is the exact backstop).
- `fee = baseFee + k * priceImpact`, clamped to `[baseFee, maxFee]`.
- Suggested params: `baseFee = 0.30%` (3000), `k` tuned so a 10% impact ≈ 5% fee,
  `maxFee = 90%`. On the SWARMLER attack shape (astronomical impact) the fee pins at
  max → extraction becomes unprofitable by construction.
- Fee override returned via `beforeSwap` (`fee | OVERRIDE_FEE_FLAG`).

### 4.2 Circuit breaker (`afterSwap`)

- `beforeInitialize` records `openBlock = block.number` and `openPrice = sqrtPriceX96`.
- `afterSwap` measures the *actual* settled price move vs. a rolling reference
  (last swap's price, or a short TWAP). If the move exceeds the threshold → **revert
  the whole swap**.
- Suggested params: during the opening window (first `WINDOW_BLOCKS` after init):
  max 25% move per swap. After the window: looser guard (e.g. 300%) or disabled —
  one config flag.
- Reverting in `afterSwap` is deliberate: it measures reality, not an estimate, and
  failed attacks still pay gas (attacker-negative expected value).

### 4.3 Wallet caps + cooldown (`beforeSwap`, opening window only)

- `WINDOW_BLOCKS = 100` (~20 min on Ethereum) from `openBlock`. All checks are pure
  `block.number` comparisons — no admin, no oracle, restrictions lift automatically.
- **Cap:** cumulative buy notional per address ≤ `MAX_BUY_PER_WALLET`
  (suggested: 0.5% of the 900M pool supply in IMD notional). Tracked in
  `mapping(bytes32 poolId => mapping(address trader => uint256 bought))`.
- **Cooldown:** max 1 swap per address per `COOLDOWN_BLOCKS = 3` blocks.
- **Trader identity:** `tx.origin` (documented tradeoff: correct for EOAs incl. all
  observed bots; smart-wallet/AA users share one bucket — acceptable for v1,
  flagged in the audit notes).
- Sells are unrestricted (no reason to block exits; also avoids trapping users).

### 4.4 Parameters (tunable, set at hook deployment)

| Param | Suggested | Rationale |
|---|---|---|
| `WINDOW_BLOCKS` | 100 | covers the observed attack zone (blocks 0–14) with margin |
| `baseFee` | 0.30% | near IMD's 1.25%? No — lower base, the *surcharge* does the work; LPs keep base |
| `maxFee` | 90% | makes degenerate-impact swaps strictly unprofitable |
| `breakerThreshold` (window) | 25% per swap | legit opens move <5%; attacks move 1000%+ |
| `MAX_BUY_PER_WALLET` | 0.5% of pool supply | bot grabbed 6.3% across addrs; forces wide distribution |
| `COOLDOWN_BLOCKS` | 3 | breaks same-block multi-tx snipe scripts |

## 5. Fee routing — wired into the IMD flywheel

- The **base fee** accrues to LPs normally (unchanged V4 behavior).
- The **dynamic surcharge** (fee − baseFee) accrues in the hook; `harvest()` sends it
  to a configurable `treasury` (default: split mirroring POOL4's ethos —
  e.g. % burn, % to POOL4 LPs). v1: single treasury address, settable once.
- This turns every attack attempt into fuel for the IMD economy: fair launches trade
  cheap, manipulation subsidizes burns.

## 6. Security considerations

- `afterSwap` revert = griefing vector? An attacker *paying gas to revert their own
  swap* only griefs themselves. Third parties can't trigger it on others' swaps.
- `tx.origin` note (see 4.3). Do **not** use it for auth — only for rate-limit
  accounting.
- Fee math: fixed-point, no division-before-multiplication, fuzzed.
- No admin keys on the hook itself (params immutable post-deploy; window logic is
  block-driven). Factory is demo-only.
- Known v1 limitation: MEV-boost-level censorship/timing games are out of scope;
  the hook targets *profitability* of manipulation, not ordering.

## 7. Test plan (Foundry)

1. **Unit:** fee curve (0% → pinned at max), breaker trips at 25.1% / passes at 24.9%,
   cap accounting, cooldown, window expiry (restrictions vanish at block+101).
2. **Fork (mainnet):** deploy against the real IMD PoolManager + IMD token.
3. **Attack replay (the demo centerpiece):** spin up a pool with hook, replay the
   SWARMLER-shaped tx → expect revert / 90% fee making it revert on profitability;
   same pool *without* the hook → extraction succeeds. Before/after, same blocks.
4. **Fuzz:** fee formula invariants (`baseFee ≤ fee ≤ maxFee`), breaker monotonicity.

## 8. Milestones (Oct 10 → Oct 21)

- **Oct 10–11:** repo scaffold, hook skeleton, address mining, `beforeInitialize`
  + window bookkeeping. *Done: design locked.*
- **Oct 12–13:** dynamic fee math + unit tests.
- **Oct 14:** circuit breaker + tests.
- **Oct 15:** caps/cooldown + tests.
- **Oct 16:** fork attack-replay simulation (before/after demo).
- **Oct 17:** fee routing / treasury + harvest.
- **Oct 18:** demo factory, mainnet deploy via IMD explorer flow, docs.
- **Oct 19:** dedicated X account, demo writeup/video, IMD Radar submission prep.
- **Oct 20–21:** buffer + submit via imdradar.site/hackathon.

## 9. Submission checklist

- [ ] Hook + factory deployed (launch *through the IMD Protocol* at explorer.imd.fun/launch)
- [ ] V4 hook / custom contract with meaningful functionality (✓ — not a standard token)
- [ ] Dedicated X account for the project
- [ ] Submitted via IMD Radar before deadline
- [ ] Validation report linked (proof the problem is real): `~/workspace/imd-validation/LAPORAN.md`

## 10. Open decisions (for build time, not now)

- Exact `k` for the fee curve → tune against fork simulation (Oct 16).
- Treasury split percentages → check POOL4's current split for mirroring.
- Whether to also gate the *demo* factory's first blocks on identity (stretch).
