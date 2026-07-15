# GEO reverse-GNSS uplink frequency analysis

**Purpose.** Decide which carrier frequencies to use for the two ranging signals
(labelled `L1` and `L2` in the code) in a *ground-to-GEO* reverse-GNSS system, and
select a defensible set of `(L1, L2)` pairs to sweep in the G5S1R4 battery.

**Why this is not a cosmetic relabel.** The simulation is a *reverse* GNSS: the ground
towers transmit and the GEO spacecraft receives and self-navigates. That is the
**Earth-to-space (uplink)** direction. The GPS/Galileo L1/L2/L5 bands the code currently
hardcodes (1575.42 / 1227.60 / 1176.45 MHz) are **Radionavigation-Satellite Service (RNSS)
*space-to-Earth* (downlink)** allocations. They are the *right* numbers for a GNSS
*receiver on the ground*, but they are **not, in general, available for a ground station to
transmit up to a satellite**. So the default 1.575 / 1.228 GHz pair is best read as an
idealised reference, not an operationally realisable uplink.

---

## 1. What the physics cares about

Three frequency-dependent effects dominate this GEO scenario:

1. **Ionospheric group delay** `I(f) = 40.3 · STEC / f²` (metres, STEC in el/m²).
   It is the single largest *dispersive* uplink error. A full ground→GEO ray pierces the
   whole ionosphere. At L1 the zenith delay is ~a few m and up to ~15–40 m at low
   elevation in active conditions; it scales as **1/f²**, so it collapses at higher bands.
   *Relative to L1:* S-band (~2.1 GHz) ≈ 56 %, C-band (~6 GHz) ≈ 7 %, X-band (~8 GHz) ≈ 4 %,
   Ka (~30 GHz) ≈ 0.3 %.

2. **Dual-frequency (ionosphere-free) conditioning.** Two frequencies let you remove the
   first-order iono, but the iono-free combination amplifies white noise by
   `√(a²+b²)`, with `a = f1²/(f1²−f2²)`, `b = f2²/(f1²−f2²)`. This blows up when the two
   frequencies are **close** (same band) and is well-conditioned only when they are **widely
   separated**. (In the default RAW dual-frequency mode the EKF keeps L1/L2 uncombined and
   this factor is diagnostic; it still tells you whether a band *could* go iono-free.)

3. **Carrier wavelength** `λ = c/f`. Shorter λ at higher bands gives finer carrier-phase /
   attitude resolution per cycle but more cycles to resolve. λ: L1 19.0 cm → C-band ~5 cm →
   X-band ~3.7 cm → Ka ~1 cm.

Higher frequency ⇒ far less ionosphere and finer phase, at the cost of more troposphere/rain
sensitivity, tighter pointing, and more expensive hardware. That trade is the whole study.

## 2. Frequency-amplification / iono table (computed)

| Pair (L1 / L2, GHz) | Band(s) | f2/f1 | iono-free noise amp `√(a²+b²)` | iono vs L1 (L2 signal) |
|---|---|---|---|---|
| 1.575 / 1.228 | L / L (GPS ref) | 0.779 | **2.98** | 165 % |
| 2.110 / 2.025 | S / S | 0.960 | **17.2** | 60 % |
| 6.425 / 5.925 | C / C | 0.922 | **8.8** | 7 % |
| 5.000 / 2.100 | C / S (split) | 0.420 | **1.23** | 56 % |
| 8.400 / 7.900 | X / X | 0.940 | **11.6** | 4 % |

Reading: same-band pairs (S/S, C/C, X/X) are realistic to license inside one uplink
allocation but are **badly conditioned** for iono-free (8–17× noise) — they rely on the band
being high enough that the *raw* residual iono is already small. The **split C/S pair** is the
only well-conditioned dual-frequency design (1.23×), the direct analogue of the VLBI S/X
ionosphere-calibration technique.

## 3. Earth-to-space bands that actually exist (ITU)

