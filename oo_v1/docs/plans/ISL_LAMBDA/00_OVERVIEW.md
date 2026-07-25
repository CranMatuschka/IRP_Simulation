# ISL + LAMBDA Feature Set — Overview, Readiness & Workflow

**Branch:** `feature/ISL-LAMBDA` (from `main`, synced with `origin/main`).
**Scope:** planning only. No implementation in this pass.
**Author role:** GNSS + Kalman-filter engineering. Every claim below is checked against the code
(file:line) or the TU Delft LAMBDA 4.0 papers, not asserted from memory.

This is the index for four plan documents:

| # | File | Topic |
|---|---|---|
| 00 | `00_OVERVIEW.md` | This file: readiness verdict, LAMBDA-vs-TWSTFT science, toolbox evaluation, model-switch workflow |
| 01 | `01_GENERALIZED_AMBIGUITY_STATES.md` | Reuse ground carrier-ambiguity states for ISL, generalised so other links can use them |
| 02 | `02_ISL_LIGHTTIME_DOPPLER.md` | Bring ISL light-time + Doppler into the carrier/ambiguity path consistently |
| 03 | `03_LAMBDA_INTEGER_RESOLUTION.md` | LAMBDA/MLAMBDA integer AR for ISL **and** ground; the TWSTFT relationship |

It supersedes the earlier single-topic `docs/isl_carrier_ambiguity_plan_B.md` (that file remains as the
float-only precursor; document 01 here is the generalised version).

---

## 1. The one finding that governs everything

**The existing "float ambiguity" is NOT a clean integer — it absorbs biases.**

`+models/+measurements/CarrierMeasurementBuilder.m:280` states it directly:

> *"Float ambiguity B_est absorbs constant clock bias per arc."*

The undifferenced carrier row (`:245`, `:263`) is
`z = ρ + b_rx − b_twr + trop − iono + B_true + …`, and the estimator lumps the **constant part of
the receiver clock, tower clock, and hardware phase biases** into the per-arc float ambiguity `B`.
That is correct EKF practice (it keeps carrier at ~5 mm instead of degrading to code level), **but it
means `B` is `integer·λ + real-valued-bias`, i.e. it does not live on an integer grid.**

**Consequence for LAMBDA:** LAMBDA/MLAMBDA finds the integer vector nearest to a float vector *under
the assumption the truth is an integer*. Feeding it the current undifferenced `B` would "fix" it to a
meaningless integer and inject a bias-sized error. **LAMBDA cannot be bolted onto the undifferenced
states as they stand.** Getting to integers requires one of two classical routes (document 03):

- **(A) Differencing** — between-antenna (single-diff, cancels both clocks → clean integer; this is
  the *only* integer-ready structure in the codebase today, via
  `+revgnss/DiffAttitudeBuilder.m` / `BaselineCarrierAmbiguityResolver`), or between-satellite/
  between-tower double-differencing.
- **(B) Bias calibration** — remove the clocks with two-way time transfer
  (`+revgnss/TwoWayTimeTransferBuilder.m`, already exists) **and** supply calibrated carrier phase
  biases (FCB/UPD). This is PPP-AR; the phase-bias products do **not** exist in the codebase.

This is the honest headline. The rest of the readiness picture is genuinely good.

---

## 2. Codebase readiness — component by component

| Capability LAMBDA/ISL needs | Status | Evidence |
|---|---|---|
| Float ambiguity **states** in the EKF (metres) | ✅ exists | `ReverseGNSSEKF.m:135-153, 653-686` |
| Float ambiguity + variance **extraction** from `x`, `P` | ✅ exists (diagonal only) | `IntegerAmbiguityFixer.m:126-131` |
| **Full** ambiguity covariance block `Qa = P(amb,amb)` for ILS | ⚠️ trivially available, **not yet assembled** | `ekf.P` is full; only diagonal used today |
| Cycle-domain covariance transform (metres→cycles, WL/NL) | ✅ exists | `WideLaneNarrowLaneDiagnostics.m` (`P_N = D·P_pair·D'`) |
| Cycle-slip detection + arc IDs + covariance reset | ✅ exists | `CarrierTrackManager.m`, `ReverseGNSSEKF.m:1076-1114` |
| **Integer-valued** ambiguities (prerequisite for AR) | ❌ only for between-antenna DD | `CarrierMeasurementBuilder.m:280`; `DiffAttitudeBuilder.m:4-11` |
| A proper ILS/LAMBDA search | ❌ ad-hoc only | `IntegerAmbiguityFixer` = rounding+ratio; `BaselineCarrierAmbiguityResolver` = raw search |
| ISL carrier row in the EKF | ❌ hard-blocked | `ISLMeasurementBuilder.m:73-76, 191-193` |
| ISL light-time correction | ✅ exists, gated off | `ISLMeasurementBuilder.m:278, 304-323` (Orekit-validated sub-mm) |
| ISL Doppler (range-rate) row | ✅ exists | `ISLMeasurementBuilder.m:165-190` |
| Two-way time transfer (clock calibration) | ✅ exists | `TwoWayTimeTransferBuilder.m` |
| A place to hold ISL ambiguity states | ❌ no link dimension | indices are `(tower, receiver, signal)` only |

