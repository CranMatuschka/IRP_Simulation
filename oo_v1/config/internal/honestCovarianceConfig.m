function cfg = honestCovarianceConfig(cfg)
%HONESTCOVARIANCECONFIG  Lab-notebook config for the "why is the realism filter over-confident
%   and can we fix it honestly (not fake-forced)?" investigation. CONCLUSION: on the one-way
%   sparse GEO geometry the over-confidence is an OBSERVABILITY WALL that no honest config
%   change fixes -- only changing the geometry (two-way / swarm) does. This overlay therefore
%   equals the realism grade plus a harmless (near-no-op) 1 m R floor; the two attempted fixes
%   and why each fails are recorded below and in the body.
%
%   cfg = honestCovarianceConfig(masterConfig())     % == realism grade (+ 1 m R floor)
%
%   WHY THE REALISM RUN IS OVER-CONFIDENT (diagnosis, verified from the code, not assumed):
%   The realism battery shows NIS/dof ~= 1 (0.94..1.15) but NEES/dof >> 1
%   (pos 133..536, clk up to 250) and 3-sigma coverage collapsing to 0 %. NIS ~ 1
%   means the innovations z-h ARE consistent with S = HPH' + R; NEES >> 1 means the
%   STATE errors are far larger than P claims. That combination is NOT a wrong-R-magnitude
%   problem (R is already ~1.07 m, sized by the C/N0 model -- confirmed, and raising the
%   sigmaFloor to 1 m below did nothing). It is a wrong-error-MODEL problem: the truth
%   injects per-tower, temporally CONSTANT / CORRELATED systematics (colored-GM multipath
%   ~0.30 m, tower survey, PCV, frame residual) that the filter treats as WHITE, so it
%   averages them away over 3600 epochs while the real error does not average. See the
%   mechanism block below for the full, corrected derivation.
%
%   TESTED HYPOTHESIS AND RESULT (2026-07-15): this file first raised the pseudorange R
%   floor (cfg.measurement.sigmaFloor_m: 0.01 -> 1.0 m) on the theory that R undercounted
%   the systematics. The full 6-run realism battery was re-run with it. RESULT: NEES barely
%   moved (e.g. G5S1R4-TW0 pos 183 -> 187, clk 250 -> 252; sigma/RMS 0.05 -> 0.05). Verified
%   why: R was ALREADY ~1.07 m in the realism grade (the C/N0 code-noise model + tower-clock
%   product already yield meanR ~= 1.14 m^2, and NIS/dof ~= 1.0 confirms R is well sized).
%   The floor was never the binding constraint, so scaling it is a near-no-op. HYPOTHESIS
%   FALSIFIED -- kept here (harmless, mildly conservative) but it is NOT the cure.
%
%   THE ACTUAL, VERIFIED MECHANISM (corrected after reading the error chain): the driver is
%   the TEMPORALLY CONSTANT / CORRELATED, PER-TOWER truth systematics that the measurement
%   model does not correct -- dominated by colored-Gauss-Markov code multipath (~0.30 m
%   steady state, tau-correlated), plus static tower-survey ENU error, antenna PCV, and the
%   EOP/solid-tide frame residual. On a GEO (near-static geometry) these alias into the
%   weakly-observable radial<->rx-clock mode with the radial dilution PDOP ~= 560:
%   0.30 m x 560 ~= 168 m, matching the observed clock/radial error ~185 m (617 ns). The
%   filter's formal clock sigma is only ~9.8 m because it models the measurement error as
%   WHITE and TEMPORALLY INDEPENDENT, so it averages it down over the 3600 epochs
%   (sigma ~ 1/sqrt(N)); the real driver is constant/correlated and does NOT average
%   -> 19x over-confident. Because a diagonal white R scales the formal sigma AND the
%   propagated error together, the over-confidence RATIO is invariant to R (and Q) scaling
%   -- the mathematical reason no honest scalar makes NEES -> 1 (R-floor experiment above).
%   NOTE two corrections to a naive budget: the 0.5 m hardware-delay residual is WHITE per
%   epoch (already honestly in R, not a constant bias), and configured inter-frequency code
%   DCB is deterministic per signal (residual bias when truth and model differ), not a white
%   covariance inflation term.
%
%   TESTED FIX #2 -- estimate per-tower clock/bias states: DIVERGES (NOT enabled). A constant
%   per-tower measurement bias is observationally identical to a per-tower clock bias, so
%   estimating per-tower clock states (clock.mode='includeTowerClocksInEKF') should absorb the
%   systematics honestly. But the one-way GEO geometry gives only N pseudoranges per epoch for
%   N tower clocks + rx clock + position, and the near-static geometry never separates them, so
%   the weakly-observable subspace random-walks. VERIFIED (2026-07-15): R1 diverges to 378 km
%   (externalTowerCorrections gauge) / 3400 km (meanGroundClockGauge); R4 fails a carrier/
%   attitude Jacobian assertion. finalizeConfig ACCEPTS the config, but config validity is not
%   dynamic observability. Left OFF (see body). Making it work is a filter-code task: gate to
%   dense/observable geometries (>= R4, pinned datum) and harden the carrier-attitude path.
%
%   CONCLUSION (the honest answer to "how to make it less over-confident"): you cannot, by any
%   config knob, for one-way sparse GEO. Covariance sizing is RATIO-INVARIANT (fix #1) and
%   state augmentation DESTABILIZES (fix #2). The over-confidence is a fundamental weak-
%   observability property of the radial<->rx-clock mode. The ONLY honest cure is GEOMETRY --
%   two-way time transfer or a co-observed swarm -- which the existing batteries already show:
%   swarm S6R4 sits at NEES ~50-60 vs ~140-540 for R1/R4, and two-way lowers R1/R4 NEES ~25 %.
%   DELIBERATELY NOT CHANGED: process noise stays at the physical force budget; no scalar
%   P/covariance inflation anywhere; the truth is identical to the realism grade.
%
%   See also: realismGradeConfig, run_oo_v1_battery, run_oo_v1_analysis.

    if nargin < 1 || isempty(cfg); cfg = masterConfig(); end

    % Start from the physically-representative realism grade (truth systematics, real
    % clock, honest floors, force-model process noise). Idempotent value-sets.
    cfg = realismGradeConfig(cfg);

    % ---- (Retained, but a near-no-op) pseudorange R floor at the ~1 m budget ----------
    % The realism grade already produces meanR ~= 1.07 m from the C/N0 code-noise model, so
    % a 1 m floor only lifts the few sub-1 m rows. Kept because >=1 m is the physically
    % correct minimum; the R-floor experiment (see header) proved it does NOT reduce the
    % over-confidence -- that is a correlation-structure problem, addressed below instead.
    cfg.measurement.sigmaFloor_m = 1.0;

    % ---- TESTED FIX #2 (per-tower clock/bias states): DIVERGES -> NOT enabled ---------
    % Idea: a constant per-tower measurement bias is observationally identical to a per-tower
    % clock bias, so estimating per-tower clock states (clock.mode='includeTowerClocksInEKF')
    % should let the filter absorb the per-tower systematics with honest covariance.
    % RESULT (verified 2026-07-15, both gauge modes): it DIVERGES on the one-way GEO geometry.
    % Each epoch gives only N pseudoranges for N tower clocks + rx clock + position, and the
    % near-static GEO geometry never separates them -> the weakly-observable subspace random-
    % walks. R1 (5 PR/epoch): externalTowerCorrections -> 378 km, meanGroundClockGauge ->
    % 3400 km; R4 hit a carrier/attitude Jacobian assertion. finalizeConfig ACCEPTS the config
    % (states are added) but the run is not dynamically observable -- config validity is not
    % stability. So this is intentionally LEFT OFF. The honest conclusion: the one-way sparse
    % GEO over-confidence is an OBSERVABILITY WALL -- neither covariance sizing (R scaling is
    % ratio-invariant) nor state augmentation (diverges) fixes it. The only thing that does is
    % changing the GEOMETRY: two-way time transfer or a co-observed swarm (empirically S6R4
    % sits at NEES ~50-60 vs ~140-540 for R1/R4). To pursue tower-clock estimation it must be
    % gated to dense/observable geometries (>= R4 with a pinned datum) and hardened against the
    % carrier-attitude assertion -- a filter-code task, not a config toggle.
    %   cfg.clock.mode       = 'includeTowerClocksInEKF';   % <- diverges; do not enable here
    %   cfg.clock.gauge.mode = 'meanGroundClockGauge';

    % Tag so reports/plots can name the profile.
    if isfield(cfg,'realism') && isstruct(cfg.realism)
        cfg.realism.honestCovariance = true;
    end
end
