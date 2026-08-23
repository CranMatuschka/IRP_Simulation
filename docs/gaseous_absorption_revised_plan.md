# Revised Part B: gaseous absorption from a frozen ITU-R P.676 table

Date: 2026-08-11
Branch: `feature/ground-orientation-exec`
Supersedes: Part B of `docs/iono_anchor_fix_and_atmospheric_absorption_plan.md`
Part A of that document is unaffected.

**No toolbox is used anywhere -- not at run time, and not in the generator.**

---

## B0. Why Part B is revised

The original WP1 was a hand implementation of ITU-R P.676 **Annex 1**, estimated at 1.5 to 3
sessions and the single largest piece of work in the plan.

That estimate was for Annex 1 as a **runtime model**, with config wiring, guards and tests.
The freq ladder visits exactly **nine** frequencies, so what is actually needed is a
**generator** that runs once and produces nine numbers. As a generator, Annex 1 is:

- the two line tables (44 oxygen rows, 35 water vapour rows) -- data transcription
- equations (1) to (9) -- about 25 lines
- the P.676 section 2.2 layered vertical integration -- about 20 lines

It runs in **0.2 seconds** and needs no toolbox. The whole thing is `p676_annex1.m` plus
`generate_gas_absorption_table.m`.

### An interim route was considered and rejected

Annex 2's closed-form approximation was drafted first (`p676_annex2.m`, retained as a
cross-check) on the grounds that it was cheaper and equally citable. It is neither, once the
table is frozen and the runtime no longer cares how the numbers were produced:

**Annex 2 cannot be validated tightly.** Comparing it against Annex 1 gives -4 to -11%, and
that gap is dominated by the approximation itself, so a transcription error in its coefficients
would hide inside it. Annex 1 can be checked against an independent implementation of the same
equations, and either matches exactly or does not. It matched exactly (B1).

### Why a frozen table rather than calling Annex 1 at run time

The generator is fast enough to call live, so a runtime path would also work. The table is
still the better fit: it is reviewable, diffable and bit-stable, it cannot silently change
under a refactor, and it is three lines instead of 160 lines of physics needing their own
tests. Regenerating for a new rung is a one-line edit to the frequency list.

---

## B1. The frozen table

ITU-R P.676-13 Annex 1, line-by-line. P.835 mean annual global reference atmosphere,
7.5 g/m^3 surface water vapour, integrated in 100 m layers to 80 km. `ZWD_ref = 0.095669 m`.

| Band | A_dry [dB] | A_wet [dB] | total [dB] | sigma factor at zenith |
|---|---|---|---|---|
| 915 ISM (*) | 0.030157 | 0.000072 | 0.030229 | 1.003 |
| 1176.45 L5 | 0.032175 | 0.000119 | 0.032293 | 1.004 |
| 1227.60 L2 | 0.032454 | 0.000129 | 0.032583 | 1.004 |
| 1575.42 L1 | 0.033786 | 0.000213 | 0.033999 | 1.004 |
| 2450 ISM | 0.035241 | 0.000517 | 0.035759 | 1.004 |
| 5200 U-NII | 0.037009 | 0.002396 | 0.039405 | 1.005 |
| 5800 ISM | 0.037373 | 0.003009 | 0.040381 | 1.005 |
| 24125 ISM | 0.073387 | 0.317082 | 0.390468 | 1.046 |
| 61250 ISM | 161.194782 | 0.272657 | **161.467439** | 1.18e8 |

(*) 915 MHz is below P.676's stated 1 GHz validity floor. See B5.

### Validation: the dry path is BIT-IDENTICAL to an independent implementation

Checked against MathWorks `gaspl`, confirmed to be an independent transcription of the same
Annex 1 (it carries the full 44-line and 35-line tables with equations (3), (5), (6a), (6b),
(7)). **The toolbox appears only in this comparison and is required by nothing.**

**A. Dry path, `e = 0` on both sides.** Same tables, same equations, so exact agreement is the
expected result and any transcription error would show immediately:

| f [GHz] | this implementation | independent | relative error |
|---|---|---|---|
| 1.000 | 5.2844301148e-03 | 5.2844301148e-03 | **0.00e+00** |
| 1.575 | 6.2317800391e-03 | 6.2317800391e-03 | **0.00e+00** |
| 2.450 | 6.7317667067e-03 | 6.7317667067e-03 | **0.00e+00** |
| 5.800 | 7.2931374087e-03 | 7.2931374087e-03 | **0.00e+00** |
| 24.125 | 1.4303650381e-02 | 1.4303650381e-02 | **0.00e+00** |
| 61.250 | 1.4815197102e+01 | 1.4815197102e+01 | **0.00e+00** |

