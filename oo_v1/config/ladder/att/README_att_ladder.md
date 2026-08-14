# att ladder: can reverse-GNSS carrier phase determine attitude at GEO on its own?

Without a star tracker, and without idealising the antenna hardware.

Every rung is one toggle against its `_extends` parent. `att001` is the entry point:
it takes `golden_baseline_attitude.json` and switches the star tracker OFF, so attitude
is carried by the differenced carrier and gyro propagation alone.

## These rungs used to live on the feat axis

They were `feat025`-`feat034` until 2026-08-14. Anything written before that date, and
commit `bdbeaed` in particular, names them by the old numbers:

| was | now | mechanism |
|---|---|---|
| feat025 | att001 | star tracker off, differenced-carrier attitude, gyro propagation |
| feat026 | att002 | carrier only |
| feat027 | att003 | coarse attitude candidate search |
| feat028 | att004 | per-baseline integer AR enabled (policy-blocked in practice) |
| feat029 | att005 | integer fix with the inter-antenna bias DELETED |
| feat030 | att006 | tower-common bias constraint |
| feat031 | att007 | tower-common bias + bias DELETED |
| feat032 | att008 | between-tower double difference |
| feat033 | att009 | integer fix + DD, bias DELETED |
| feat034 | att010 | joint rigid-body integer/attitude search, nothing deleted |

## Measured, 3600 s, GEO, 5 towers, 4 antennas

**Mixed measurement configs. Read this before comparing rows.** `att004`-`att010` were
re-measured 2026-08-14 after the differenced-carrier measurement covariance was
corrected (see "The covariance correction" below). `att011`-`att015` are PRE-correction
numbers and have not been re-run, so a comparison ACROSS that boundary is not
like-for-like. Within each block it is.

| rung | mechanism | error deg | sigma deg | err/sigma |
|---|---|---|---|---|
| att004 | baseline, AR policy-blocked | 1.460038 | 0.227421 | 6.420 |
| att005 | integer fix (bias DELETED) | 1.138511 | 0.208533 | 5.460 |
| att006 | tower-common bias | 1.288407 | 0.227177 | 5.671 |
| att007 | fix + common bias | 1.104871 | 0.208474 | 5.300 |
| att008 | DD only | 1.585572 | 1.010705 | 1.569 |
| att009 | fix + DD | 1.439385 | 0.864258 | 1.665 |
| **att010** | **joint search, NOTHING deleted** | **1.036624** | **1.009287** | **1.027** |
| **att011** | **att010 + space-grade FOG gyro** | **0.182352** | **0.207983** | **0.877** |
| **att012** | **att011 + 3 mm receive-end multipath** | **2.522981** | **0.199447** | **12.65** |
| att013 | att012 at 20 mm (stress bound, fix REFUSED, float) | 5.987894 | 0.027734 | 215.90 |
| **att014** | **att012 with the joint fix FORCED OFF (float, 3 mm)** | **1.173890** | **0.027675** | **42.42** |
| **att015** | **att011 with the joint fix FORCED OFF (float, clean)** | **1.336773** | **0.027654** | **48.34** |

`att011`-`att015` were cut directly on the att axis and never lived on `feat`, so they do
not appear in the rename table above.

### The covariance correction (2026-08-14)

The single- and double-differenced attitude rows share raw phases: every baseline at a
tower is differenced against the SAME reference antenna. The shipped `R` charged that
correlation as zero across baseline groups, because `blkdiag` of per-group blocks cannot
represent a covariance that reaches between groups. Replaced by a Gram assembly over the
whole stack, exact for any row set. Derivation, SPD proof and verification are in
`docs/handoff_joint_constrained_attitude.md`.