- **RNSS Earth-to-space, 5000–5010 MHz (C-band).** The *only* navigation-specific uplink
  allocation. Introduced by Resolution 603 (WRC-2000); this is exactly the band Galileo uses
  for its feeder-link (mission uplink to the satellites). ⇒ a real ground→space *navigation*
  carrier lives at ~5 GHz.
- **Space-operation / EESS / SRS Earth-to-space (S-band), ~2025–2110 MHz.** The classic TT&C
  command uplink band (~85 MHz wide — too narrow for a well-separated pair on its own).
- **FSS C-band uplink, 5925–6425 MHz.** 500 MHz of well-established satellite uplink.
- **Government/military X-band uplink, 7900–8400 MHz.** Low iono, but access-restricted.
- **FSS Ku-band uplink, 14.0–14.5 GHz** and **Ka-band uplink, 27.5–31 GHz.** Iono negligible;
  rain/tropo and pointing dominate (rain fade is *not* modelled here, so Ka would look
  optimistically good — noted as a caveat rather than a recommended run).

**Implication.** A credible reverse-GNSS uplink is C-band-centred (RNSS 5 GHz / FSS 6 GHz),
optionally paired with an S-band tone for a widely-separated, well-conditioned dual-frequency
iono solution. Pure L-band (the GPS default) is the idealised *reference*, not a realisable
uplink.

## 4. Recommended sweep set

Each pair keeps the code's `L1 > L2` convention (L1 = higher/primary, L2 = lower). All are run
at **G5S1R4**, for both the **idealised** and **realism** grade.

| # | Name | L1 (GHz) | L2 (GHz) | Rationale |
|---|---|---|---|---|
| 1 | **L-band (GPS reference)** | 1.57542 | 1.22760 | Anchor = current default; not uplink-legal but the baseline everything is compared to. |
| 2 | **S-band uplink** | 2.110 | 2.025 | Realistic TT&C-style narrow uplink; shows the narrow-band iono-free penalty. |
| 3 | **C-band uplink** | 6.425 | 5.925 | Realistic wide FSS/RNSS uplink; iono ~7 % of L-band. |
| 4 | **C/S split-band** | 5.000 | 2.100 | RNSS-5 GHz primary + S-band tone; best-conditioned dual-frequency (amp 1.23). |
| 5 | **X-band uplink** | 8.400 | 7.900 | Very low iono, government band; upper anchor. |

Folder tag per the request: `<L1>#<L2>` in GHz to 2 decimals, e.g. `1.58#1.23`, `2.11#2.03`,
`6.43#5.93`, `5.00#2.10`, `8.40#7.90`, appended to `Battery_idealised_` / `Battery_realism_`.

## 5. What the two grades are (IMPORTANT — they do NOT differ in atmosphere)

The battery's `idealised` vs `realism` label maps to `run_oo_v1_battery`'s `Realism` flag, i.e.
to **`cfg.realism.grade` OFF vs ON** — nothing more. Both grades start from `masterConfig`, whose
default is **`cfg.atmosphere.realistic = true`**, so **both grades run the SAME realistic
atmosphere** (Saastamoinen/Niell troposphere + diurnal/Klobuchar ionosphere, non-cancelling
truth−model residuals). `realismGradeConfig` never touches the troposphere or ionosphere; the
atmosphere is a *separate* toggle (`cfg.atmosphere.realistic`). Empirically confirmed from the run
configs: both arms have `atmosphere.realistic=1`, `troposphere.enable=1`, `ionosphere.enable=1`,
`codeMode=singleFrequency`.

So the grades differ ONLY in the realism-grade overlay:

| effect | idealised (grade OFF) | realism (grade ON) |
|---|---|---|
| receiver clock template | `legacy` (quiet idealised maser) | `jowTable2p1` (real caesium) |
| tower-clock product σ | 0.010 m (~33 ps) | 0.100 m (~0.33 ns) |
| hardware delay / DCB / C/N0 | off / 0 / off | 0.5 m / 0.30 m / on |
| luni-solar+SRP force gap, EOP, tide | off | on |
| honest measurement floors, inter-antenna carrier bias | off | on |
| **troposphere + ionosphere** | **realistic (same)** | **realistic (same)** |

