# The joint constrained integer/attitude search: wired, measured, closed

Written 2026-08-14. The wiring task this document originally handed off is DONE.
What follows is the record of what was built, what it measured, and what the
measurement changed about the story.

## The question this line of work is answering

Can reverse-GNSS carrier phase determine spacecraft attitude at GEO on its own,
without a star tracker and without idealising the antenna hardware?

## Where it stood

`att001`/`att003` measured the wall: 15 differenced observables against 15
float ambiguities is exactly determined by the ambiguities alone, leaving
nothing to inform attitude. The tell was the sigma, which read 0.230097 deg
whether the true error was 0.46 deg or 1.40 deg. A covariance that carries no
information about the actual error is an unobserved state, not a struggling one.

Three mechanisms were then built and measured (commit `bdbeaed`), 3600 s, GEO,
5 towers, 4 antennas. `att010` is this pass:

Re-measured 2026-08-14 after the measurement covariance was corrected (see below).
The `bdbeaed` column is kept because the comparison is the finding, not a footnote:
it is like-for-like, att008 having been re-run on the pre-fix tree through the same
extraction to reproduce `1.649196` / `1.024780` exactly.

| rung | mechanism | error deg | sigma deg | err/sigma | was (err / sigma) |
|---|---|---|---|---|---|
| att004 | baseline, AR policy-blocked | 1.460038 | 0.227421 | 6.420 | 1.397941 / 0.230097 |
| att005 | integer fix (bias DELETED) | 1.138511 | 0.208533 | 5.460 | 1.159938 / 0.210448 |
| att006 | tower-common bias | 1.288407 | 0.227177 | 5.671 | 1.380606 / 0.230438 |
| att007 | fix + common bias | 1.104871 | 0.208474 | 5.300 | 1.187378 / 0.210284 |
| att008 | DD only | 1.585572 | 1.010705 | 1.569 | 1.649196 / 1.024780 |
| att009 | fix + DD (bias DELETED) | 1.439385 | 0.864258 | 1.665 | 1.235936 / 0.917092 |
| **att010** | **joint search, NOTHING deleted** | **1.036624** | **1.009287** | **1.027** | 0.954157 / 1.048386 |

The correction did NOT buy accuracy: att009 and att010 got worse on error by 16 % and
8.6 %. It moved att010's `err/sigma` from 0.910 to 1.027, from mildly conservative to
almost exactly consistent, and that is the whole of what it bought.

**`att011`, `att012` and `att013` are NOT in this table because they have not been
re-measured under the corrected `R`.** Their rows in `README_att_ladder.md` are pre-fix
numbers and are not comparable with the seven above.

Two findings from the first three mechanisms, separate virtues in separate rungs:

- **Accuracy** comes only from the absolute integer fix. `lambda*(dphi - N) =
  b_body' R' e` has no common-mode escape hatch, so the whole error becomes
  visible rather than the ~5 % differential part. att005 is the only rung whose
  sigma ever responded.
- **Honesty** comes only from the between-tower double difference. The
  inter-antenna bias was being absorbed into the calibration and counted as
  information, so the filter tightened on a constant it had merely fitted.
  Cancelling it algebraically raises the sigma to what the geometry actually
  supports. **The 0.2301 deg sigma quoted by every earlier attitude rung is not
  defensible.**

**att010 takes both virtues from one mechanism, with nothing deleted.** It is the
best error in the family and the only rung whose covariance is not lying.

## What was wired

`+revgnss/JointConstrainedAttitudeResolver.m` existed, complete, and was called
from nowhere. It is now called from `DiffAttitudeBuilder.buildRows`, which unlike
`finalize` has the towers, the lever arms and the position estimate it needs to
evaluate a candidate attitude.

- **Gate:** `cfg.estimator.diffAtt.jointConstrainedSearch.enable`, default OFF,
  declared next to the two existing diffAtt leaves in `masterConfig.m`.
  Parameters are read from `estimator.attitudeInit.search`.
- **One shot,** at the first post-calibration epoch that has rows. The ambiguity
  is constant per arc, so the integers only have to be found once.
- **The result is threaded through `store`,** not a persistent. `buildRows` gained
  a sixth output and the call site in `ReverseGNSSSimulation` captures it. A
  persistent would have carried the first run's integers into a second run in the
  same MATLAB session, and the store is what `ReportRunner` reads.
- **On acceptance the DD row form is forced on** and the row becomes
  `z = (z_t - z_p) - lambda*(N_t - N_p)` against `h = g_t - g_p`, pure geometry,
  with neither `delta_B` nor the modelled bias in it. The geometry-only single
  difference is tracked alongside in a new `rows_g` array for exactly this. Taking
  the integer DIFFERENCE makes the row independent of which tower pivots.
