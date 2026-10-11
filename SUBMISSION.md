# FairOpenHook — Hackathon Submission

## One-liner
Sniper-resistant Community Coin launches — every attack becomes fuel for the flywheel.

## About (IMD Radar, <1000 chars)

FairOpenHook is a Uniswap V4 hook that makes Community Coin launches resistant to sniper-bot manipulation. In the replayed SWARMLER #1212 attack, bots extracted 4.39% of supply for dust plus gas. FairOpenHook counters this with three mechanisms: (1) dynamic fee — 0.30% base plus 150x price impact, capped at 90%, making manipulation economically irrational; (2) circuit breaker — reverts swaps moving price over 25% in the 100-block opening window; (3) wallet caps — max 0.5% of supply per wallet, one swap per 3 blocks. Captured surcharges flow to an immutable treasury, a potential new reward stream for the IMD flywheel (burns, staker rewards) independent of sell pressure. Proven on a mainnet fork at block 26158808: the exact replayed attack (118.88 IMD for 2,129 tokens, 22,059x swing) reverts with BreakerTripped() with the hook attached, and a 0.01 IMD control trade passed normally. Live on Robinhood Chain; testnet dApp available for hands-on testing.

## Links
- Contract (Robinhood Chain): `0x51871F67273A56CDbdd8D9a936a98D3032Cb60C8`
- Explorer: https://robinhoodchain.blockscout.com/address/0x51871F67273A56CDbdd8D9a936a98D3032Cb60C8
- Testnet dApp: (artifact link)
- GitHub: https://github.com/n0krayy/FairOpenHook
- X: @SigmoidIMD

## Writing rules (house style)
- Full English, professional tone for all public copy.
- Never overgeneralize from the evidence: say "in the replayed SWARMLER #1212 attack" not "every launch"; "blocked the replayed attack" not "makes it impossible"; describe the tested control trade, not "fair trading is untouched".
- "Potential" for flywheel integration until wired onchain.