Equations (1) to (9) and Table 1 are transcribed correctly. This is proof, not consistency.

**B. Total at `rho = 7.5`**, which differs by -0.12% to -3.52%. That is **not** an error: the
water vapour table was **revised between P.676-10 and P.676-13** (the 22.235 GHz line's `b1`
0.1130 -> 0.1079, `b3` 28.11 -> 26.38, and the 1780 GHz line by 21%). The oxygen table is
byte-identical across the two versions and the two independent sources. The gap is largest at
24.125 GHz (-3.1%), which is exactly where water vapour is 81% of the total.

> A trap worth recording: comparing "dry" attenuation by calling the reference with
> `rho = 0` while calling this one with `rho = 7.5` is **wrong**, and initially showed a
> spurious 1% disagreement. Water vapour partial pressure `e` broadens the oxygen lines
> through equations (6a) and (7) and enters the continuum through (9), so dry attenuation in a
> moist atmosphere is a different quantity from dry attenuation in a dry one.

### Three conclusions available NOW, before any implementation

1. **Below 6 GHz absorption is under 0.5% on code sigma at zenith.** `freq009`, `freq010` and
   `freq011` are untouched by this entire work package.
2. **At 24.125 GHz it is 4.6% on sigma, and 81% of it is water vapour.** The only band in the
   ladder that is genuinely humidity-sensitive, and the only one where a number moves.
3. **At 61.25 GHz the link is dead.** C/N0 goes from 51 dB-Hz to **minus 110 dB-Hz**, i.e.
   ~135 dB short of a 25 dB-Hz threshold. Not a threshold-choice question, and no simulation
   is required to establish it.

> **The cheapest defensible outcome is to stop here.** This table plus B7's ch8 wording
> supports every claim the original Part B set out to support. Implementing the rest converts
> "asserted with a sourced table" into "demonstrated in the simulation", which is worth
> roughly two sessions. A real gain for the chapter, but discretionary rather than a gap.

---

## B2. Design: two columns, and the mapping the repo already has

The original WP1 argued for a live line-by-line model specifically so absorption would share
ONE weather realisation with the troposphere rather than introducing a second independent
atmosphere. **The frozen table keeps that property**, because the dry and wet columns are
stored separately:

```
A(f, el, tower) = A_dry(f)*m_h(el) + A_wet(f)*m_w(el)*(ZWD_tower / ZWD_ref)
```

Structurally identical to the troposphere's own `ZHD*m_h + ZWD*m_w` at
`EnvironmentModel.m:443`, so it reuses `tropMapping_` -- already tested, already carrying the
per-side Niell/simple selector -- instead of inventing a second obliquity law. The per-tower
weather coupling enters through the ZWD ratio on the wet column, which is where it physically
belongs and where it actually matters (24 GHz).

Splitting the columns is not bookkeeping. Oxygen and water vapour have genuinely different
scale heights, so a single total mapped one way would be wrong at low elevation.

**The elevation term matters more than the original B1 claimed.** B1 quoted 0.4% on sigma at
L1 from the zenith figure. At the 10 deg mask the airmass is ~5.6, so it is nearer 2.2%.
Gating is mandatory by a wider margin than argued.

---

## B3. Work packages

| WP | Scope | Estimate | Status |
|---|---|---|---|
| WP0 | `p676_annex1.m`, generator, cross-check script | ~3 h | **DONE** |
| WP1 | `models.atmosphere.GaseousAbsorption` reading the frozen table | ~2 h | **DONE** |
| WP2 | Shared C/N0 helper, then subtract A_gas | ~3 h | **DONE** |
| WP3 | S4 frequency law | ~1 h | **DONE** (default 0, inert) |
| WP4 | Link closure as a RESOLVE-TIME refusal | ~2 h | **DONE** |
| WP5 | Gating and its three assertions | ~3 h | **DONE** |
| WP6 | Tests against the table and published values | ~3 h | **DONE** |

**Total: ~2 sessions plus ~20 to 70 min of re-runs.** The original was 4-6 sessions plus ~2 h.

### Delivered 2026-08-11

Files added: `analysis/p676_annex1.m`, `analysis/p676_annex2.m`,
`analysis/generate_gas_absorption_table.m`, `analysis/compare_p676_implementations.m`,
`+models/+atmosphere/GaseousAbsorption.m`, `tests/test_gaseous_absorption.m`,
`tests/test_gaseous_absorption_gate.m`, `tests/test_link_closure_and_s4_frequency.m`.