- **On refusal nothing changes** and the configured path runs untouched.

## The gate was measuring the wrong thing, and that is the substantive finding

First wiring refused: `rejectedJointRatio`, ratio 1.0012 against a 1.20 threshold.
Rather than assume, the cost surface was dumped and mapped.

The grid is over ATTITUDE. The runner-up candidate is an adjacent attitude half a
step away, and on this geometry it carries the SAME integers, so
`sorted(2)/sorted(1)` measured the CURVATURE of the cost surface in attitude, not
the separation between competing hypotheses.

Measured over the +/-2 deg window:

- **0 of 729 candidates** produced an integer set different from the winner's.
- **1 distinct integer set** in the entire window.
- First integer flip at **+22.0 / +35.5 / +44.5 deg** per axis. (The original
  5.4 deg estimate in the class docstring used the SD lever of 2 m; the search
  works on the DD lever of ~0.4 m, so the true flip distance is far larger.)

The old test refused a fix that was not merely unambiguous but maximally so. The
ratio now compares the winner against the best candidate carrying a DIFFERENT
integer set, which is what the resolver's own docstring always claimed it did.
When no such candidate exists the ratio is `Inf` and refusing is not available,
because there is nothing to confuse the winner with. `neighbourRatio`,
`integerUniqueOverWindow` and `nDistinctIntegerSets` are all reported.

## What the measurement changed about the story

- **The ~0.05 deg expectation in the original handoff was wrong by 19x**, and for a
  traceable reason: it used the SD lever arm (2 m) where the search works on the DD
  lever (2 m x |e_t - e_p| ~ 0.4 m). Measured DD attitude sensitivity is
  **1.1 / 5.4 / 1.7 mm per deg**, against **18 / 4.8 / 34.9 mm per deg** in the SD
  it replaces. The between-tower difference discards roughly 94 % of the signal,
  exactly as att008 predicted from the ~17 deg Earth subtense.
- **The winning attitude is not an attitude.** Against a one-epoch DD residual of
  0.076 cycles (14.5 mm) the winner is noise-placed; it landed on a grid CORNER.
  `euler_best` is recorded as a diagnostic and is deliberately NOT injected. The
  search delivers the INTEGERS; the EKF estimates attitude from the fixed rows.
