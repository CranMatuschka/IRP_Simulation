# Handoff: wire the joint constrained integer/attitude search

Written 2026-08-14. Everything below is committed except where stated.

## The question this line of work is answering

Can reverse-GNSS carrier phase determine spacecraft attitude at GEO on its own,
without a star tracker and without idealising the antenna hardware?

## Where it stands

`feat025`/`feat027` measured the wall: 15 differenced observables against 15
float ambiguities is exactly determined by the ambiguities alone, leaving
nothing to inform attitude. The tell was the sigma, which read 0.230097 deg
whether the true error was 0.46 deg or 1.40 deg. A covariance that carries no
information about the actual error is an unobserved state, not a struggling one.

Three mechanisms were then built and measured (commit `bdbeaed`), 3600 s, GEO,
5 towers, 4 antennas:

| rung | mechanism | error deg | sigma deg | err/sigma |
|---|---|---|---|---|
| feat028 | baseline, AR policy-blocked | 1.397941 | 0.230097 | 6.08 |
| feat029 | integer fix (bias DELETED) | **1.159938** | 0.210448 | 5.51 |
| feat030 | tower-common bias | 1.380606 | 0.230438 | 5.99 |
| feat031 | fix + common bias | 1.187378 | 0.210284 | 5.65 |
| feat032 | DD only | 1.649196 | 1.024780 | 1.609 |
| feat033 | fix + DD | 1.235936 | 0.917092 | **1.348** |

Two findings, and they are separate virtues sitting in separate rungs:

- **Accuracy** comes only from the absolute integer fix. `lambda*(dphi - N) =
  b_body' R' e` has no common-mode escape hatch, so the whole error becomes
  visible rather than the ~5 % differential part. feat029 is the only rung whose
  sigma ever responded.
- **Honesty** comes only from the between-tower double difference. The
  inter-antenna bias was being absorbed into the calibration and counted as
  information, so the filter tightened on a constant it had merely fitted.
  Cancelling it algebraically raises the sigma to what the geometry actually
  supports. **The 0.2301 deg sigma quoted by every earlier attitude rung is not
  defensible.**

## The remaining task: wiring

`+revgnss/JointConstrainedAttitudeResolver.m` is written, complete and
self-contained. It is NOT called from anywhere yet.

### Why it should work

The existing `BaselineCarrierAmbiguityResolver` resolves each (tower, baseline)
cell **independently** -- it loops `ti`, `bi` and writes `ambiguityStatus{ti,bi}`
with its own RMS and ratio test per cell. That discards the strongest constraint
available: all 15 observables must be explained by ONE rotation of a rigid body
whose geometry is known by construction. 15 observables against 3 attitude DOF
is massively overdetermined.

A one-cycle integer error is lambda ~ 0.19 m at L1. Absorbing it by rotating
instead needs `dtheta ~ 0.19 / 2 = 0.095 rad = 5.4 deg`, and that SAME rotation
must then explain the other 14 rows simultaneously. It cannot. Wrong integer
sets are rejected violently under a joint cost while looking perfectly
acceptable per cell -- which is why the per-cell ratio came out 1.0229.

The surviving degeneracy (shift every tower's integer on baseline `i` by a
common `k_i`, absorb into the bias) is invisible to attitude, because attitude
enters only through `(R b_i).e_t`. So the search works on between-tower
differences and **never needs the bias calibrated, estimated or deleted**.

### Where to wire it

`DiffAttitudeBuilder.finalize(store, cfg)` does NOT have geometry.
`DiffAttitudeBuilder.buildRows(store, cpInfo, x_est, sm, towers, leverArms, cfg, nx)` DOES.

Call it from `buildRows`, once, guarded by a persistent one-shot flag (the same
pattern as the `TOWER DD APPLIED` announcement already in that file). Build:

```matlab
% [nT x nB] modelled single differences for a candidate attitude
gFun = @(eul) buildModelledSD_(cfg, towers, r_cm, eul, leverArms, nT, nB);
% where each entry is
%   modelRangeOnly(cfg, towers, ti, ai, r_cm, eul, leverArms) ...
% - modelRangeOnly(cfg, towers, ti, 1,  r_cm, eul, leverArms)
```

`zSD(ti,bi)` is the observed `phi_i - phi_ref` already computed in `buildRows`.

Add the gate to `masterConfig.m` next to the two existing leaves:

```matlab
cfg.estimator.diffAtt.jointConstrainedSearch.enable = false;
```

Reuse `estimator.attitudeInit.search` for parameters: `windowDeg [2;2;2]`,
`stepDeg [0.5;0.5;0.5]` (729 candidates), `ratioThreshold 1.20`,
`maxRmsCycles 0.30`.

### Then run

`feat034` = feat028 + joint search. **Bias left IN at its realistic 0.02 cycles,
nothing deleted, nothing declared calibrated.** This is the first genuinely
quotable attitude rung in the ladder, because the joint search cancels the bias
rather than needing it calibrated.

Expected: ~0.05 deg (3 arcmin) on the two well-conditioned axes, ~0.3 deg about
the line of sight (the ~17 deg Earth subtense from GEO is the only thing
supplying that axis). Against feat029's 1.159938 deg from independent fixing.

Verify with the golden gate after wiring:

```matlab
addpath(pwd,'config','config/internal','tests','tests/regression');
run_oo_v1_regression('smoke','single')      % also 'headline', 'correlated'
```

## Open defects, found and not fixed

1. **`BaselineCarrierAmbiguityResolver.m:265`** -- a catch-all `else` emits
   `'rejectedRms'` when NO named gate failed. 10/15 baselines carry that label
   while their own recorded `rmsBest` (<= 0.0349) is far below the 0.10
   threshold, so the label is wrong and the real failure is on the L2 branch.
   **The 5/15 fix count is probably an undercount.**
2. **`daInfo` is never persisted.** `buildRows` writes it into
   `errStruct.diffAttRows`, which is consumed in-epoch, so DD and joint
   diagnostics cannot be read back from the output `.mat`. A one-shot log line
   was added as a workaround; the proper fix is to persist it into `diag`.
3. **The phase-bias gate refuses on a status string, never on magnitude**
   (`BaselineCarrierAmbiguityResolver.m:118-119`). The bias is 0.02 cycles
   against a 0.5-cycle rounding margin, i.e. 25x inside the safe interval. The
   joint search makes this gate unnecessary.

## Standing caveats for anything quoted from this family

- **Phase wind-up is not modelled anywhere in this simulation**, and an integer
  fix is exactly the operation a slow unmodelled carrier-phase rotation
  corrupts. It does NOT cancel in a between-tower DD, because the
  tower-to-satellite geometry differs per tower. Every fix here is optimistic.
- **feat029, feat031 and feat033 delete the inter-antenna bias.** They are
  diagnostics. They are not system performance figures.
- The third attitude axis is geometrically weak by roughly `1/sin(10 deg) ~ 6`
  and no amount of integer work changes that. Only a commanded slew (the bias is
  fixed in the BODY frame while attitude is not) or a long enough arc for GEO
  libration breaks it.