Consequences for the sweep:

- The **ionosphere ∝ 1/f² frequency effect is present in BOTH grades** (both realistic). Frequency
  therefore moves the clock/radial in the idealised grade too — e.g. C-band gets the best idealised
  clock because its iono is smaller, not because iono was removed.
- The **realism grade is uniformly worse** because it piles the honest clock, looser tower product,
  and the systematics/force terms *on top of* the same atmosphere. It is the physically
  representative curve; idealised is the optimistic-clock/systematics twin.
- **To isolate carrier wavelength alone** (ionosphere genuinely cancelling) you would need a THIRD
  arm with `cfg.atmosphere.realistic = false` (matched synthetic atmosphere, truth==model). That
  was NOT run here — say so and I can add it.
- **Not modelled** (caveats for the write-up): rain fade / gaseous absorption at Ku/Ka, band-
  dependent antenna gain and hardware group delay, and licensing/regulatory feasibility beyond
  the allocation existing.

## 6. Implementation note (how frequency is made to actually change)

Frequency was **not** config-driven: `revgnss.SignalDefinition` hardcodes the three L-band
values and `ConfigFactory.finalizeConfig` re-derives every downstream frequency from it *by
signal name*, overwriting any `cfg.signals.*.frequency_Hz` a caller sets. The sweep therefore
overrides the canonical source itself:

- `revgnss.SignalDefinition` gains a **golden-safe frequency override** (persistent, default
  empty ⇒ byte-identical to today; set per pair, cleared in a `finally`). Because
  `finalizeConfig` and the physics fall-backs all funnel through `SignalDefinition.get`, one
  override propagates consistently to the iono scaling, carrier wavelength, and IF diagnostics.
- `config/realisticAtmosphereConfig.m` line 70 (the only literal `1575.42e6` on the active
  physics path, the ionosphere K_L1 constant) is changed to derive K_L1 from the actual L1
  frequency, so the modelled iono shrinks with band exactly as the truth does. Byte-identical
  when no override is set.

No EKF, covariance, or truth/estimate-boundary code is touched; the frozen goldens remain
byte-identical because the override defaults off.

---

## 7. Results (G5S1R4, one-way TW0, 3600 s, converged-window RMS)

Run 2026-07-15 via `run_oo_v1_freqbattery`. All 10 runs converged (10/10 ok). Folder tags
round the carriers to 2 dp GHz: S-band L2 2.025→`2.02`, C-band 6.425/5.925→`6.42/5.92`
(deterministic %.2f; exact Hz preserved in the manifest and run labels).

**Idealised grade** — realism-grade overlay OFF (optimistic clock/systematics) but the SAME
realistic atmosphere as the realism grade (see §5): the ionosphere is present, just paired with a
quiet legacy clock and tight floors, so it maps mostly into the clock/radial mode:

| Pair (GHz) | 3D pos | radial | clock RMS | attitude |
|---|---:|---:|---:|---:|
| 1.58 / 1.23  L-band | 6.12 m | 2.62 m | 9.48 ns | **0.13°** |
| 2.11 / 2.02  S-band | 4.99 m | 2.48 m | 8.52 ns | **0.12°** |
| 6.42 / 5.92  C-band | **4.65 m** | **2.10 m** | **7.01 ns** | 2.93° |
| 5.00 / 2.10  C/S split | 7.22 m | 3.62 m | 11.51 ns | 1.74° |
| 8.40 / 7.90  X-band | 5.27 m | 3.40 m | 11.24 ns | 2.61° |

Position spread is modest (4.6–7.2 m); C-band gets the best idealised clock/radial (7.01 ns /
2.10 m) — consistent with its smaller (not removed) ionosphere. The striking effect is
**attitude**: L/S-band ≈ 0.12–0.13° but C/X/split
≈ 1.7–2.9° — ~20× worse. Cause: attitude is differential-carrier and the ambiguity-resolution
gates (5-cycle integer search half-width, ±1 m lever arms) are L-band-tuned; at C/X wavelengths
(~5 / ~3.7 cm) a 1 m arm spans 4–5× more cycles, so the AR degrades. **The attitude AR would need
retuning per band** — a real finding, not a physics limit.

