# Attack Replay: BEFORE / AFTER FairOpenHook (mainnet fork)

**Demo utama hackathon.** Membuktikan: "bot nyedot 4.39% supply modal dust → hook bikin mustahil."

Label: **[FAKTA]** = dari data on-chain (~/workspace/imd-validation/LAPORAN.md).
**[REKREASI]** = dari eksekusi fork (angka di bawah ini, bukan karangan).

## Setup

- Fork: Ethereum mainnet @ blok **26158808** (blok launch SWARMLER #1212) [FAKTA], via `ethereum-rpc.publicnode.com`.
- PoolManager: **real** IMD PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` [FAKTA].
- Pair: **real** $IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` [FAKTA] + mock new token (18 desimal).
- Opening price: **2.5e-6 IMD/token** [FAKTA] → tick ±129000 (tickSpacing 60).
- Likuiditas: **900M token single-sided** jauh out-of-range [FAKTA: 90% supply] + **dust in-range** (~1e-8 IMD, mereplikasi "tick pembuka hampir tanpa likuiditas") [FAKTA].
- Attacker: EOA asli `0xd8ba9E5886B7000BACe2C9dbdd0BE98Ac77D4A28` (di-prank, di-deal IMD) [FAKTA].
- Serangan: **exact-input buy 118.88 IMD** (parameter swap-1 serangan asli) [FAKTA], di blok+1 [FAKTA].
- AFTER: pool **identik** + FairOpenHook (params default: baseFee 0.30%, feeK=50, maxFee 90%, breaker 25%/100 blok, cap 4.5M, cooldown 3).

Re-run: `forge test --match-contract AttackReplay -vv` (file: `test/AttackReplay.t.sol`).

## BEFORE — tanpa hook: serangan berhasil

| Metrik | Angka | Status |
|---|---|---|
| Input serangan | 118.88 IMD | [FAKTA] |
| Token yang keluar | 2,129.36 token | [REKREASI] |
| **Price swing** | **22,059x** (harga token dalam IMD naik) | [REKREASI] |
| Fee dibayar attacker | 1.486 IMD (1.25%) | [REKREASI] |
| Status | **SUKSES** — dust mengayun harga puluhan ribu-x | [REKREASI] |

Konteks [FAKTA]: di serangan asli, manipulasi ini 121M-x, dan langkah flash kedua mengekstrak **43.9M token (4.39% supply)** dengan net cost ~0. Replay ini membuktikan **enabler**-nya (langkah 1): tick pembuka yang near-zero bisa dimanipulasi dust. (Langkah 2 — flash-borrow — tidak direplikasi; 4.39% adalah fakta serangan asli.)

## AFTER — dengan FairOpenHook: serangan revert

| Metrik | Angka | Status |
|---|---|---|
| Input serangan | 118.88 IMD (sama persis) | [REKREASI] |
| Status | **REVERT — `BreakerTripped()`** | [REKREASI] |
| Alasan | price swing >> 25% dalam window → circuit breaker kill | [REKREASI] |

Serangan yang sama, di pool yang identik, mati di breaker. Tidak ada token keluar, tidak ada manipulasi.

## Kontrol positif — trading normal tidak mati

Pool hooked dengan likuiditas sehat (10M token + ~25 IMD):

| Swap | Hasil | Fee (surcharge) |
|---|---|---|
| 0.01 IMD buy | **sukses**, dapat 3,988.49 token (= harga wajar − 0.3%) | 0 pips (+ 0.30% baseFee ke LP) |

Hook tidak mematikan price discovery normal. Fee kecil untuk trade kecil.

## Fee curve (feeK=50) — data untuk tuning

Di pool sehat, surcharge terukur (di atas baseFee 0.30%):

| Input | Surcharge | Total fee |
|---|---|---|
| 0.1 IMD | 50 pips | 0.305% |
| 0.5 IMD | 300 pips | 0.330% |
| 1.0 IMD | 600 pips | 0.360% |
| 2.0 IMD | 1200 pips | 0.420% |

Fee naik linear dengan ukuran — sesuai desain. Trade kecil praktis cuma bayar baseFee.

## Rekomendasi tuning feeK: 50 → **150**

**Alasan (berbasis angka):** fee harus membuat manipulasi sub-breaker *economically irrational*.
Untuk manipulasi ber-impak I (bps), fee (pips) = 3000 + feeK·I. Agar fee (sebagai fraksi) melampaui
maksimum gain (yang dibatasi besarnya price move itu sendiri):

> (3000 + feeK·I)/1e6 > I/1e4  →  feeK > 100 − 3000/I

- Di batas breaker (I=2500, 25%): butuh **feeK > 98.8**.
- feeK=50 (sekarang): manipulasi 25% cuma bayar **12.8%** fee < 25% potensi gain → **masih bisa profit**. Fee saat ini *speed bump*, bukan deterrent.
- feeK=150: 10% impact → 1.8% fee (wajar untuk legit); 25% impact → **37.8%** fee (bunuh diri ekonomis); cap 90% tercapai di 60% impact (backstop di atas breaker).

Trade kecil tidak terdampak (surcharge ≈ 0 di impak rendah, terbukti di kontrol positif).
**Aksi:** ubah `feeK: 50` → `150` di `src/FairOpenHook.sol` (params), `script/Deploy.s.sol`, dan `test/FairOpenHook.t.sol` (`_defaultParams`).

## Batasan jujur

1. Replay mencakup **langkah 1** serangan (manipulasi dust). Langkah 2 (flash extraction 4.39%) tidak direplikasi — itu fakta serangan asli, bukan hasil fork ini.
2. Swing 22,059x vs 121M-x asli: beda penempatan 900M & dust vs pool asli. Fenomena identik (dust → ayunan astronomis), orde beda.
3. "Token terekstrak" 2,129 adalah output langsung swap-1, bukan 4.39% (yang butuh langkah flash).
4. Pool adalah rekreasi setia, bukan pool SWARMLER asli (itu pakai SWARMLERHook).
