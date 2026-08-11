# Ionosphere L1-anchor fix, the complete freq sweep, and the plan for atmospheric absorption

Date: 2026-08-11
Branch: `feature/ground-orientation-exec`
Commit delivered: `515ea3b` fix(ionosphere): the L1 anchor was relabelled at the primary band, never converted

This document has two halves. Part A records what was diagnosed, fixed and measured. Part B
is the plan for the follow-on work (gaseous absorption, link budget, S4 frequency law) that
Part B's findings showed to be the real gap at high bands.

---

# Part A: what was done

## A1. The defect

`freq009`-`freq013` retune the carrier by rewriting `signals.L1.frequency_Hz` itself, up to
61.25 GHz. The ionosphere did not follow.

The cause was **relabelling, not a missing conversion**. Three facts compose:

1. `cfg.errors.ionosphere.*.verticalDelayL1_m` (5.0 m), the Klobuchar amp/DC (20 ns / 5 ns)
   and `stochastic.sigmaVDelayL1_ss_m` are PHYSICAL 1575.42 MHz amplitudes.
2. `EnvironmentModel.getIonoDelay` scales by `(f_L1/f_signal)^2`, and
   `CodeMeasurementBuilder` scales again on per-signal expansion.
3. In both, `f_L1` is `revgnss.SignalUtils.frequency(cfg,'L1')` -- the **RESOLVED** band,
   which the rung has retuned.

For the primary signal `f_signal == f_L1`, so **both scale factors are identically 1.0**.
5.0 m of L1 delay was therefore applied verbatim at 5.8, 24.125 and 61.25 GHz. `freq011`'s
own `_id` predicts `0.0738x` the L1 ionosphere = `(1.57542/5.8)^2`; the code delivered `1.0x`.

The anchor was never converted. It was renamed.

## A2. The fix

Added `revgnss.Constants.IONO_ANCHOR_L1_HZ = 1575.42e6` and one shared helper:

```matlab
models.atmosphere.IonosphereModel.climatologyAnchorScale(f_ref_Hz, exponent)
```

It composes with the existing downstream factor:

```
(f_canon/f_ref)^n * (f_ref/f_signal)^n = (f_canon/f_signal)^n
```

so it is correct for every caller whatever frequency they ask for. Applied at three effects,
each with its own power law:

| effect | exponent | note |
|---|---|---|
| first-order delay | 2 | `verticalDelayL1_m`, Klobuchar, GM residual |
| amplitude scintillation sigma | `frequencyExponent` | lands in **R**; was charging L1 scintillation at every band |
| higher-order ionosphere | 3 / 4 | restructured to convert back to canonical L1 so the fractions AND their caps clamp where defined |

### The trap that a naive helper would have hit

**Do NOT apply the scale to the diurnal VTEC mean.** That branch builds its metres through
`K_L1 = 40.308e16/f_ref^2`, which already carries `1/f_ref^2` and is therefore already
expressed at the reference band. Scaling it again double-converts. It is **live in realism
grade**, so a blanket "convert every L1-anchored quantity" helper would have silently
corrupted every realism result.

The two truth sub-paths behave oppositely under retuning and must be split:

- `diurnal.enable = false` (default) -> constant `verticalDelayL1_m`, needs conversion
- `diurnal.enable = true` (realism)  -> `K_L1` mean, already correct, must be left alone

## A3. Verification

At the canonical band every factor is a value divided by itself, so it is **exactly 1.0** in
floating point.

- **Stage-85 gate: 0/4 FAILED** at `rtol = 1e-9` across single / headline / realism / feat024
- 61.25 GHz vertical iono now returns **3.308 mm** (predicted 3.3 mm)
- 9 ionosphere tests pass, including the Orekit cross-validation (dispersive ratio exact to 5e-10)

New test `tests/test_iono_band_scaling.m` pins the invariant the defect actually broke:

> the delay at a FIXED signal frequency must not depend on the reference band

which also catches double-conversion of the diurnal branch, and asserts the guard rejects a
non-physical reference frequency.

---

## A4. Sweep results: 13/13, the first complete freq axis