| rung | error before -> after | sigma before -> after | err/sigma before -> after |
|---|---|---|---|
| att004 | 1.397941 -> 1.460038 | 0.230097 -> 0.227421 | 6.075 -> 6.420 |
| att005 | 1.159938 -> 1.138511 | 0.210448 -> 0.208533 | 5.512 -> 5.460 |
| att006 | 1.380606 -> 1.288407 | 0.230438 -> 0.227177 | 5.991 -> 5.671 |
| att007 | 1.187378 -> 1.104871 | 0.210284 -> 0.208474 | 5.647 -> 5.300 |
| att008 | 1.649196 -> 1.585572 | 1.024780 -> 1.010705 | 1.609 -> 1.569 |
| att009 | 1.235936 -> 1.439385 | 0.917092 -> 0.864258 | 1.348 -> 1.665 |
| **att010** | 0.954157 -> **1.036624** | 1.048386 -> **1.009287** | 0.910 -> **1.027** |

Read this honestly: **correcting the covariance did not buy accuracy.** att009 and
att010 got WORSE on error, by 16 % and 8.6 %. Sigma tightened slightly on all seven,
which is the expected direction: the fix charges four eigendirections twice the variance
they had and the other eight half, and the net over this geometry is a slightly tighter
filter. What it bought is that the number is now the covariance of the rows actually
being formed. att010's `err/sigma` moving 0.910 -> 1.027 is the whole result.

The before column is like-for-like, not quoted: att008 was re-run on the pre-fix tree
through the same extraction and reproduced `1.649196` / `1.024780` to all six decimals.

**This does NOT make `R` correct, and att012 is the proof.** The assembly takes the raw
phases as iid. att012's receive-end multipath is neither white nor independent in time,
and it degrades attitude 13.8x with the sigma unmoved. That is an `R` CONTENT defect on
top of the structural one, and it is the larger of the two.

**Provenance of `error deg`.** It is NOT in the run summary:
`singleAssetAttitudeErrorNorm_deg` and the `stage60*` fields are gated on
`scenario.name == 'singleAssetCarrierAttitude'`, which no att rung sets, so all of them
are `NaN`. The value is stage 60's own formula applied to the stored final euler,
`norm(atan2d(sind(est-tru), cosd(est-tru)))`. `sigma deg` is
`summary.finalAttitudeSigma_deg`, which is populated normally.

Row form is the discriminator throughout, and it is recorded in every `.mat` as
`diffAttMeanNRows`: **12** is the integer-fixed between-tower double difference, **15** is
the float inter-antenna single difference. att010, att011 and att012 run at 12. att013,
att014 and att015 run at 15. For att014 and att015 that is the liveness proof their own
configs demand. For att013 it is a RESULT: nothing was toggled there, the joint search
refused at 20 mm and the solution fell back to the float path on its own.

