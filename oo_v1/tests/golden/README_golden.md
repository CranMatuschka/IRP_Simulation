# Frozen golden fingerprints — ground-referenced orientation

Every `.json` here is the output of `revgnss.GoldenRunFingerprint` on one committed scenario. It
is the answer to a question the summary could not previously answer: **has this number moved?**

Asserted by `tests/test_golden_ground_orientation.m`.

---

## What a fingerprint is, and what it is not

A fingerprint is **not** a claim that the numbers are right. It is a claim that they have not
**changed**. Correctness is argued elsewhere — in the estimator's own acceptance tests, in
`tests/test_ground_orientation_estimator_contract.m`, and in the physics.

Numbers are stored as `%.17g` **strings**, deliberately. `jsonencode` writes NaN as `null` and
`jsondecode` reads `null` back as `[]`, so a frozen NaN would return as an empty array and every
NaN-valued field would fail its own length check — a failure that is purely an encoding artefact.
A vector of NaNs is worse: it decodes to a cell. Strings round-trip every double exactly,
including NaN and Inf, and keep the file diffable, which matters for a file humans have to review.

Each fingerprint records the **SHA-256 of the scenario it came from**. That check catches the one
failure mode that makes a golden worse than useless: a scenario edited without the golden being
re-cut, so the gate passes while measuring something else.

---

## The fixtures

| fixture | arc | what it holds | may it move? |
|---|---|---|---|
| `test006_groundOrientationInert120` | 120 s | every ground-referenced gate OFF | **NEVER.** A change here means a supposedly gated commit leaked into the default path, and the commit is wrong regardless of how good its own numbers look. |
| `test007_groundOrientationSmoke120` | 120 s | joint + 3-parameter rotation + carrier probe ON | Yes, when a Phase B–E commit changes an estimator. Re-cut deliberately; record the reason below. |
| `test008_groundOrientationCarrier120` | 120 s | the above plus Phase F ambiguity resolution and the fixed-carrier observable | Yes, same rule. |

**No number from any of these is a result.** At 120 s the formation turns 0.4°, so an arc-constant
shape offset and an arc-constant rotation are the same parameter to within the noise. Both solvers
are *expected* to refuse, and the fixtures check that they refuse the same way every time.
Scientific claims come from the 6 h scenarios.

---

## Running the gate

Fast (what `run_all_tests` does): presence, schema and scenario hash only. It does not re-run
anything, because a 120 s federated run costs about 90 s and the suite has 357 tests in it.

Full — re-runs every fixture end to end and compares all 81 values:

```bash
OO_V1_GOLDEN=1 matlab -batch "addpath(genpath('.')); addpath('tests'); test_golden_ground_orientation"
```

Re-cutting a golden, once you have decided the change is intended:

```bash
matlab -batch "addpath(genpath('.')); out = run_oo_v1('test007_groundOrientationSmoke120.json', 120); revgnss.GoldenRunFingerprint.write(revgnss.GoldenRunFingerprint.fromRun(out, [], 'config/ladder/test/test007_groundOrientationSmoke120.json'), 'tests/golden/test007_groundOrientationSmoke120.json')"
```

---

## Change log

Every re-cut goes here, with the reason. A golden re-cut without an entry is indistinguishable
from a regression that was papered over.

### 2026-08-05 — initial cut

All three fixtures cut for the first time, against the commit ladder in
`docs/ground_referenced_orientation_execution_plan.md` Phases A–G and F. Nothing to compare
against; this is the baseline the ladder is measured from.

Verified at cut time: `test006_groundOrientationInert120` and `test007_groundOrientationSmoke120` both
reproduce **bit-for-bit** on a re-run (81 values, relative tolerance 1e-12 and 1e-9).

Notable values in this cut, recorded so a future reader can see what changed and why:

* `jointObservableShapeDof` — **1 of 12** on the code observable, **9 of 12** on the fixed
  wide-lane carrier. This is the measurement that explains run20: the ground double difference on
  code constrains essentially none of the formation's shape, so the joint solve was regularising
  eleven unseen directions with one scalar prior. It is not a weight problem.
* `jointAcceptReason` — both fixtures record a REFUSAL. That is the designed behaviour at 0.4° of
  turn and is the point of the fixture.
* `jointLeverArmDdSystematic_m` = **3.4e-15 m**. The observable and the prediction are now
  referenced to the same antenna phase centre (execution-plan B1); the defect that removed is
  reported alongside as `leverArmDdUncorrected_m`.
* `carrierFixRate_wideLane` — the probe's counted rate, now with a Wilson interval computed on the
  **effective** epoch count (9.3 of 121 at 120 s), not on the 2420 counted trials. The counted
  trials are not independent: the dominant error is the arc-correlated geometry error, not thermal
  noise.

### 2026-08-06 — re-cut all three, after two global physics fixes (audit defects D1, D2)

All three fixtures re-cut one day after the initial cut, following two fixes that change the
truth physics globally. This is the sanctioned exception in which even
`test006_groundOrientationInert120` moves, and the pre-re-cut full rerun is the evidence that no gate
leaked: the inert fixture moved in exactly two clock-sensitive scalars and nothing else
(`shapeErrRaw_m` by 0.96 mm, `shapeErrSolved_m` by 4.8e-9 m; the other 79 of 81 frozen values
bit-identical, every ground-referenced gate still recorded as off).

