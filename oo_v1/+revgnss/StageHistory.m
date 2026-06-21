classdef StageHistory
    % StageHistory  Implemented-stage history and missing-scientific-items list.
    %
    % Separates stage-history bookkeeping from runtime source-truth in ReportStatus.
    % ReportStatus.current() delegates to this class for long list fields.
    %
    % Usage:
    %   items   = revgnss.StageHistory.implementedItems()
    %   missing = revgnss.StageHistory.missingScientificItems(55)
    %   item    = revgnss.StageHistory.currentImplementedItem(55)

    methods (Static)

        function list = implementedItems()
            % implementedItems  Full history of implemented-stage items.
            list = {
                'ReportStatus: runtime git SHA, branch, validation mode, missing-stages list'
                'ValidationSummary: JSON + TXT summary writer and reader'
                'ValidationRunner: deterministic random test selection (seed per stage, 2-5 tests)'
                'FrameTimeUtils: simple ECEF/inertial Earth-rotation and Sagnac foundation'
                'run_stage24_validation.m: targeted smoke validation + all-toggle report run'
                'Report Stage 24 validation status section in PDF/TEX'
                'All-toggle report mode: all independent boolean features enabled for run'
                'README updated to Stage 24 with runtime-SHA policy'
                'TWSTFT code time-transfer diagnostic scaffold (Stage 24a, diagnostic-only)'
                'Stage 25: env-var all-toggle gate; run_stage25_26_validation executes main script directly'
                'Stage 26: OrbitDynamics two-body + J2 + RK4; OrbitPropagator orbit-mode selector'
                'Stage 27: validation artifact closure; preliminary summary before report; real PDF text via pdftotext'
                'Stage 28: OrbitDiagnostics helper; OrbitPropagator time-grid validation; orbit diagnostics in report'
                'Stage 29: validation gate moved into main script; .gitignore for output artifacts; SHA-based freshness check'
                'Stage 30: MainScriptValidationGate helper; restored pre/post-run gate in run_oo_reverse_gnss_report.m'
                'Stage 31: AttitudeObservability audit class; H-column rank/condition/classification; report subsection'
                'Stage 32: ReceiverGeometry helper; body-frame lever-arm normalisation, baselines, centroid; report subsection'
                'Stage 33: AttitudeKinematics convention(), eulerToDcm(), gimbal metric, validateDcm(), finite-diff lever-arm Jacobian; report subsection'
                'Stage 34: AttitudeJacobianAudit audit(), finiteDiffRangeAttitudePartial(), hOnlySummary(); H-only summary in production; report subsection'
                'Stage 35: AttitudeEvidenceReport helper; scenario-level attitude evidence summary linking truth/estimate histories with observability, receiver geometry, Euler convention, and Jacobian audit status'
                'Stage 36: AttitudeScenarioReadiness helper; single-asset attitude scenario readiness classification from receiver geometry rank, measurement modes, observability, Jacobian audit, and evidence status'
                'Stage 37: validation-status chapter removed from PDF; README contains validation status and missing-scientific-stages summary; PDF verification checks scientific content and absence of validation-status heading'
                'Stage 38: CarrierAttitudePreparation helper; rowInventory (totalCarrierRows/totalDiffAttRows from summary), ambiguityInventory (nAmbiguities from nTowers*nReceivers), classify_ priority chain; report subsection in writeAttitudeObservability_'
                'Stage 39: CarrierRowMetadataInventory helper; carrier/differential-attitude row and ambiguity metadata inventory with summary fallback and explicit limitations; reused in Stage 38 helper; report subsection'
                'Stage 40: AmbiguityReadinessDiagnostics helper; float ambiguity readiness assessment using Stage 39 inventory, covariance check, slip detection status, known-ambiguity validation flag; blockers and score; report subsection'
                'Stage 41: AmbiguityStateMetadata helper; EKF ambiguity state-map export and final ambiguity covariance sub-block diagnostics for float ambiguity readiness'
                'Stage 42: SignalCatalog signal facade; guarded L2 carrier EKF row architecture (l2EkfRows.enable); L2 ambiguity states, wavelength, iono scaling per signal; L2CarrierArchitectureDiagnostics; AmbiguityStateMetadata signal ID labels (L1/L2)'
                'Stage 43: diagnostic-only L1/L2 ionosphere-free combination coefficients, first-order ionosphere cancellation check, and noise amplification reporting; no EKF IF rows and no integer fixing'
                'Stage 44: SignalConfigResolver for consistent L2 detection from any cfg field; IonosphereFreeBiasBudget diagnostic IF bias residual propagation; fixes l2SignalEnabled_ bug in IFCombinationDiagnostics'
                'Stage 45: guarded L1/L2 ionosphere-free code EKF rows via IF combination using alpha/beta coefficients; uncorrelated-noise R_IF; explicit bias-budget and noise-amplification limitations; no carrier IF, no integer fixing, no PPP-grade claim'
                'Stage 46: CodeIonoFreeConsistencyDiagnostics; explicit row-count, H-compatibility, R/noise-amplification, residual/NIS, and bias-state-risk audit for Stage 45 code IF EKF rows; combineJacobians utility in CodeIonoFreeRowBuilder'
                'Stage 47: CarrierIonoFreeRowBuilder post-processes L1+L2 carrier EKF rows into IF rows (float ambiguity, non-integer); CarrierIonoFreeEkfDiagnostics; B_IF=alpha*B_L1+beta*B_L2; no integer fixing, no LAMBDA/MLAMBDA, no calibrated DCB'
                'Stage 48: CarrierIonoFreeAmbiguityTraceability helper; explicit L1/L2 ambiguity state pair metadata in cpInfo (ambiguityStateIdxL1/L2, ambiguityStateIdxPair, ambiguityWeights); Var(B_IF)=[alpha beta]*P_pair*[alpha;beta] from Stage 41 Pamb; stale EKF-state-map-refactoring limitation removed from AmbiguityReadinessDiagnostics'
                'Stage 49: wide-lane / narrow-lane float diagnostics from traced L1/L2 ambiguity covariance; no integer fixing, no LAMBDA/MLAMBDA, no phase-bias products, no false-fix-risk control'
                'Stage 50: ambiguity fixing readiness gate combining Stages 41/48/49, arc-quality availability, and residual/NIS availability; strict readiness gate only; no integer fixing, no LAMBDA/MLAMBDA, no phase-bias products, no false-fix-risk control'
                'Stage 51: ambiguity readiness evidence hardening; non-early-return evidence collection, explicit arc-quality and residual/NIS availability diagnostics, public arcQuality/residualConsistency/blockerList, readiness score, blocker aggregation, and status-warning consistency; no integer fixing'
                'Stage 52: carrier arc and cycle-slip evidence export; CarrierTrackManager extended with slipCount_ and currentArcEpoch_ per track; CarrierArcEvidence helper; compact arc fields in summary; AmbiguityFixingReadinessGate.arcQuality() prefers Stage 52 fields; report subsection; no integer fixing'
                'Stage 53: cycle-slip-aware arc-separated float ambiguities; CarrierTrackManager extended with currentArcId_ per track; AmbiguityArcState helper; per-row arc metadata in summary; arc consistency check for carrier IF and WL/NL pairs; Stage 53 compact fields in summary; report subsection; no integer fixing'
                'Stage 54: enforceCarrierArcConsistency.enable gate in CarrierIonoFreeRowBuilder.buildFromStack; arc-inconsistent pairs filtered before IF combination; empty-output handling when all pairs skipped; new cpInfo_IF fields (nArcSkippedPairs, arcConsistencyEnforced, arcMetaUsedForEnforcement); arc-blocked classification in WideLaneNarrowLaneDiagnostics; Stage 54 blockers in AmbiguityFixingReadinessGate; Stage 54 compact summary fields; Stage 54 report subsection; no integer fixing'
                'Stage 55: source-truth and report-architecture cleanup; StageHistory and DiagnosticPluginRegistry helpers; ReportStatus delegates history/missing lists to StageHistory; ReportRunner calls DiagnosticPluginRegistry.collectAll for plugin metadata; Stage 55 PDF subsection; no physics change, no EKF math change, no ambiguity fixing, no LAMBDA/MLAMBDA, no false-fix-risk control'
                'Stage 56: measurement geometry core consolidation; LinkGeometry shared helper for tower position, antenna position, analytic LOS Jacobian, FD position/attitude Jacobian, and attitude partial gate; CodeJacobianBuilder and CarrierMeasurementBuilder migrated; preferred cfg.estimator.attitude.use<Kind>Partials config with backward-compat legacy path; stale carrier-IF comment in CarrierMeasurementBuilder replaced with scientifically correct guard; no physics change, no EKF math change, no integer fixing, no LAMBDA/MLAMBDA, no false-fix-risk control'
                'Stage 57: EKF innovation accounting and gauge/NIS cleanup; EkfInnovationAccounting helper with classifyRows/compute/residualRms/compact; ReverseGNSSSimulation captures nu and S from update() to build separated physical/gauge/augmented NIS accounting; Diagnostics stores per-epoch Stage 57 fields; ReportRunner exposes physicalNIS, gaugeNIS, and per-type RMS in summary; ClockExactReportBuilder Stage 57 subsection; legacyMeanNisIncludesGauge flag marks existing meanNIS as augmented; physicalConsistencyUsesGaugeRows=false; no measurement physics change, no EKF update math change, no integer fixing, no LAMBDA/MLAMBDA, no false-fix-risk control'
                'Stage 58: EKF two-body/J2 dynamics prediction; ECEF state transformed to inertial-like frame with constant Earth rotation, propagated by OrbitDynamics RK4 two-body/J2, transformed back to ECEF, and finite-difference 6x6 translational STM used in EKF prediction; EkfDynamicsPredictor helper with mode/propagateEcef/finiteDiffStm6/summaryLines; FrameTimeUtils extended with ecefStateToInertial/inertialStateToEcef/omegaEcef_radps/roundTripStateError; default constantVelocity mode is backward compatible; no drag, SRP, third bodies, EOP/IERS, relativistic clock model, integer fixing, LAMBDA/MLAMBDA, or false-fix-risk control'
                'Stage 59: controlled single-space-asset multi-antenna float-carrier attitude scenario; non-collinear 4-receiver lever-arm cross pattern with z-offset (baseline rank 3); carrier attitude partials enabled via preferred Stage 56 controls; EKF float ambiguities with arc-separated ambiguity metadata (Stage 53) and enforced carrier arc consistency (Stage 54); attitude error norm, carrier residual RMS, physical NIS-per-DOF, baseline rank, and dynamics self-consistency reported; constantVelocity EKF dynamics for self-consistency with static-ECEF GEO truth; ISL/TWSTFT disabled; ScenarioPresets.apply helper and SingleAssetAttitudeScenarioReport helper added; no integer fixing, no LAMBDA/MLAMBDA, no calibrated phase-bias products, no false-fix-risk control, no PPP-grade attitude claim, no multi-space-asset estimation'
                'Stage 60: carrier-attitude measurement model closure; CarrierAttitudeRowClosure helper with rowGeometry/attitudeJacobianFiniteDiff/compareRow/spotCheck methods delegating to LinkGeometry; CarrierMeasurementBuilder extended with per-row cpInfo closure metadata (leverArmNorm_m, attitudePartialsEnabled, attitudeSensitive, hAttitudeNorm, rowUsesLinkGeometry, carrierAttClosureAvail); SingleAssetAttitudeScenarioReport extended with component-level roll/pitch/yaw truth/estimate/error from final diag.log euler; ReportRunner populates stage60* summary fields including FD spot-check closure status; component-level euler errors exported to singleAssetAttitudeRollError_deg/Pitch/Yaw; no integer fixing, no LAMBDA/MLAMBDA, no quaternion/error-state EKF, no PPP-grade claim, no new orbit dynamics, no new attitude parameterization'
                'Stage 61: quaternion nominal / small-angle error-state attitude EKF; AttitudeErrorStateKinematics helper (quatNormalize, eulerToQuatZYX, quatToEulerZYX, quatToDcm, deltaQuat, injectRight, propagateQuatBodyRate, smallAnglePerturbedDcm, wrapEulerError_deg, summaryLines); ReverseGNSSEKF extended with nominalQuat_wxyz, attitudeParameterization, getMeasurementState(), getReportEulerRad(), quaternionErrorState predict/update paths; LinkGeometry.finiteDiffAttitudeJacobian extended with quaternionErrorState mode (perturbs DCM body-frame, not Euler angles); Diagnostics uses getReportEulerRad(); ReverseGNSSSimulation routes measurement state via getMeasurementState(); CarrierAttitudeRowClosure adds stage61CarrierClosureUsesErrorStateJacobian and closed-quaternion-error-state classification; run script selects quaternionErrorState; no integer fixing, no LAMBDA/MLAMBDA, no PPP-grade claim, no new orbit dynamics'
                'Stage 62: quaternion error-state covariance consistency closure; ReverseGNSSEKF.update now computes S, K, and Joseph posterior covariance from the pre-update covariance Pminus, then injects delta_theta into the nominal quaternion and applies the attitude reset Jacobian G=I-0.5*skew(delta_theta) to the posterior covariance; records covarianceResetOrder=posterior-after-joseph, injection norms, quaternion norm, and reset Jacobian condition number; injection size guard (default 10 deg) warns if exceeded; Stage 57 physical/gauge accounting and Stage 60 carrier-attitude closure preserved; legacy eulerZYX mode unchanged; no integer fixing, no LAMBDA/MLAMBDA, no false-fix-risk control, no PPP-grade claim'
                'Stage 63: controlled single-asset raw-carrier integer ambiguity fixing; IntegerAmbiguityFixer helper with assess/resetOnSlip/summaryLines; 18 scientific guards (scenario, ambiguity mode, arc length, covariance sigma, distance-to-integer, residual RMS, held/reset management); fixes applied as EKF pseudo-measurements via new applyAmbiguityPseudoMeasurement method in ReverseGNSSEKF; held fixes tracked per arc in ReverseGNSSSimulation.fixState63_; fix counts accumulated in fix63Log_; stage63* summary fields and Stage 63 PDF subsection; NOT LAMBDA/MLAMBDA, NOT carrier-IF integer fixing, NOT wide-lane/narrow-lane, NOT formal false-fix-risk control, NOT calibrated phase-bias products, NOT PPP-grade attitude'
                'Stage 64: scientific closure and v1 freeze; PCV default corrected to none; IF covariance assumption documented (alpha^2*Var_L1+beta^2*Var_L2, Cov=0); Doppler labelled simplified-v1 (LOS range-rate + rx/tower clock drift only); Stage 64 Final Scientific Closure section in PDF; stage64* summary fields in ReportRunner; scenario semantics clarified (cleanIdeal/matchedError/finalAllToggle); active-no-fixes from Stage 63 acknowledged and not treated as failure; Stage 61/62 quaternion covariance update-order preserved; full suite NOT RUN; v1 frozen as controlled internally consistent MATLAB EKF simulation demonstration'
            };
        end

        function list = missingScientificItems(~)
            % missingScientificItems  Not-implemented items that must not be claimed.
            % v1 is frozen at Stage 64. These items are not implemented and must not be claimed.
            list = {
                'Full CI / full test-suite validation (current: targeted random smoke, 2-5 tests only; full suite NOT RUN)'
                'Calibrated antenna PCO/PCV and ANTEX hardware-bias products (default PCV=none; toy PCV is synthetic-only; geometry model is reference-point only)'
                'Production-grade quaternion attitude robustness: large-error injection bounding, ring-down prevention, and formal reset-transition validation (Stage 61 adds quaternionErrorState mode; Stage 62 fixes covariance reset ordering; production-grade injection clamping not implemented)'
                'Integer ambiguity fixing (LAMBDA/MLAMBDA, carrier-IF, wide-lane/narrow-lane): Stage 63 adds controlled raw-carrier fixing path; active-no-fixes in all-toggle run is correct (IF combination prevents individual L1 sigma convergence); LAMBDA/MLAMBDA, carrier-IF integer fixing, WL/NL, calibrated phase-bias products, and formal false-fix-risk control are NOT implemented'
                'Calibrated inter-frequency biases / DCB / differential phase biases (not modelled in v1)'
                'Simplified v1 Doppler only (LOS range-rate + rx/tower clock drift; no Sagnac-rate, no relativistic range-rate, no lever-arm velocity from body rates, no high-fidelity transmitter dynamics)'
                'IF covariance uses uncorrelated noise assumption (Var_IF=alpha^2*Var_L1+beta^2*Var_L2, Cov(L1,L2)=0); correlated dual-frequency noise modelling not implemented'
                'Monte Carlo / NIS / NEES stochastic consistency validation'
                'Scientific troposphere: Niell/GMF/VMF3/GPT3/ERA5 mapping functions'
                'Scientific ionosphere: Klobuchar/IONEX/higher-order ionosphere models'
                'Full IERS/EOP GCRS/ITRF reference-frame and Earth-orientation products'
                'Full relativistic GNSS clock modelling (Schwarzschild, gravitational redshift)'
                'Higher-fidelity orbit dynamics: drag, SRP, third bodies, precise orbit products'
                'Real TWSTFT / relay / transponder physics'
                'External GNSS product ingestion: SP3, CLK, RINEX, IONEX, ANTEX'
                'Operational navigation, precise orbit determination, mission-qualified attitude, or PPP-grade processing (v1 is a controlled EKF demonstration only)'
            };
        end

        function item = currentImplementedItem(stage)
            % currentImplementedItem  Return the single implemented-items entry for stage.
            all_ = revgnss.StageHistory.implementedItems();
            prefix = sprintf('Stage %d:', stage);
            for k = 1:numel(all_)
                if startsWith(all_{k}, prefix)
                    item = all_{k};
                    return
                end
            end
            item = sprintf('Stage %d: (no history entry found)', stage);
        end

    end
end