**Verdict:** the codebase is **~70 % of the way to float-carrier ISL** and **~40 % of the way to
integer AR**. The float scaffolding is strong and re-usable; the two genuine gaps are (i) a *link*
dimension for ISL ambiguity states (document 01), and (ii) an *integer-valued* parametrisation
(differenced or bias-calibrated) plus a real ILS engine (document 03). Nothing here is blocked by a
missing theory — it is all engineering with known recipes.

---

## 3. Is this "actually" worth doing? (critical answer)

**Yes, with a scoped ambition.** The realistic payoff ladder:

1. **Float ISL carrier** (docs 01+02): code-level (0.3 m) → **decimetre** ISL. Low science risk.
2. **Integer AR on differenced links** (doc 03, route A): decimetre → **millimetre** for the
   *observable* quantity — attitude (between-antenna DD, already integer-ready) and swarm *relative*
   shape (between-satellite DD). High value, medium risk.
3. **Integer AR on absolute ground position** (doc 03): **not classically achievable** with a single
   spacecraft receiver — you cannot double-difference with one receiver, and the sim has no phase-bias
   products. This needs TWSTFT clock calibration **plus** an FCB/UPD product to attempt PPP-AR, and
   even then absolute AR from a nadir cone is weak (the radial↔clock wall documented in
   `TwoWayTimeTransferBuilder.m`). **Be honest in the thesis: LAMBDA sharpens *relative/shape* and
   *attitude*, not single-receiver *absolute* position.**

If someone (including ChatGPT) implies "add LAMBDA and the absolute GEO position goes to mm," that is
wrong for this geometry. The win is real but it is in attitude and relative/shape.

---

## 4. LAMBDA vs TWSTFT — the science (this is a frequent point of confusion)

**They are complementary, not alternatives. They solve different unknowns, and TWSTFT can be the
*enabler* that makes LAMBDA feasible.**

- **TWSTFT / two-way time transfer** cancels the range by reciprocity and isolates the **clock
  difference** `b_rx − b_twr` (`TwoWayTimeTransferBuilder.m:20-33`). Its product is **time/clock**.
- **LAMBDA** fixes the carrier **integer ambiguity**, whose product is a **millimetre range** →
  geometry / position / shape / attitude.
- The link between them: the undifferenced ambiguity is only non-integer because it absorbs the
  **clock** (and hardware) bias (§1). **Two-way time transfer removes the clock unknown**, which is
  exactly the contaminant standing between the float ambiguity and an integer. So a realistic precise
  stack is: **TWSTFT (clock) → carrier ambiguity becomes integer-resolvable → LAMBDA (range).**
- In a **two-way carrier** link you get both from one exchange: the **sum** of forward+return phase
  gives range (needs LAMBDA), the **difference** gives clock (TWSTFT). This is the cleanest ISL
  design and document 03 recommends it.

So the answer to *"is LAMBDA used instead of TWSTFT or in combination?"* → **in combination**;
they are duals (range vs clock), and TWSTFT/clock-calibration is often a precondition for AR.

---

## 5. TU Delft LAMBDA 4.0 toolbox — reuse or rewrite?

**Recommendation: reuse it (vendored, wrapped), do not rewrite.**

The attached `LAMBD4-master_2024_10_01/` is the **canonical, peer-reviewed** implementation
(Massarweh, Verhagen & Teunissen 2024; the Teunissen 1993/1995 and de Jonge–Tiberius 1996 papers are
in `LAMBDA_papers/`). Rewriting the ILS search-and-shrink from scratch would be scientifically
pointless and error-prone. Key facts from inspection:

- **Clean, self-contained interface** (`LAMBDA.m`):
  `[a_fix, sqnorm, nFixed, SR, Z_mat, Qz_hat] = LAMBDA(a_hat, Qa_hat, METHOD, …)`.
  Inputs are exactly *float ambiguity vector* + *its variance-covariance matrix*. Nothing else. That
  is precisely what an EKF exposes (`a_hat = x(ambIdx)/λ`, `Qa_hat = P(ambIdx,ambIdx)/λ²`).