The two fixes:

* **D1 — `models.clocks.ClockModel.precomputeNoise` FFT amplitude scaling.** The synthesized
  WPM/FPM/flicker-FM colored clock noise was a factor ~2/N too quiet (N = epoch count), i.e.
  effectively absent from every run and run-length dependent. Corrected to
  `A_k = sqrt(N*fs*S_k)/2` (verified against the analytic broadband sigma and the
  `sqrt(2 ln2 h-1)` Allan floor). These fixtures run realism-grade clocks, so their truth
  clocks now carry the flicker floor that was previously suppressed. The relative layer is
  nearly immune (clocks cancel in the two-way observables): solved shape moved by 4.8e-9 m.
* **D2 — `GroundDifferencedRotationSolver.estimatedEuler_`.** The `estimatedAttitude` lever
  mode read the euler rows of `history.x`, which under the default `quaternionErrorState`
  parameterization are the post-reset MEKF error state (identically zero) — so the lever
  prediction was built at IDENTITY attitude while the observable carried the truth attitude,
  silently re-creating the B1 asymmetry. It now reads `history.nominalQuat_wxyz` (valid under
  both parameterizations). This restores the value the initial-cut entry above documented:
  `jointLeverArmDdSystematic_m` returns to **3.4e-15 m** (the fingerprint frozen in between
  held 2.3e-10 m — the identity-attitude residual).

Verdict fields are unchanged in kind: both solvers still refuse rotation at 0.4° of turn, shape
is still applied from the rotation-constrained re-solve, `jointObservableShapeDof` is still
1/12 (code) and 9/12 (fixed wide-lane carrier). Only the digits behind those decisions moved,
at the size of the restored clock noise.

Verified at re-cut time: the full gate (`OO_V1_GOLDEN=1`) reproduces all three fixtures against
the new fingerprints; the six Stage-85 goldens and the swarm-relative baseline were re-captured
in the same pass and re-verified green (Stage-85: zero metric deviations; swarm digest:
max|delta| = 0 on every component). Note the re-captured REALISM goldens changed category:
`finalPositionRMS` / `finalClockBiasRMS` ≈ 286 / 284 m (was ~1.3 m) — the restored flicker
floor of the realistic oscillator meeting the one-way GEO radial↔clock degeneracy. That is the
honest one-way baseline; the pre-fix meter-class realism number was the D1 bug.

---

## Re-cut 2026-08-08 — the config/ladder migration, and a PRE-EXISTING drift it exposed

The three fixtures moved from `config/scenarios/ground_orientation_*120.json` to
`config/ladder/test/test00{6,7,8}_groundOrientation*120.json` and lost their
`simulation.duration_s`, which is now the second argument of `run_oo_v1`
(`test_golden_ground_orientation` passes `FIXTURE_DURATION_S = 120` explicitly). Both
`scenarioName` and `scenarioSha256` therefore had to be re-cut.

**The migration itself is provably inert.** Two checks were run before the re-cut:

1. *Config A/B.* The pre-migration file (old name, `duration_s` inside the JSON) and the
   migrated file (duration supplied as a run argument) resolve to configurations that are
   identical leaf for leaf — 0 differing leaves on all three fixtures, excluding
   `scenario.name`, `report.runVersion` and `provenance.explicit`.
2. *Runtime A/B on the inert fixture.* Running both files end to end at 120 s and comparing
   every fingerprint field gives **exactly two differences: `scenarioName` and
   `scenarioSha256`.** Every numeric field is bit-identical.

**What the re-cut did expose is a drift that predates it.** The values frozen in the previous
fingerprints no longer match what this working tree produces, on
`test006_groundOrientationInert120` — the fixture whose whole purpose is that it must never
move:

| field | frozen | this tree |
|---|---|---|
| `shapeErrRaw_m` | 1.10874052908731 | 0.858544334149772 |
| `shapeErrSolved_m` | 0.139745239065178 | 0.138615055951347 |
| `baselineErrRaw_m` | 1.18745995861981 | 0.995897577927101 |
| `formalShapeSigma_m` | 0.72496142437215 | 0.115988396652144 |
| `beamPathErrRms_m` | 0.261173941628095 | 0.253320005973328 |
| `beamCoherenceFreq_Hz` | 57393256.0 | 59172677.0 |
| `beamSpotDisplacement_m` | 12948.6 | 11997.99 |

By this file's own rule that is the signature of a supposedly gated change reaching the
default path. The uncommitted working tree at the time of the re-cut carried modifications to
`+revgnss/JointGeometrySolver.m`, `+revgnss/GroundDifferencedRotationSolver.m`,
`+revgnss/GroundCarrierAmbiguityProbe.m` and `config/masterConfig.m`, plus three untracked new
classes; one of those is the cause. **The fingerprints below were re-cut against that tree, so
they certify the tree as it stands and NOT a reviewed change.** The gate reasons are still
`gateOff` on all three ground-referenced stages, so whatever moved did so without switching a
gate on — that is what needs explaining before these numbers are quoted.