| Rung | Configuration | nx | posRMS | NIS ratio |
|---|---|---|---|---|
| freq009 | 915 / 2450 MHz | 67 | **0.992 m** | 0.798 |
| freq010 | 2450 / 5800 MHz | 67 | 1.056 m | 0.795 |
| freq012 | 5800 / 24125 MHz | 67 | 1.099 m | 0.788 |
| freq013 | 24125 / 61250 MHz | 67 | 1.123 m | 0.793 |
| freq006 | L1/L5 iono-free, no iono state | 62 | 1.199 m | 1.235 |
| freq005 | L1/L5 raw | 67 | 1.277 m | 0.828 |
| freq004 | L1/L2 iono-free, no iono state | 62 | 1.333 m | 1.265 |
| freq002 | L1/L2 raw | 67 | 1.441 m | 0.829 |
| freq007 | L1/L2 raw, no iono state | 62 | 1.504 m | 0.882 |
| freq008 | L1 only, no iono state | 42 | 2.197 m | 0.879 |
| freq011 | 5200 / 5800 MHz | 67 | **4.070 m** | 0.821 |
| freq001 | L1 only | 47 | 4.903 m | 0.758 |
| freq003 | L1/L2 iono-free | 67 | **6.230 m** | 1.134 |

Artefacts: `/private/tmp/claude-501/freq_sweep_final` (snapshot, `PROVENANCE.txt`,
`iono_anchor_fix.diff`, `freq_sweep.csv`).

### Finding 1: the slant-iono state helps only where something observes it

| | state ON | state OFF | |
|---|---|---|---|
| L1 only | 4.903 | **2.197** | hurts 2.2x |
| L1/L2 raw | **1.441** | 1.504 | helps 4.4% |
| L1/L2 iono-free | 6.230 | **1.333** | hurts 4.7x |

One rule covers all three: the state pays off **iff an observable ionospheric differential
survives into the measurements**. Single-frequency never had one; iono-free spent it forming
the combination; only raw dual-frequency keeps it. Asymmetry is ~80:1 against guessing wrong.

### Finding 2: iono-free is NOT worse than raw

`freq003`'s 6.23 m is a **misconfiguration**, not a property of the combination. Removing the
redundant states gives 1.333 m, which *beats* raw's 1.441 m. Reproduces on the other pair:
1.199 m vs 1.277 m. Iono-free wins by 6-8% despite half the rows and 3.4x noisier ones.

> Any existing claim that "IF costs accuracy" read off a freq003-style rung is measuring the
> redundant state, not the combination, and must be rechecked.

### Finding 3: above ~5 GHz the ionosphere stops mattering

freq010/012/013 span 2.45 -> 61.25 GHz: a 25x range in carrier, **625x in ionospheric
magnitude** (2.07 m -> 3.3 mm). They land within **6%** of each other.

This does NOT support "higher carrier is better". It supports "once the ionosphere is small
against code noise, shrinking it further buys nothing".

### Finding 4: the one failure is CONDITIONING, not magnitude

| Rung | `\|1-(fp/fs)^2\|` | I_primary | differential | posRMS |
|---|---|---|---|---|
| freq012 | 16.30 | 0.021 m | 0.348 m | 1.099 m |
| freq009 | 6.17 | 2.067 m | 12.76 m | 0.992 m |
| freq013 | 5.45 | 0.003 m | 0.018 m | 1.123 m |
| freq010 | 4.60 | 0.369 m | 1.70 m | 1.056 m |
| **freq011** | **0.244** | 0.369 m | 0.090 m | **4.070 m** |

Ordering by *absolute differential* is non-monotonic (freq013 0.018 < freq011 0.090 <
freq012 0.348, but posRMS 1.123 / 4.070 / 1.099). **Conditioning separates cleanly.**

At 10.9% carrier separation the two signals see nearly the same ionosphere, so the filter
cannot split ionosphere from range and the state aliases into position.

### CORRECTION to the originally planned Change 3

The plan proposed gating on `I_p * |1-(f1/f2)^2|` against the code noise floor. That formula
catches freq011 here **only by luck** -- because 5.8 GHz had already shrunk `I_p`. A narrow
pair at a LOW band (1200/1300 MHz: conditioning 0.174, `I_p` 8.6 m, product ~1.5 m) sails
through the gate while being badly conditioned.

Two separate tests are required:

1. **conditioning** `|1-(f_p/f_s)^2| >~ 0.5` -> REFUSE.
   Empirically bracketed: 0.244 fails, GPS L1/L2's 0.647 is fine.
2. **magnitude** differential below the noise floor -> disable, harmless.
   (freq013: the state is worthless, not harmful.)

### Finding 5: NIS is BLIND to all of this

Ratios span 0.758-1.265 across configurations differing by **6x** in position error, and the
single worst rung (freq003, 6.23 m) posts a perfectly respectable 1.134. The filter is
genuinely consistent with its own wrong assumptions.

> Any gate must be computed at **resolve time from frequency geometry**. It cannot be
> detected from run diagnostics.

## A5. Caveats on citing the sweep

- **Cross-tree absolute comparison is invalid.** L1/L5 raw is 1.277 m here vs 0.343 m in the
  earlier ladder, which predates the R campaign, the tower-clock stochastic flip and the
  Winkel oscillator table. Rankings carry over; absolute values do not.
