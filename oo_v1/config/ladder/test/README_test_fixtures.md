# test axis: configs OWNED BY THE TEST SUITE, not rungs of a physics ladder

Every other ladder axis answers a question. This one does not. These files are INPUTS to
`tests/*.m`, and their numbers are fixture ids, not ladder positions. Nothing here is a
result and nothing here belongs in a sweep.

## `test003_*.json` is not `test_*.m`

The collision is one character wide and it is worth naming, because it catches everyone once:

| pattern | what it is | example |
|---|---|---|
| `test` + **digit** | a scenario config on this axis | `test003_jointCoherentTwoWayCode.json` |
| `test` + **underscore** | a MATLAB test that CONSUMES one | `test_joint_coherent_two_way_scenario.m` |

The convention holds without exception across both trees. `run_oo_v1.m` (header, the axis
table) states the same thing: `config/ladder/test/  test###  fixtures owned by the test suite`.

## Ownership map

Nothing on this axis should exist without a loader. If a row here says NONE, that rung is
either dead or filed in the wrong axis, and both are bugs.

| rung | loaded by | what it is for |
|---|---|---|
| `test001_idealFlat` | 4 `test_orekit_*` cross-validation tests | the "everything off" flat baseline both estimators start from |
| `test002_idealFlatConditioned` | **NONE** | test001's `addToR=false` partner. See below. |
| `test003_jointCoherentTwoWayCode` | 7 tests (two-way Jacobian, link schedule, ISL time transfer, summary PDF) | 6-spacecraft joint EKF, scheduled coherent transponded PN two-way code ring |
| `test004_...Realism` | 3 tests (range noise/bias guards, secondary ground toggle) | the same at realism grade |
| `test005_jointReciprocalTimeTransfer` | 2 tests (ISL time transfer, session-timing persistence) | 2-spacecraft first-order reciprocal ISL time transfer |
| `test006_groundOrientationInert120` | `test_golden_ground_orientation.m` | gate-inertness fixture, every ground-referenced gate OFF |
| `test007_groundOrientationSmoke120` | `test_golden_ground_orientation.m` | 120 s pre-commit execution coverage, all stages ON |
| `test008_groundOrientationCarrier120` | `test_golden_ground_orientation.m` | Phase F ambiguity resolution code-path check |

## The three golden fixtures, and why renaming them is expensive

`test006`/`test007`/`test008` are pinned by frozen fingerprints in `tests/golden/*.json`.
`GoldenRunFingerprint` stores `scenarioSha256 = fileSha256(scenarioFile)`, a hash of the file
CONTENTS, and `test_golden_ground_orientation.m` compares it before it compares any value.

The consequence is asymmetric and worth knowing before anyone tidies this folder:

- **MOVING a fixture between axes is free.** `scenarioFileIndex` scans every
  `config/ladder/<axis>/` and the resolver matches on FILENAME ALONE, so the folder is
  documentation. Contents unchanged means sha unchanged means the gate still passes.
- **RENAMING one is not.** A clean rename changes the internal `scenario.name`, which changes
  the file, which changes the sha, which fails the gate and forces a fingerprint re-cut. On
  `test006` that means re-cutting the one fixture at tolerance `1e-12` whose entire
  evidentiary value is that it has NEVER been re-cut. The re-cut would reproduce every value,
  so it is not dangerous, but it spends the cleanest provenance argument in the repo to buy a
  naming preference. `tests/golden/README_golden.md` carries the re-cut protocol.

`test008` is additionally cited BY NAME in the `_id` prose of four `carr` rungs, as the worked
example of a perfect wide-lane fix (20 of 20, bootstrapped 1.000) feeding an orientation solve
that was wrong by a factor of twenty-one. Renaming it breaks a written evidence chain that
runs into the thesis.

## Do not quote these as results

`test003`, `test004` and `test005` select `multiAsset.mode = 'joint'`, and the joint path in
`ReverseGNSSSimulation` is live for them. Joint mode is excluded from every reported result on
scientific grounds. These three are exercising the code path, which is a different and
legitimate job, but a number lifted from one of them is not a system performance figure.

## test002 is unowned

Nothing loads it. It survives only in a comment in
`+models/+clocks/TowerClockCorrectionProvider.m` describing it and `test001` as the two rungs
whose whole purpose is an empty `R`, a purpose they were silently not serving until `addToR`
was wired. Either give it a loader alongside `test001` in the Orekit tests, or delete it. It
should not sit here indefinitely as the only row in the ownership map reading NONE.

## Two rungs left this axis on 2026-08-20

Both were studies wearing a fixture's name: no test loaded either, and neither had a
fingerprint, so both moves were sha-neutral. Anything written before that date names them by
the old ids.

| was | now | why it never belonged here |
|---|---|---|
| `test009_kaIonoFree` | `freq/freq014_kaIonoFree` | a Ka 30/28 GHz ionosphere-free FALSIFICATION run: fractional separation 6.7 %, ~10.3x noise amplification against L1/L2's 3.0x, to delete ~1.4 cm of ionosphere. A `freq` question with a `freq` answer. |
| `test010_towerClockEpochMismatch` | `carr/carr021_towerClockEpochMismatch` | the standing fixture for the code/carrier tower-clock epoch defect that every code-carrier combination inherits. It is the defect `carr020` was cut to price. |

`freq014` also carries the `signals.enabledMask` orientation entry in
`config/internal/scenarioResolutionExceptionRegistry.m`, which keys on filename and was
re-pointed with the move.