- **Rich method set** we will actually use: ILS (#3, default), Partial AR (#5, crucial when full-set
  SR is low — likely for weak GEO/ISL geometry), Integer Aperture / FFRT (#7) and bootstrapping (#2)
  for **validation/acceptance testing**. `Ps_LAMBDA.m` computes **success rate / failure rate** — we
  should gate any fix on SR, which the toolbox gives us for free.
- **`mlambda.m`** is a separate McGill (Chang/Xie) MLAMBDA implementation, also included — useful as a
  cross-check oracle but not the primary (keep one primary engine = the TU Delft `LAMBDA.m`).
- **Licensing / attribution (action required before merge):** the code is © TU Delft GRS; `README.txt`
  has no explicit open-source licence text. **Do not vendor into the repo until the licence/reuse
  terms are confirmed** (email in README). Interim: keep it under `third_party/LAMBDA/` with the
  original headers intact and a `PROVENANCE.md`, and treat it as an optional dependency behind the
  feature toggle. Document 03 assumes this resolves to "reuse permitted with attribution."

**What we must build around it (the toolbox does NOT do):** assemble `a_hat`/`Qa_hat` from the EKF,
choose the *differenced* parametrisation that makes them integer, run the **conditional state update**
of the real-valued states after fixing (`x_check = x_hat − Q_bâ Qâ⁻¹ (â − ǎ)`), and the accept/reject
logic. That glue is the real work; the search itself is a black box we call.

---

## 6. Model-switching workflow (Opus 4.8 ↔ Sonnet 5)

Model switching is a **manual user action** — the assistant cannot change its own model. Switch with
`/model` in Claude Code (or the app's model selector). The intended division of labour:

| Model | Use for | Why |
|---|---|---|
| **Opus 4.8** (`/model claude-opus-4-8`) | Planning, physics/math design, state-vector & covariance design, golden-safety review, reading diffs, validation-result interpretation, anything touching `ReverseGNSSEKF.nx` | Judgement-heavy, equivalence-critical, high blast-radius |
| **Sonnet 5** (`/model claude-sonnet-5`) | Mechanical implementation from an approved per-phase spec: adding config toggles, writing the LAMBDA wrapper, wiring rows, scaffolding tests | Fast, cheap, ideal for well-specified edits |

**Per-phase loop (repeat for each phase in docs 01–03):**

1. **[Opus]** Turn the phase into a concrete edit spec: exact files, functions, new states, the
   golden-safety gate, and the acceptance test. Commit the spec.
2. `/model claude-sonnet-5` — **[Sonnet]** implement strictly to the spec; run the phase's unit test;
   stop at the golden fingerprint.
3. `/model claude-opus-4-8` — **[Opus]** review the diff against the spec, run/interpret the golden
   regression (`tests/regression/run_swarm_fingerprint.m`) and scientific validation, decide
   merge/iterate.

Rule of thumb: **if the edit can change `nx`, covariance structure, or the truth/estimate boundary,
Opus drives; otherwise Sonnet drives.** Never let a model boundary fall in the middle of a
state-vector change.

---

## 7. Recommended phase order & dependencies

```
Phase 0  [Opus]   Confirm LAMBDA licence; vendor to third_party/LAMBDA/ behind a toggle
Phase 1  [01]     Generalised ambiguity-state layer (link dimension); ISL float carrier row
Phase 2  [02]     ISL light-time + Doppler consistency with the new carrier path
Phase 3  [03-A]   LAMBDA wrapper + Qa assembly; apply to the INTEGER-READY case first
                  (between-antenna DD attitude — already integer, lowest risk, validates the engine)
Phase 4  [03-B]   Between-satellite DD for ISL relative/shape → integer ISL AR
Phase 5  [03-C]   TWSTFT-calibrated ground path; PPP-AR feasibility study (may end as "documented
                  negative result" for single-receiver absolute — that is a legitimate outcome)
```

Each phase is independently gated **default-off** and must leave the frozen golden fingerprint
(`nx=65`, `traceP=50503.7896526557`) byte-identical when its toggle is off. Phase 3 deliberately
starts on the one case that is *already* integer, so the LAMBDA engine is proven before we invest in
new differenced parametrisations.

---

## 8. Cross-cutting risks

- **`nx`/state-vector surgery** (docs 01, 03) is the highest-risk area — one frozen-golden file.
  Mitigation: append-last ordering, default-off gates, re-freeze a dedicated enabled-config
  fingerprint.
- **Non-integer parametrisation** (§1) is the highest-*science* risk — fixing a bias-contaminated
  ambiguity is worse than not fixing. Mitigation: only ever run LAMBDA on a *provably differenced or
  bias-calibrated* vector; gate every fix on `Ps_LAMBDA` success rate.
- **Licensing** (§5) blocks vendoring, not planning. Resolve in Phase 0.
- **Over-claiming absolute AR** (§3): keep the thesis claims to attitude + relative/shape.

---

## 9. On the attached ChatGPT discussion

The shared `chatgpt.com/share/...` link could not be read programmatically (share pages render via
JavaScript; the fetch returned only the login shell). So this plan critiques the *substance* of the
three requests directly rather than that specific thread. Watch for these common LLM errors when
comparing against it:

- Claiming LAMBDA **replaces** TWSTFT (wrong — §4, they are duals).
- Claiming the existing float states are **ready to fix** with LAMBDA (wrong — §1, they absorb bias).
- Claiming single-receiver **absolute** GEO position becomes mm-class with AR (wrong for this
  geometry — §3).
- Underestimating the **link-dimension** refactor for ISL states (document 01) or the need for a
  **full** covariance block rather than the per-ambiguity sigma used today.

If the thread contradicts any of the above, trust the code-grounded analysis here.