- **freq009's win is separation, not spectrum.** 91% carrier separation earns 0.992 m.
  Nothing here says licence-exempt bands are intrinsically better than GPS bands.
- **`S4zen` remains band-blind** -- see Part B.
- Each rung = main 3600 s run + **12 Monte Carlo seeds at 900 s** (`report.monteCarlo` is off
  in `masterConfig` but ON via `golden_baseline.json`), hence ~18 min/rung, ~4 h for 13.

## A6. Still open from the original plan

**Change 3 (observability gate) was deliberately NOT implemented.** Holding it was
vindicated: the sweep showed the specified criterion had a blind spot. It is now well-posed
(two tests, threshold empirically bracketed) and is a small, self-contained piece of work.

**Audit recommendation.** A slant-iono state estimated where nothing observes it cost 4.7x in
position while NIS stayed in band. Any other ladder rung or thesis result running
`perTowerSlant` alongside an iono-free combination carries the same silent penalty. Worth an
audit before ch8.

---

# Part B: plan for atmospheric absorption, link budget and S4

## B0. Why this, and why not S4 alone

`S4zen` carries no frequency dependence, so the Conker fading factor `1/sqrt(1-2*S4^2)` is
identical at 915 MHz and 61.25 GHz. Physically S4 falls off as roughly `f^-1.5` in weak
scatter; at 61.25 GHz the true value would be ~0.0012, i.e. no scintillation at all.

**But implementing S4's frequency law alone is not worth doing.** Quantified: at 61.25 GHz it
moves the scintillation sigma from ~54 mm to ~8 mm, against 0.30 m code noise -- a **1.6%
change in total R**, and far less in position. It would not move a single sweep conclusion.

The stronger objection is **false precision**. The C/N0 model is
`base_dBHz + elevationGain_dB*sin(el)` -- elevation only. There is **no frequency dependence
and no atmospheric absorption anywhere in the model**. 61.25 GHz sits inside the oxygen
absorption complex: ~15 dB/km specific attenuation at sea level, of order 100 dB zenith
through the atmosphere. A ground-to-GEO link at 61.25 GHz **does not close**.

So freq013's tidy 1.123 m describes a link that could not physically be established. Adding a
scintillation frequency law would make the ionospheric physics look more rigorous at exactly
the bands where a four-orders-of-magnitude larger effect is entirely absent.

**Do the package together, or not at all.**

## B1. Two findings that shape the design

**The golden runs `codeNoise.model = 'cn0'` with `cn0.enable = 1`.** Verified by resolving
`golden_baseline.json`. The C/N0 path is LIVE, not inert. Unlike the anchor fix -- exactly 1.0
at L1, so free -- absorption at L1 is ~0.035 dB zenith, i.e. ~0.4% on sigma through
`10^(-A/20)`, which is six orders of magnitude past `rtol = 1e-9`. **Gating is mandatory.**

**Much of the scaffolding exists.**
- `cfg.measurements.codeNoise.cn0.weatherLossScale_dB` is declared in `masterConfig` and read
  by **no physics anywhere** -- a reserved-but-inert hook for exactly this.
- `cfg.multiAsset.twoWayISL.linkBudget` is a working RF budget (`EIRP_dBW`, `GT_dBK`,
  `refFrequency_Hz`, free-space path loss) establishing the repo's conventions.

This is extend-not-build.

## B2. Work packages

### WP1 -- Gaseous absorption model

New `models.atmosphere.GaseousAbsorption` implementing **ITU-R P.676 Annex 1** (line-by-line:
44 oxygen lines + 35 water-vapour lines, valid 1-1000 GHz).

Annex 1 over the simplified Annex 2 specifically because 54-66 GHz is where the simplified
forms are weakest, and 61.25 GHz sits in it. Also page-referenceable for the traceability
register.

**Drive it from the EXISTING weather state.** `EnvironmentModel` already carries per-tower
ZHD/ZWD from `localWeatherGM`; invert Saastamoinen for surface pressure and water-vapour
density. Absorption then shares one weather realisation with the troposphere rather than
introducing a second independent atmosphere -- the same defect class as the per-satellite
atmosphere artefact, avoided by construction.

### WP2 -- Absorption into C/N0

Extend the `'cn0'` branch of `codeSignalSigma` (`MeasurementModelUtils.m:174`) and its twin
in `ErrorChain.m:487`:

```
cn0_dBHz = base_dBHz + elevGain_dB*sin(el) - A_gas(f, el, weather)
```