**Realism grade** — physically-sized truth−model residuals; the ionosphere (∝1/f²) is a genuine
error, and higher bands / wider separation should help:

| Pair (GHz) | 3D pos | radial | clock RMS | consistency |
|---|---:|---:|---:|---|
| 1.58 / 1.23  L-band | 11.72 m | 6.86 m | 20.55 ns | consistent |
| 2.11 / 2.02  S-band | 14.46 m | 10.43 m | **33.96 ns (worst)** | pos σ 2.2× / clk σ 1.6× small; rad 3σ 92% |
| 6.42 / 5.92  C-band | 10.64 m | 6.90 m | 22.04 ns | pos σ 1.5× small |
| 5.00 / 2.10  C/S split | 11.24 m | **4.66 m (best)** | **15.57 ns (best)** | NIS optimistic |
| 8.40 / 7.90  X-band | 10.98 m | 7.05 m | 22.79 ns | pos σ 1.6× small |

**Headline findings**

1. **Wide frequency SEPARATION wins, not raw band height.** The C/S split (5.00/2.10 GHz) gives
   the best clock (15.6 ns) and radial (4.66 m) because the 2.4× frequency ratio actually resolves
   the ionosphere. This is the best-conditioned dual-frequency pair (iono-free noise amp 1.23) and
   the direct analogue of the VLBI S/X technique.
2. **The narrow S-band pair is pathological.** 2.110/2.025 GHz (ratio 1.04) is worst on clock
   (34 ns) and radial (10.4 m) and the only covariance-optimistic run (radial 3σ coverage 92 %):
   significant iono AND no separation to remove it. A single narrow uplink band cannot do
   dual-frequency iono correction — exactly the §2 warning, now quantified.
3. **Same-band C and X help modestly via low raw iono** (~7 % / ~4 % of L-band) — radial ~6.9–7.0 m
   — but their near-degenerate pairing gives no iono leverage, so they do not beat the split pair.
4. **Frequency does NOT cure the observability wall.** corr(radial,clock) = −1.000 for *every*
   pair: the one-way ground→GEO radial↔clock degeneracy is geometric, not dispersive. Frequency
   only modulates the error *within* that mode; breaking it still needs two-way TWSTFT or a
   co-observed swarm (see the honest-covariance / two-way work).

**Design implication.** For a realistic reverse-GNSS GEO uplink, pair the RNSS/FSS C-band
(~5–6 GHz) primary with a widely-separated S-band (~2 GHz) tone. That buys both low absolute iono
on the primary *and* genuine dual-frequency iono observability — better than any same-band pair,
and far better than a narrow S-band-only design. Attitude then wants a band-matched AR retune.

Deliverables: `output/Report_20260715/Battery_{idealised,realism}_<L1>#<L2>/…/*.pdf` (per run) and
`output/Report_20260715/Battery_freqsweep/analysis/` (comparison_report.md/pdf, comparison_metrics.csv,
comparison_overview.png, radial_clock_timeseries.png).

---

### Sources
- RNSS 5000–5010 MHz Earth-to-space / Galileo feeder uplink; ITU Res. 603 (WRC-2000):
  Inside GNSS, "RNSS and the ITU Radio Regulations" — https://insidegnss.com/rnss-and-the-itu-radio-regulations/
- S/C/X/Ku/Ka Earth-to-space uplink allocations: ESA, "Satellite frequency bands" —
  https://www.esa.int/Applications/Connectivity_and_Secure_Communications/Satellite_frequency_bands
- Ionospheric group delay ∝ 1/f² and GEO L-band magnitude (~15 m zenith, ~40 m low-elevation):
  Penn State GEOG 862, "The Ionospheric Effect" — https://courses.ems.psu.edu/geog862/node/1715
- Dual-band (S/X) ionosphere calibration analogue: NASA NTRS 20230003984, "Ionospheric path
  delay impacts single-band (VLBI)" — https://ntrs.nasa.gov/api/citations/20230003984
