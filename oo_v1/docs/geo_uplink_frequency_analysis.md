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

## 5. The THREE grades and TWO topologies (what actually varies)

The battery's grade label maps to `run_oo_v1_battery` flags — **`Realism` (`cfg.realism.grade`)**
and **`Atmosphere`**. All grades start from `masterConfig`, whose default is
`cfg.atmosphere.realistic = true`. The atmosphere is a *separate* toggle from the realism grade:
`realismGradeConfig` never touches the troposphere or ionosphere.

| grade | realism overlay | atmosphere | what it is |
|---|---|---|---|
| **idealised** | OFF | realistic (iono ∝1/f² present) | optimistic clock/systematics twin |
| **realism** | ON (`realismGradeConfig`) | realistic (same as idealised) | physically representative |
| **matchedatmo** | OFF | **OFF** (`atmosphere.realistic=false`) | idealised **minus the atmosphere** → isolates carrier wavelength |

The realism overlay (idealised→realism) changes ONLY: receiver clock `legacy`→`jowTable2p1`,
tower-clock product σ 0.010→0.100 m, hardware delay/DCB/C-N0 off→(0.5 m / 0.30 m / on), luni-solar
+SRP force gap / EOP / solid-Earth tide off→on, honest floors + inter-antenna carrier bias off→on.
It does **not** change the troposphere/ionosphere. So **the ionosphere ∝1/f² effect is present in
BOTH idealised and realism** (that is why C-band already gets the best *idealised* clock — smaller
iono, not removed iono).

**matchedatmo** sets `cfg.atmosphere.realistic=false`, which makes `applyAtmosphereProfile` a no-op
so tropo/iono `enable=0`. **Subtlety that bit us:** scintillation is gated *only* on
`errors.ionosphere.scintillation.enable` (default TRUE) — not on `ionosphere.enable` — and is
injected **frequency-scaled** (`∝(f_L1/f)`) into the truth, so it survives `realistic=false` and
would confound the sweep. The matched grade therefore *also* disables scintillation (+ its phase
jitter), the higher-order iono, and the stochastic tropo/iono draws, giving a genuine zero-
atmospheric-error baseline (verified from the finalized config: iono/tropo/scint/higher-order all
`enable=0`). Contrast **idealised − matchedatmo** = the ionosphere's contribution; **matchedatmo
across the pairs** = the pure carrier-wavelength effect.

**Two topologies** (Towers=5, one-way TW0): **G5S1R4** (ground-only) and **G5S6R4** (5-secondary
ISL swarm aiding the primary). The frequency override is provably independent of the ISL path (ECEF
geometry + metre/m·s⁻¹ sigmas; the ISL carrier row is diagnostic only). Caveat: at S6R4 only the
**realism** grade carries an honest ISL product σ (0.10/0.10 m); idealised/matchedatmo keep the
tighter 0.03/0.02 m, so their radial ±3σ coverage at S6R4 reads optimistic — expected, documented.

Full matrix = **3 grades × 5 pairs × 2 topologies = 30 runs**, homed under
`output/FrequencyTests/{G5S1R4,G5S6R4}/Battery_{idealised,realism,matchedatmo}_<L1>#<L2>/`.

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

## 7. Results (3 grades × 5 pairs × 2 topologies, one-way TW0, 3600 s, converged RMS)

Run 2026-07-15 via `run_oo_v1_freqbattery` (30/30 ok). Folder tags round the carriers to 2 dp GHz
(exact Hz in the manifests). Deliverables under `output/FrequencyTests/{G5S1R4,G5S6R4}/`: per-run
clockExact PDFs, plus `analysis/`, `../analysis_all/` (comparison_report.md/pdf, .csv, PNGs).

### 7.1 Ground-only (G5S1R4) — the radial is degeneracy-limited, not frequency-limited

| Pair (GHz) | idealised 3D / rad / clk | realism 3D / rad / clk | matchedatmo 3D / rad / clk |
|---|---|---|---|
| 1.58/1.23 L | 6.12 m / 2.62 m / 9.48 ns | 11.7 m / 6.86 m / 20.6 ns | 24.7 m / 24.7 m / 82.0 ns |
| 2.11/2.02 S | 4.99 m / 2.48 m / 8.52 ns | 14.5 m / 10.4 m / 34.0 ns | 2.04 m / 2.04 m / 6.78 ns |
| 6.42/5.92 C | 4.65 m / 2.10 m / 7.01 ns | 10.6 m / 6.90 m / 22.0 ns | **0.80 m / 0.79 m / 2.62 ns** |
| 5.00/2.10 C+S | 7.22 m / 3.62 m / 11.5 ns | 11.2 m / **4.66 m** / **15.6 ns** | 9.85 m / 9.84 m / 32.6 ns |
| 8.40/7.90 X | 5.27 m / 3.40 m / 11.2 ns | 11.0 m / 7.05 m / 22.8 ns | 2.95 m / 2.95 m / 9.79 ns |

