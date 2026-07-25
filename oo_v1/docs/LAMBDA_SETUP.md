# LAMBDA 4.0 — external dependency setup

The LAMBDA toolbox is **not** included in this repository and must be installed separately,
exactly like the Orekit cross-validation bridge.

## Why it is not vendored

Every file in the TU Delft distribution carries only:

```
Copyright: Geoscience & Remote Sensing department @ TUDelft
Contact email:  LAMBDAtoolbox-CITG-GRS@tudelft.nl
```

There is **no licence file and no licence grant of any kind**. Absent an explicit grant the
legal default is all-rights-reserved, so committing the source into this public repository
would be unlicensed redistribution. Treating it as a user-installed dependency costs
nothing scientifically and removes the risk entirely.

If you want it bundled, ask TU Delft for an explicit grant at the address above first.

## Install

1. Obtain `LAMBDA 4.0` (MATLAB) from TU Delft.
2. Unpack it anywhere **outside** this repository, e.g. `~/tools/LAMBD4-master_2024_10_01`.
   The folder must contain `LAMBDA.m`, `Ps_LAMBDA.m` and the `LAMBDA_toolbox/` subfolder.
3. Point the config at it:

```matlab
cfg.estimator.lambda.toolboxPath = '/absolute/path/to/LAMBD4-master_2024_10_01';
cfg.estimator.lambda.enable      = true;
```

`revgnss.integer.LambdaResolver.addToPath` adds both the root and `LAMBDA_toolbox/` using
`fullfile`. (The toolbox's own examples use a Windows separator —
`addpath('..','..\LAMBDA_toolbox')` in `LAMBDA_examples/RUN_example_1.m:27` — which fails
on macOS/Linux. Do not copy that line.)

## Behaviour when it is absent

Nothing breaks. `LambdaResolver.resolve` returns the **float** solution with
`info.decision = 'unavailable-toolbox'`. It never errors and never silently claims a fix.
Tests that need the toolbox skip themselves; set `LAMBDA_TOOLBOX_PATH` in the environment
to enable them:

```bash
export LAMBDA_TOOLBOX_PATH=/absolute/path/to/LAMBD4-master_2024_10_01
```

## What the wrapper adds on top of the toolbox

The ILS search is **not** reimplemented — it is called as a black box. The wrapper supplies
the parts the toolbox deliberately leaves to the caller:

- **metres → cycles** for the vector *and the full covariance* (`Qa_cyc = D·Qa_m·Dᵀ`).
  The full matrix matters: ILS decorrelation lives on the off-diagonals. The pre-existing
  `IntegerAmbiguityFixer` reads only `P(i,i)` — that is integer *rounding*, the weakest
  estimator, which this replaces.
- **A success-rate gate.** Every fix is gated on the bootstrapped SR from `Ps_LAMBDA`
  (a rigorous lower bound for ILS). This is the false-fix protection `IntegerAmbiguityFixer`
  explicitly lacks (`falseFixRisk:false`).
- **A ratio test** on `sqnorm(2)/sqnorm(1)`.
- **An explicit precondition check** — see below.

## The precondition that matters most

LAMBDA finds the integer vector nearest a float vector **assuming the truth is an integer**.
The *undifferenced* ambiguities in this codebase are **not**: they absorb the per-arc
clock/hardware bias (`CarrierMeasurementBuilder.m:280`), so `B = λN + bias`. Fixing those
would inject a bias-sized error.

Only **differenced** (between-antenna / between-satellite) or **bias-calibrated** vectors may
be resolved. `LambdaResolver.assertIntegerParametrisation` makes that explicit at the call
site, and the success-rate gate will usually reject a contaminated vector anyway — but the
assertion is the contract.

See `docs/plans/ISL_LAMBDA/03_LAMBDA_INTEGER_RESOLUTION.md` for the three routes (A:
between-antenna attitude — already integer-ready; B: between-satellite ISL; C: PPP-AR,
which needs a phase-bias product that does not exist here).

## References (PDFs ship with the toolbox)

- Massarweh, Verhagen & Teunissen (2024), *New LAMBDA toolbox for mixed-integer models*.
- Teunissen (1993, 1995) — least-squares ambiguity decorrelation adjustment.
- de Jonge & Tiberius (1996) — implementation aspects.
- Verhagen (2005) — reliability of integer ambiguity resolution.
