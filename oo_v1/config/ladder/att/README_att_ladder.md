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

| rung | mechanism | error deg | sigma deg | err/sigma |
|---|---|---|---|---|
| att004 | baseline, AR policy-blocked | 1.397941 | 0.230097 | 6.08 |
| att005 | integer fix (bias DELETED) | 1.159938 | 0.210448 | 5.51 |
| att006 | tower-common bias | 1.380606 | 0.230438 | 5.99 |
| att007 | fix + common bias | 1.187378 | 0.210284 | 5.65 |
| att008 | DD only | 1.649196 | 1.024780 | 1.609 |
| att009 | fix + DD | 1.235936 | 0.917092 | 1.348 |
| **att010** | **joint search, NOTHING deleted** | **0.954157** | **1.048386** | **0.910** |
| **att011** | **att010 + space-grade FOG gyro** | **0.182352** | **0.207983** | **0.877** |

`att010` is the only rung that is both the best in the family on error and honest on
covariance, and the only one that achieves it without deleting a real hardware effect.
`att005`, `att007` and `att009` delete the inter-antenna bias: they are diagnostics, not
system performance figures.

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
  only those survive an inter-antenna difference. In order: carrier multipath is
  ABSENT (no multipath term in `CarrierMeasurementBuilder`, `coloredGM.carrierScale`
  still reserved) and is the dominant real error source for GNSS attitude arrays;
  antenna PCV cancels between truth and model, so a PERFECTLY CALIBRATED array is
  assumed and the ~5 mm real residual is never injected; the inter-antenna bias is
  assumed calibrated to 0.02 cycles and perfectly static; and in att011 the filter
  knows the gyro exactly, so scale factor, misalignment and g-sensitivity are absent.
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