corr(radial,clock) = **−1.00 for all 15**. Key read: matchedatmo (iono OFF) sharpens the
**horizontal** dramatically (along/cross fall to 4–90 cm, vs metres for idealised) but the
**radial** stays trapped in the unobservable radial↔clock mode and swings wildly and
non-monotonically with the pair (0.79 m at C-band to 24.7 m at L-band). So on a one-way ground-only
link the radial is set by the observability wall, not by the ionosphere — frequency choice cannot
fix it. In the realism grade the C+S split is still the best *realistic* ground-only design (radial
4.66 m, clock 15.6 ns) and the narrow S-band is worst (34 ns), as in the original 10-run sweep.

### 7.2 ISL swarm (G5S6R4) — the swarm unlocks radial, and THEN frequency is a clean lever

With 5 co-observed secondaries aiding the primary, the radial becomes observable and the
optimistic-clock grades reach **mm–cm**:

| Pair (GHz) | idealised 3D / rad / clk | matchedatmo 3D / rad / clk | realism 3D / rad / clk |
|---|---|---|---|
| 1.58/1.23 L | 345 mm / 313 mm / 31 ps | 58 mm / 19 mm / 38 ps | 2.34 m / 2.03 m / 293 ps |
| 2.11/2.02 S | 223 mm / 190 mm / 41 ps | 45 mm / 17 mm / 40 ps | 3.18 m / 2.79 m / 693 ps |
| 6.42/5.92 C | 118 mm / 95 mm / 25 ps | **29 mm / 16 mm / 25 ps** | 2.85 m / 2.49 m / 433 ps |
| 5.00/2.10 C+S | 406 mm / 356 mm / 37 ps | 72 mm / 23 mm / 53 ps | 3.88 m / 3.43 m / 701 ps |
| 8.40/7.90 X | 159 mm / 132 mm / 26 ps | 32 mm / 17 mm / 29 ps | 3.15 m / 2.76 m / 568 ps |

- **matchedatmo isolates the ionosphere cleanly.** With iono OFF the swarm solution is mm-flat
  across bands (29–72 mm 3D), so position is set by geometry/wavelength, not frequency — exactly the
  isolation the grade was built for. The **idealised − matchedatmo gap IS the ionosphere cost**, and
  it scales as 1/f²: ~287 mm at L, ~178 mm at S, ~89 mm at C, ~127 mm at X. C-band is the sweet spot
  (idealised 118 mm, matchedatmo 29 mm).
- **realism at S6R4 is honestly poor AND over-confident** — 2.3–3.9 m 3D, clock 0.3–0.7 ns, NEES(pos)
  200–400, radial 3σ coverage **0 %**, pos σ 25–35× too small. The swarm aiding does NOT rescue the
  honest-systematics case, and (as flagged in §5) the covariance is badly optimistic because the
  represented-secondary product σ is still tighter than the real systematics. This is the most
  important honesty caveat of the whole study: **the mm-cm swarm numbers are an idealised-error
  artefact; the physically-representative swarm error is metre-level with unreliable covariance.**

### 7.3 Headline findings (all 30 runs)

1. **The limiting factor is observability, not frequency.** One-way ground-only radial is degeneracy-
   locked (corr = −1) for every band; only the ISL swarm makes radial observable. Frequency is a
   second-order lever that only matters once the geometry is fixed.
2. **Once radial is observable, lower ionosphere wins** — higher band (C/X) and the wide C+S split
   reduce the iono residual; the iono cost falls ∝1/f² (quantified above via idealised−matchedatmo).
3. **The narrow S-band pair is the pathological uplink** (worst realism ground-only clock, 34 ns): iono
   present, no separation to remove it. A single narrow band cannot do dual-frequency correction.
4. **Attitude is L-band-tuned across every grade/topology**: L/S-band ≈ 6–8 arcmin (~0.12°) but
   C/X/split ≈ 1.7–3° — the differential-carrier AR gates (5-cycle search, ±1 m arms) do not scale to
   the shorter C/X wavelengths. A band-matched AR retune is needed, not a physics limit.
5. **Covariance realism is the real gap at S6R4**: the honest (realism) grade is metre-level and
   over-confident there, so a swarm design must budget for represented-secondary product realism, not
   just add links.

**Design implication.** A credible reverse-GNSS GEO system pairs an RNSS/FSS **C-band (~5–6 GHz)**
primary with a widely-separated **S-band (~2 GHz)** tone (low absolute iono + genuine dual-frequency
observability) **and** a co-observed swarm to break the radial↔clock wall — then budgets honestly for
the swarm product covariance and retunes the attitude AR to the chosen band.

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