**Deliberately NOT a full RF budget in this pass.** Subtracting an absorption term is a small,
reviewable change delivering the entire scientific point. A full EIRP/G-T budget adds antenna
and system-temperature parameters that are pure invention for this mission and would need
their own sourcing. Keep that as a later `'physicalRF'` mode mirroring the ISL one.

> **Two call sites compute C/N0 identically and must not drift.** Same lesson as the
> truth/model iono helper: put it in ONE shared function.

Delete `weatherLossScale_dB` in the same change rather than wire it. It is a 2 dB scalar
placeholder with no model behind it; keeping it beside a real absorption term leaves two
knobs that look equivalent, one of which lies.

### WP3 -- S4 frequency law

Nearly free: `climatologyAnchorScale(f_ref, exponent)` already exists and already takes an
exponent. Add `scintillation.s4FrequencyExponent`, default **0** (preserves today's behaviour
exactly), set to **1.5** under realism grade. ~3 lines plus config.

### WP4 -- Link closure

The one that changes conclusions. Below a C/N0 threshold the receiver produces **no**
measurement, not a noisy one. Add `cn0.minTrackable_dBHz` (~25-30 dB-Hz) dropping rows
outright.

> **Expect freq013 to stop producing a solution at all.** That is the correct result and the
> goal of the exercise, not a regression. Decide this up front.

Touches row-count bookkeeping that the NIS budget checks (`arcNisRowBudgetCloses`).

### WP5 -- Gating

```
cfg.atmosphere.gaseousAbsorption.enable = false      % master, default off
cfg.realism.include.gaseousAbsorption                % only when realism.grade = true
```

**The gate needs its own test, because this repo makes inert toggles routinely.** The toggle
audit found ~70, and `weatherLossScale_dB` is one in this exact subsystem. Two specific traps:

- **No physics reader.** The `feat` ablation rungs resolve `master 0, truth 1` and disable
  nothing, so any "effect X contributes Y m" read off them measures noise.
- **`_extends` inheritance is recorded as OWNERSHIP**, so `resolveEnablePairsPostMerge` skips
  the truth/model pair and a rung looks configured while being inert.

Three assertions required:

1. **OFF == baseline** -- bit-identical goldens with the gate off. Proves no leak.
2. **ON changes something** -- specific non-trivial delta at a known frequency. Proves not inert.
3. **ON via `_extends` also changes it** -- resolve a rung inheriting the flag and confirm the
   physics sees it. Proves the inheritance path works.

(2) and (3) are the ones this repo keeps missing; (1) is the only one written by default.

### WP6 -- Tests

Validate against **published ITU-R values**, not self-consistency:

| Check | Expected |
|---|---|
| zenith attenuation at L1 | ~0.035 dB |
| zenith at 22.235 GHz | water-vapour line visible |
| zenith at 60 GHz | order 100 dB |
| elevation scaling | monotonic, ~1/sin(el) above 10 deg |
| 61.25 GHz at GEO range | C/N0 below threshold, rows dropped |
| L1 with gate off | bit-identical |

## B3. Decisions required before starting

**Does realism grade include absorption?** If yes, all 8 goldens re-cut and every ladder
result becomes non-comparable with existing ones.
**Recommendation: NO.** Keep it opt-in, add to the freq rungs only. The effect is negligible
at L-band where all other ladders live, so re-cutting eight goldens buys nothing and costs
cross-ladder comparability.

**Is a full RF budget in scope?** **Recommendation: NO** for this pass, per WP2.

## B4. Sequencing

1. **WP1 + WP6** -- build and validate the absorption model standalone against published
   values, wired to nothing.
2. **WP5** -- add the gate, off. Prove goldens unchanged.
3. **WP2** -- wire absorption into C/N0.
4. **WP4** -- link closure and row dropping.
5. **WP3** -- S4 frequency law.
6. Re-run **freq009-013 only**.

WP1 is the bulk (spectroscopic line table plus continuum terms). WP2/3/5 are small. WP4 is
small but has reach.

## B5. What this does and does not achieve

It makes the model **honest** about high bands. It does not make high bands **work**. The
likely end state is that freq012 degrades somewhat and freq013 stops closing entirely.

That is exactly the ch8 caveat -- but demonstrated rather than asserted.

## B6. Interim ch8 wording (valid without any of Part B)

> These rungs isolate the geometric and ionospheric consequences of band choice. They
> deliberately exclude atmospheric absorption, which dominates above ~20 GHz and rules out
> 61 GHz for a ground-space link entirely.

This is a defensible scope statement, it is true, and it protects the results that matter --
that conditioning drives the iono state, and that the ionosphere stops mattering above
~5 GHz. Both survive without any claim that 61 GHz is a usable band.