Files changed: `config/masterConfig.m` (gate, `minTrackable_dBHz`,
`s4FrequencyExponent`, `weatherLossScale_dB` DELETED),
`+models/+measurements/MeasurementModelUtils.m` (shared `cn0CodeSigma`),
`+models/+errors/ErrorChain.m` (routes to it), `+revgnss/ConfigFactory.m` (WP4 guard),
`+models/+errors/EnvironmentModel.m` (WP3 S4 anchor),
`config/ladder/freq/freq013_ism24125_61250.json` (`_linkClosure` note).

**Equivalence: PROVEN, not assumed.** Stage-85 smoke/single and smoke/realism both PASS
with 0 core and 0 non-core failures at `rtol = 1e-9`, after every change. The realism tier
is the one that matters, because `realismGradeConfig.m:51` sets `codeNoise.model = 'cn0'`
and the single tier does not -- a PASS on single alone would have proven nothing about the
C/N0 refactor. A concurrent session independently verified `full realism` and `full
headline` against the same edited tree, also 0/0.

**WP2 found a pre-existing drift.** The two C/N0 sites were NOT identical: `codeSignalSigma`
floors the elevation at `ELEVATION_FLOOR_RAD`, `ErrorChain.computeCodeSigmaVec_` does not.
PRESERVED rather than unified, because unifying moves results below 5 deg elevation.
Unreachable under the 10 deg mask, so latent rather than live. Documented at the helper.

**WP4 as built.** `ConfigFactory:linkDoesNotClose`, tested at ZENITH (best case), inert
unless absorption AND `cn0` are both on. `freq013` is RETAINED, not deleted: its
`_linkClosure` key now carries the computed 161.47 dB / -110.5 dB-Hz / 135.5 dB short
instead of the previous assertion that its margin was "fiction". Deleting it would have
discarded a documented negative result.

### WP0 -- generator and provenance

Plain-MATLAB files under `analysis/`, committed so the numbers are reproducible rather than
pasted:

- `p676_annex1.m` -- P.676-13 Annex 1, Tables 1 and 2 plus equations (1)-(9)
- `generate_gas_absorption_table.m` -- P.835 profile, layered integration, emits the table
- `p676_annex2.m` -- the Annex 2 approximation, retained as an independent cross-check only
- `compare_p676_implementations.m` -- the B1 validation, skipped when no toolbox is present

Working drafts of all of these exist in the session scratchpad and have been run. They
produced B1.

### WP1 -- the class

`models.atmosphere.GaseousAbsorption` holding the frozen table plus:

- `zenithDryWet(f_Hz)` returning `[A_dry, A_wet]`, **hard error off-table**
- `slantAttenuation_dB(f_Hz, elev_rad, ZWD_m, latRad, doy, heightKm)` composing via
  `tropMapping_`

### WP2 -- into C/N0

Two halves, and only the second needs WP1:

- **WP2a**: collapse `MeasurementModelUtils.m:174-189` and `ErrorChain.m:487-500` into one
  shared helper. They already differ in how they source sigma0 (per-signal `codeSigma0_m`
  versus `cn0.sigmaAt45dBHz_m`), so the helper takes sigma0 as an ARGUMENT rather than
  reading config. Must be bit-identical. Delete `weatherLossScale_dB`
  (`masterConfig.m:2132`, confirmed zero readers repo-wide).
- **WP2b**: subtract `A_gas` inside that one helper.

WP2a is independently shippable and worth doing whenever the file is next touched.

### WP4 -- refuse at resolve time, do not run a dead link

**Redesigned.** The original dropped rows below a C/N0 threshold and expected `freq013` to
"stop producing a solution at all", which meant the report builder, `arcNisRowBudgetCloses`
and every gate had to survive a zero-row run.

Do not do that. Part A's own Finding 5 already established the principle:

> Any gate must be computed at **resolve time from frequency geometry**. It cannot be
> detected from run diagnostics.

The same applies to link closure. The table says 61.25 GHz is 135 dB short before a single
epoch is simulated. **Refuse the configuration at resolve time with the number in the error
message, and drop `freq013` from the ladder.** The scientific claim is identical and it costs
one guard instead of pipeline surgery.

Keep `cn0.minTrackable_dBHz` as the constant so the refusal is parameterised, but apply it at
resolve, not per row.

### WP5 -- gating

Unchanged from the original, and still the package most likely to be got wrong. Three
assertions, of which only the first is written by default:

1. OFF is bit-identical to the golden
2. ON changes a specific quantity at a known frequency
3. ON via `_extends` also changes it

The original plan's warning is confirmed by a fresh instance: `codeNoise.minElevation_rad`
at `masterConfig.m:2127` has **no reader anywhere in the repo**. That is a second inert toggle
in this exact subsystem, alongside `weatherLossScale_dB`.

---

## B4. Decisions

**1. Does realism grade include absorption? NO.** Unchanged, now better supported: at L1 it is
0.034 dB zenith. Re-cutting eight goldens for a 0.4% zenith / 2.2% at-mask sigma change buys
nothing and costs cross-ladder comparability.

**2. Does realism set the S4 exponent to 1.5? RECOMMEND NO, not yet.** The original called WP3
"nearly free, ~3 lines plus config", which holds only while the default is 0. S4 goes as
`f^-1.5`, and L2 is BELOW L1, so setting 1.5 raises S4 on the L2 row by

```
(1575.42 / 1227.60)^1.5 = 1.45
```

**45% more S4, not less.** With `S4zen = 0.3` live in the golden
(`golden_baseline.json:112`, annotated there as the largest truth-only term at 0.618 m rms)
and the `min(0.7)` clamp already firing ~33% of epochs, that drives L2 rows into the clamp
harder and pins them at 2.121 m. This is a realism golden re-cut through a mechanism the
original plan did not identify. **Measure the clamp rate before enabling it.**

**3. Toolbox anywhere? NO.** Settled. The runtime reads a frozen table, the generator is plain
MATLAB Annex 1, and the toolbox appears only in the optional cross-check script.

**4. Annex 1 or Annex 2? ANNEX 1.** Annex 1 is the reference method and Annex 2 is a fit to it.
Once a generator is written either way, Annex 1 costs about an hour more and buys exact
validation. Annex 2 stays in the tree as a second opinion.

---

## B5. Known limits, to state rather than fix

- **⚠ The line tables have NOT been read from the Recommendation directly.** The ITU PDF is a
  scanned image and text extraction failed. Table 1 and Table 2 were transcribed from the
  ITU-Rpy v13 data files. **The oxygen table is byte-identical to the independent MathWorks
  P.676-10 transcription**, which is genuine two-source agreement, and the equations are proved
  correct by the exact match in B1. The **water vapour table has only ONE source** here,
  because it was revised after v10. **Verify Table 2 against the Recommendation before citing
  in the traceability register.** The downloaded P.676-12 PDF is in this session's
  tool-results directory.
- **915 MHz sits below P.676's stated 1-1000 GHz validity floor.** The implementation evaluates
  there and returns 0.030 dB, and the independent reference refuses the frequency outright.
  `freq009` must carry the caveat rather than imply a validated value. At 0.030 dB it changes
  nothing.
- **One reference atmosphere.** Per-tower variation enters only through the ZWD ratio on the
  wet column. Adequate below 6 GHz, where wet is under 8% of the total. It is the dominant
  uncertainty at 24 GHz, where wet is 81%.
- **The P.676 version matters at 24 GHz and nowhere else.** v13 versus v10 moves 24.125 GHz by
  -3.1% and every other ladder frequency by under 0.6%. If a result is ever compared against
  an external v10-based figure, that band is the one to check.
- **Off-table frequencies must hard error, not interpolate.** The 22.235 GHz water line and the
  60 GHz oxygen complex make interpolation meaningless above ~20 GHz. Regenerating is a
  one-line edit, so an error costs nothing.

---

## B6. Sequencing

1. **WP0 + WP6** -- commit the generator, verify against published values, wired to nothing
2. **WP5** -- gate, off, prove goldens bit-identical
3. **WP1 + WP2** -- model and wiring
4. **WP4** -- resolve-time refusal, drop `freq013`
5. **WP3** -- only if decision 2 resolves
6. Re-run **`freq012` only** (it carries the 24.125 GHz row). `freq009`-`freq011` are all at or
   below 5.8 GHz, where the effect is under 0.5%, and can be re-run for completeness rather
   than necessity. ~18 min mandatory, ~72 min for all four.

---

## B7. What carries over unchanged

B6 of the original document -- the interim ch8 scope wording -- remains valid, remains true,
and remains the fallback if none of this is implemented:

> These rungs isolate the geometric and ionospheric consequences of band choice. They
> deliberately exclude atmospheric absorption, which dominates above ~20 GHz and rules out
> 61 GHz for a ground-space link entirely.

With B1's table in hand, that sentence can now cite a number instead of asserting a direction.