**att012 is the honesty rung and it breaks the family.** 3 mm of quasi-static
per-antenna carrier multipath, at the repo's OWN declared 1/100 code-to-carrier scale
rather than any borrowed terrestrial figure (see the multipath section below on why
Kaplan's 2 cm does not apply at the spacecraft end), degrades attitude 13.8x while the
sigma does not move. The final 2.523 deg is ABOVE the 1.500 deg initial error, i.e. the filter
ended further from truth than its own prior. The DD residual rises only 1.041x, so the
damage is nearly invisible in residual RMS: no residual monitor would catch it.

**That invisibility is specific to the realistic level, which is what makes it dangerous.**
At att013's 20 mm the same failure IS catchable, with arc carrier NIS per dof 2.9712 against
a 0.9738 baseline, overall NIS/dof 1.2472 against ~0.87 everywhere else, and a DD residual
of 40.8 mm against 19.9 mm. So monitoring catches the stress case and misses the expected
one. Do not read att013 as evidence that this failure announces itself.

**Why, and this is the finding.** On the FLOAT rungs (att004-att009) `delta_B` is a free
REAL per (tower, baseline) and absorbs antenna-specific quasi-static offsets. Once the
joint fix is accepted the rows become `dz = (z_t - z_p) - lambda*(N_t - N_p)` against
pure geometry, with the Jacobian filling ONLY the attitude columns: no ambiguity, bias
or clock column survives. **The integer fix removes the absorber.** The mechanism that
buys att010/att011 their accuracy under a clean error model is the same one that makes
them fragile under a realistic one. This also disposes of the objection that the result
turns on an undefended correlation time: a perfectly static offset is no more absorbable
than a drifting one on that path.

`att010` is the only rung that is both the best in the family on error and honest on
covariance, and the only one that achieves it without deleting a real hardware effect.
`att005`, `att007` and `att009` delete the inter-antenna bias: they are diagnostics, not
system performance figures.

## att014 and att015 close the 2x2, and the absorber claim survives it

The paragraph above was an argument from row construction. `att014` and `att015` force the
joint fix OFF at both multipath levels, which makes it a measurement:

| | fix ON | fix OFF | fix effect |
|---|---|---|---|
| clean | att011 **0.182352** | att015 **1.336773** | **7.33x, the fix HELPS** |
| 3 mm multipath | att012 **2.522981** | att014 **1.173890** | **0.47x, the fix HURTS** |

**The sign of the fix effect flips with multipath**, which is exactly what "the integer fix
removes the absorber" predicts and is stronger evidence than either column alone. With
nothing to absorb, the fix is worth 7.33x. With 3 mm of per-antenna offset available for
`delta_B` to soak up, taking that freedom away costs 2.15x.

**The float path is not the answer either, and its failure mode is worse.** Its sigma does
not respond to its error at all: 0.027654, 0.027675 and 0.027734 deg across att015, att014
and att013 while the error moves 1.336773, 1.173890 and 5.987894 deg, giving err/sigma of
48, 42 and 216. It is structurally overconfident at EVERY multipath level including zero,
because with the FOG gyro there is no process-noise floor and the sigma simply decays as
`1/sqrt(N)`. att004's 0.230097 deg sigma is what that same path looks like when the MEMS
gyro still floors it.

**Best case across the whole family under any non-zero multipath is att014's 1.173890 deg**,
which beats the 1.500 deg prior by only 1.28x and carries a sigma 42x too small. Against a
30 arcsec star tracker's measured 0.016542 deg that is a factor of 71.

Two smaller points from these rungs. Error on the float path scales close to linearly with
amplitude once multipath dominates, 5.10x of error for 6.67x of amplitude between att014 and
att013. And at 3 mm it does NOT yet dominate: att015 (clean) is marginally WORSE than att014
(3 mm), which at one seed says the frozen 60 s `delta_B` calibration is still the larger term
there. Do not read that ordering as multipath helping.

## Is multipath a real factor for reverse GNSS? Yes, but not the part you would expect

The question has to be split by END OF THE LINK, because the two ends have opposite
consequences for attitude.

**Transmit end (the ground towers) — certainly real, probably the largest multipath
term in the link, and it contributes NOTHING to attitude.** The towers are ground GNSS
transmitters with ground bounce, elevation dependent. `coloredGM` already models it at
0.30 m code with a 1/sin(el) envelope keyed on tower elevation. But it is COMMON to all
four spacecraft phase centres, so it cancels identically in the inter-antenna single
difference this ladder is built on. That is exactly why `golden_baseline.json` sets its
`sharedAcrossAntennas` gate true, having measured that a per-antenna draw handed a
4-antenna run a free `sqrt(4)`. The certainly-real, certainly-large multipath is
precisely the one that cannot touch attitude.

**Receive end (the spacecraft structure) — the only one that reaches attitude, and it
is millimetre-class, not centimetre-class.** Three reasons it is far smaller than the
terrestrial case: no ground plane and no terrain, so the dominant terrestrial reflector
is absent; RHCP-to-LHCP polarisation flip on a single specular reflection, which an RHCP
antenna rejects by roughly 10-20 dB, putting a reflected ray at ~10-30 % amplitude
before anything else; and antenna pattern roll-off at the large off-boresight angles
structural reflections arrive from. Against that, it is not zero: for a nadir-pointing
GEO communications satellite the signal arrives from nadir and the nadir face is exactly
where the large Earth-coverage reflectors and feeds sit.

**So att012's 3 mm is the physically relevant rung and att013's 20 mm is a stress
bound.** att013 was originally cut as "Kaplan multipath" on the argument that 2 cm is
the benign-environment literature value. That was a CATEGORY ERROR: Kaplan's 2 cm is a
GROUND RECEIVER figure and does not bound a spacecraft antenna. It is retained at 20 mm
because the gate result it produced is worth having, not because it is expected.

**Caveat on both.** There is NO receive-antenna gain pattern and NO polarisation model
anywhere on the ground-to-spacecraft link (only the ISL link has one), so the injected
term is free-standing: nothing in the modelled physics attenuates a structural
reflection or constrains its amplitude. 3 mm and 20 mm are ASSUMED levels, not derived
ones. Quote them as assumptions.

## Read these before quoting any number above

- **The 0.230097 deg sigma that att004, att006 and every pre-2026-08-14 attitude rung
  quotes is not defensible.** The inter-antenna bias was being absorbed into the
  calibration and counted as information, so the filter tightened on a constant it had
  merely fitted. Only the between-tower DD (att008 onward) raises the sigma to what the
  geometry actually supports.
- **Phase wind-up is not modelled, but the received caveat about it was WRONG for this
  observable and is corrected as of att011.** Wind-up is a function of antenna
  ORIENTATION about the line of sight, not position. The observable here is the
  INTER-ANTENNA single difference at one tower: the transmitter term is the same tower
  antenna in both and cancels exactly, and the receiver term is common to all four
  spacecraft antennas, which the config makes co-oriented by construction (lever-arm
  positions only, one spacecraft-level `boresight_body`). A term identical on both
  antennas cancels in the difference. The old claim, that wind-up survives a
  between-tower DD, is true of UNDIFFERENCED observables and was carried over without
  being re-derived. The real residual is array non-ideality (imperfect co-orientation,
  per-antenna polarisation differences), which is smaller than the caveat implied.
- **What actually makes these rungs optimistic** is the ANTENNA-SPECIFIC effects, since
  only those survive an inter-antenna difference. In order: carrier multipath is the
  dominant real error source for GNSS attitude arrays and was ABSENT until `att012`
  implemented `errors.multipath.receiveEnd` (this bullet previously read "absent, no
  multipath term in `CarrierMeasurementBuilder`" and is now correct only for
  `att000`-`att011` and `att015`, which run with it off); antenna PCV cancels between
  truth and model, so a PERFECTLY CALIBRATED array is assumed and the ~5 mm real
  residual is never injected; the inter-antenna bias is assumed calibrated to 0.02
  cycles and perfectly static; and from att011 on the filter knows the gyro exactly, so
  scale factor, misalignment and g-sensitivity are absent.
- **att010's accuracy does not come from the DD being sensitive.** Measured DD attitude
  sensitivity is 1.1 / 5.4 / 1.7 mm per degree, against 18 / 4.8 / 34.9 mm per degree in
  the single difference it replaces: the between-tower difference discards roughly 94 %
  of the signal, as att008 predicted from the ~17 deg Earth subtense. The gain comes from
  the ambiguity being an INTEGER fixed under the rigid-body constraint rather than a
  float absorbed from the wrong prior attitude.
- **The final sigma equals the single-epoch information content.** 19.1 mm post-fit DD
  residual over 12 rows at ~5 mm/deg is ~1 deg, and att010 reports 1.048386 deg after
  3600 epochs. The arc buys no accumulation, because gyro process noise re-inflates
  attitude between updates as fast as the rows shrink it.
- **The third axis is geometrically weak** by roughly `1/sin(10 deg) ~ 6` and no integer
  work changes that. Only a commanded slew (the bias is fixed in the BODY frame while
  attitude is not) or an arc long enough for GEO libration breaks it.