- **The arc buys no averaging, and that is now the limit.** 19.1 mm post-fit DD
  residual over 12 rows at ~5 mm/deg is ~1 deg of single-epoch information, and the
  rung reports 1.009287 deg after 3601 epochs -- the single-epoch value,
  essentially unimproved. **This rung is not limited by the ambiguity**, which is now
  fixed and unique. (The covariance correction moved this from 1.048386 to 1.009287
  and did not change the reading.)

  What it IS limited by is not yet established, and one earlier guess here is now
  ruled out. The resolved gyro numbers are ARW `2e-4 rad/sqrt(s)`, bias RRW
  `3e-6 rad/s/sqrt(s)`, initial bias sigma `3e-5 rad/s` (realism grade doubles
  masterConfig's declared values). ARW alone is only **0.0115 deg per 1 s epoch**, and
  a random-walk-plus-measurement steady state of `sqrt(q*sigma_z) = sqrt(0.0115*1.0)`
  is ~0.107 deg, TEN TIMES BELOW the 1.009287 deg observed. So angle random walk does
  not explain it.

  The leading candidate is the **gyro BIAS**, not the gyro noise: `3e-5 rad/s`
  integrated over the arc is **6.19 deg** of attitude drift if unestimated, the filter
  carries three gyro-bias states to absorb it, and a DD observable worth 1-5 mm/deg is
  a weak lever for separating a slowly drifting bias from attitude itself. The
  competing candidate is time-correlation of the DD rows themselves, which would make
  N_eff over the arc far smaller than 3601. **Both are testable and neither is tested
  here.** The cheap discriminator is a gyro-grade rung against att010, changing truth
  and filter together so it stays a grade experiment and not a mismatch experiment.

## Verification performed

- Golden gate **5/5 PASS** with the leaf at its default OFF: `smoke` x
  `single`, `headline`, `realism`, `feat024`, `correlated`, all reporting
  "Stage-85 numbers unchanged vs frozen golden".
- **att004 re-run on this tree**: 1.39794054 deg / 0.23009746 deg, matching the
  `bdbeaed` figures to eight figures, so the att010 comparison is like-for-like
  rather than quoted.
- Position metrics **byte-identical** between att004 and att010 (2.105 m final,
  4.528 m RMS, 1.523 m last-20 %), as they must be for attitude-only rows.
- Liveness, not just gate-on: `jointRigidBodyFixed`, `diffAttMeanNRows` 12.0 and
  `diffAttRejectedRows` 0 across the whole arc, so the integer-fixed rows carried
  every epoch and not just the first.

### Re-verified after the covariance correction (2026-08-14)

- Golden gate **5/5 PASS before and 5/5 PASS after**, same five smoke scenarios.
  The DD leaf is default OFF, so the goldens are the control, and they held.
- **The before column is like-for-like, not quoted.** att008 re-run on the pre-fix
  tree through the same extraction reproduced `1.649196` / `1.024780` to all six
  decimals, which also confirms the tree state is the one those numbers came from.
- Liveness re-confirmed in a FRESH process per rung, because the announcement is
  `persistent` and a batched session prints it for the first rung only (open defect
  6): `TOWER DD APPLIED: 3 groups, pivot tower 1, 0 rows dropped, 12 DD rows (was
  15 SD rows)`. That row set is the fully-populated one the closed form covers.
- att004-att010 were ALL re-run, not only the three DD rungs. The SD fallback `R`
  was wrong too, so the whole family moved, and publishing corrected rows beside
  stale ones would have mixed two measurement configs in one table.
- **att011, att012 and att013 have NOT been re-measured under the corrected `R`.**
  They post-date this work and their rows in the ladder table are pre-fix numbers.

## The DD R assembly was structurally incomplete (PRE-EXISTING, FIXED 2026-08-14)

Found by adversarial review of this change and confirmed by reading the code. It was
**not** introduced by that change: `blocks{end+1} = R_row*(eye(m)+ones(m))`, the
`blkdiag` across groups, and the SD fallback `R_row*eye` were all unchanged lines
inherited from the `towerDoubleDifference` path, so **it affected att008 and att009 as
much as att010**, and the SD fallback affected every diffAtt rung in the family.

### The defect

Every baseline at a tower is single-differenced against the SAME reference antenna
(`refMask = antennaIdx==1` is computed once per tower, outside the baseline loop). So
with `phi_{t,a}` iid of variance `sigma^2` and
`d_{t,b} = phi_{t,b+1} - phi_{t,1} - phi_{p,b+1} + phi_{p,1}`, the exact covariance is

```
Cov(d_{t,b}, d_{t',b'}) = sigma^2 * (delta_bb' + 1) * (delta_tt' + 1)
```

i.e. in the fully-populated case `R_true = sigma^2 * (I_nB + J_nB) kron (I_m + J_m)`.
The code built `2*sigma^2 * I_nB kron (I_m + J_m)`: correct on the diagonal
(`4 sigma^2`) and correct within a baseline group (`2 sigma^2`), but **exactly zero**
where the truth is `2 sigma^2` (same tower, different baseline) and `sigma^2`
(different tower, different baseline). `(I3+J3)` has eigenvalues `{4,1,1}` and the code
substituted `2` for all three, so the DD combination COMMON to all three baselines was
charged half its true variance.

### The fix

`blkdiag` of per-group blocks cannot represent a covariance that reaches ACROSS groups,
so the block form was replaced rather than patched. Each row is now written in terms of
the raw phases it is actually built from, and the covariance is one Gram product over
the whole stack:

- `sdCoefficients_(rows_key, rows_sig, nTowers, nBaselines)` returns `C` with a `+1` on
  `(t, b+1, s)` and a `-1` on `(t, 1, sref)` per single-differenced row.
- `gramCovariance_(C, sigma_phi)` returns `sigma_phi^2 * C*C'`, symmetrised.
- The DD path accumulates the differencing map `D_dd` alongside the rows it differences,
  using the SAME pivot choices, and takes `gramCovariance_(D_dd*C, sigma_phi)`.
- The SD fallback takes `gramCovariance_(C, sigma_phi)` directly, which is NOT diagonal:
  rows on one tower and signal covary by `sigma_phi^2` through the shared reference.

This is exact for any row set, which the block form could not be: towers or baselines
missing, groups pivoting on DIFFERENT towers (the pivot is the first row present, so an
absent tower on one baseline moves that group's pivot and not the others'), and L1 and
L2 rows mixed in one stack. A `rows_sig` column pair records the signal actually read
for the row and for its reference rather than assuming the two agree, so the
shared-reference correlation is keyed off the real observable.

### Positive definiteness is structural, not hoped for

Column `(t, b+1, s)` appears in exactly ONE row of `C`, and after between-tower
differencing it still appears in exactly one row of `D_dd*C`, because a group's pivot is
by construction not among its own differenced towers. Every row therefore owns a column
in which it is the only nonzero, no row is a combination of the others, `C` has full row
rank, and `sigma_phi^2 * C*C'` is SPD.

Verified rather than argued, over **all 32767 non-empty subsets** of the 15-row golden
stack (5 towers x 3 baselines), 32552 of which produce DD rows: the worst minimum
eigenvalue is exactly `1.000000 * sigma_phi^2` for both the SD and the DD assembly, zero
non-SPD cases, nothing approaching zero. On the fully-populated set the assembled `R`
reproduces `sigma^2 (I_3+J_3) kron (I_4+J_4)` to `0.000e+00`, and a 400000-sample Monte
Carlo over rows formed from the raw definition agrees with the assembled `R` to 0.4 %
and with the OLD `R` to only 50 %. The live ladder row set IS that fully-populated one:
`TOWER DD APPLIED: 3 groups, pivot tower 1, 0 rows dropped, 12 DD rows (was 15 SD rows)`.

### Two things not to over-read, both still true after the fix

- **The DD rows do not enter any reported NIS.** `ekf.update(z_da,h_da,H_da,R_da)` is
  called with all outputs discarded, and the observable-stack adapter attaches no R and
  no NIS, so the covariance-consistency table in the run summary describes the main
  measurement stack only. There is no "inflated DD NIS" symptom to look for, before or
  after. The update itself DOES apply: `ReverseGNSSEKF` is a `handle`, so discarding the
  return value costs the diagnostic, not the correction.
- **The aggregate effect is not a simple `sqrt(2)` on the reported sigma.**
  `tr(R_code^-1 R_true) = 12.000000`, exactly the row count, so a scalar consistency
  check is blind to this. Per direction, `eig(R_code^-1 R_true)` is `2.00` on four
  eigendirections and `0.50` on the other eight: the old `R` charged HALF the true
  variance on four of them and TWICE on the other eight, and the two errors cancel
  exactly in the trace. The `sqrt(2)` is real but lives ONLY on the direction common to
  every baseline and tower, where the true sigma is `sqrt(20)*sigma_phi = 44.7 mm`
  against the `sqrt(10)*sigma_phi = 31.6 mm` the old assembly assigned.

### The SCALE of R is untouched by this, and is NOT a defect

The structural fix leaves `trace(R)` unchanged, so the expected residual RMS is
unchanged at `2*sigma_phi`. Nothing here moves the scale, and nothing needed to.

**Do not re-open this on the `sigma_phi = 0.005` reading.** That is the retracted claim
in open defect 4 below, and it keeps coming back because `masterConfig.m:3210` really
does say `0.005`. The attitude family does not use that value:
`golden_baseline_attitude.json:183` sets `"carrier": {"sigma_m": 0.010}`, and every att
rung inherits it through `att001 -> golden_baseline_attitude.json`. So the assigned DD
sigma is `2*sigma_phi = 20 mm`, against a measured one-epoch DD residual of 14.5 mm and
a post-fit arc residual of 19.1 mm. Both sit BELOW the assigned sigma: **R is mildly
conservative in scale, not optimistic.** The "1.45x optimistic" figure is what you get
by pairing the measured residual with the masterConfig 5 mm the family overrides, and it
has been wrong every time it has been quoted.

**What this fix does NOT cover, and att012 proves it matters more.** The Gram assembly
takes the raw phases as iid. `att012` ships receive-end carrier multipath, which is
neither white nor independent in time, and reports the error 13.8x worse with the sigma
unmoved. That is an R CONTENT defect sitting on top of the structural one this section
fixes, and it is the larger of the two. "R is structurally correct" must not be read as
"R is correct".

## Open defects, found and not fixed

1. **`BaselineCarrierAmbiguityResolver.m:265`** -- a catch-all `else` emits
   `'rejectedRms'` when NO named gate failed. 10/15 baselines carry that label
   while their own recorded `rmsBest` (<= 0.0349) is far below the 0.10
   threshold, so the label is wrong and the real failure is on the L2 branch.
   **The 5/15 fix count is probably an undercount.**
2. **`daInfo` is never persisted.** `buildRows` writes it into
   `errStruct.diffAttRows`, which is consumed in-epoch. The joint result is now
   readable because it lives in `store` instead, but the joint fields are still
   NOT plumbed into `summary` in `ReportRunner`, so they cannot be read from the
   output `.mat` without re-running. One-shot log lines cover it meanwhile.
3. **The phase-bias gate refuses on a status string, never on magnitude**
   (`BaselineCarrierAmbiguityResolver.m:118-119`). The joint search makes this
   gate unnecessary for its own path.
4. **R's SCALE on the DD rows is fine, and an earlier claim here that it was 1.45x
   optimistic was WRONG.** That claim assumed `sigma_phi = 0.005` from masterConfig.
   The attitude family resolves `measurements.carrier.sigma_m` to **0.010 m**, which
   `golden_baseline_attitude.json` budgets deliberately to cover wind-up, carrier
   multipath and the PCV calibration residual. So the assigned DD sigma is
   `2*sigma_phi = 20 mm = 0.105101 cycles`, against a measured one-epoch DD residual
   of 14.5 mm and a post-fit arc residual of 19.1 mm. R is mildly CONSERVATIVE in
   scale, not optimistic. The structural defect above is unaffected by this and
   was real; it is now fixed. **This retraction has had to be made more than once.**
   Anyone re-deriving the DD noise MUST resolve `measurements.carrier.sigma_m`
   through the att chain rather than read `masterConfig.m:3210`, which says 0.005
   and is overridden to 0.010 by `golden_baseline_attitude.json:183`.
6. **The DD liveness announcement fires once per MATLAB PROCESS, not per run.**
   `ddAnnounced_` in `DiffAttitudeBuilder.buildRows` is `persistent`, so running
   several rungs in one `matlab -batch` session prints
   `[DiffAtt] TOWER DD APPLIED` for the FIRST rung only. The absence of the line
   for later rungs in a batch log says NOTHING about whether their DD path ran.
   This defeats the purpose of the line, which was added precisely to separate
   "gate on" from "transform applied". Verify liveness with one rung per process
   until this is keyed on the run rather than the process.
7. **The attitude error is not in the summary at all.**
   `singleAssetAttitudeErrorNorm_deg` and every `stage60*` attitude field are
   gated on `scenario.name == 'singleAssetCarrierAttitude'`, which NO att rung
   sets, so all of them are `NaN` in every att output `.mat`. The ladder table's
   `error deg` column is recomputed with stage 60's own formula,
   `norm(atan2d(sind(est-tru), cosd(est-tru)))`, over the stored final euler.
   `finalAttitudeSigma_deg` is populated normally and needs no such treatment.
5. **The acceptance gates were structurally unable to refuse, and this was fixed.**
   The cost is a ROUNDED residual, bounded to [-0.5, 0.5] by construction, so pure
   noise already sits at `1/sqrt(12) = 0.2887` cycles and the inherited 0.30-cycle
   threshold could not refuse random data. Paired with a ratio that is correctly
   `+Inf` whenever the integer set is unique over the window -- the normal case at
   GEO -- acceptance was unconditional. The gate now scales with the expected DD
   noise, keeping 0.30 as an outer bound only. The gate is on the SAMPLING
   DISTRIBUTION of the RMS statistic, `s*(1 + k/sqrt(2n))`, not on `k*s`: the first
   attempt used `k*s` and did NOT bind, because with `s = 0.1051` cycles it landed at
   0.3153, above the 0.30 outer bound, so `min()` handed back 0.30 and the gate stayed
   inert. It was caught because the log line prints the operative gate. Measured:
   n = 12, gate 0.1695, winner 0.076065 = 0.72 s. **Anyone tempted to re-introduce a fixed cycle threshold
   on a rounded residual should read this entry first.**

## Standing caveats for anything quoted from this family

- **Phase wind-up is not modelled anywhere in this simulation**, and an integer
  fix is exactly the operation a slow unmodelled carrier-phase rotation corrupts.
  It does NOT cancel in a between-tower DD, because the tower-to-satellite
  geometry differs per tower. Every fix here is optimistic.
- **att005, att007 and att009 delete the inter-antenna bias.** They are
  diagnostics. They are not system performance figures. att010 deletes nothing.
- **The one-shot fix carries no redundancy.** It rides on one epoch of phase, has
  no arc averaging in it, and is not re-searched after a cycle slip. The ratio
  gate also cannot protect against a badly wrong attitude prior: with one integer
  hypothesis in the window there is nothing to refuse against, so a prior wrong by
  tens of degrees would fix the wrong set silently. The prior here is wrong by
  ~1.5 deg against flip distances of 22 to 44.5 deg, a 15x margin, but a margin
  is not a guarantee.
- The third attitude axis is geometrically weak by roughly `1/sin(10 deg) ~ 6` and
  no amount of integer work changes that. Only a commanded slew (the bias is fixed
  in the BODY frame while attitude is not) or a long enough arc for GEO libration
  breaks it.
