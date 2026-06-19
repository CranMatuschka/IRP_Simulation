classdef ReportStatus
    % ReportStatus  Runtime validation status.
    %
    % Reads runtime values from output/latest_validation_summary.json (if present).
    % If the JSON is missing or has a stale SHA, validationArtifactFresh=false.
    % Report generation continues normally regardless.
    %
    % Usage:
    %   s     = revgnss.ReportStatus.current();      % full status struct
    %   lines = revgnss.ReportStatus.summaryLines();  % formatted cell array

    methods (Static)

        function s = current()
            s.stage      = '49';
            s.stageTitle = 'Wide-Lane / Narrow-Lane Float Diagnostics v1';
            s.validationMode = 'targeted-random-smoke';
            s.fullSuiteRun   = false;

            s.gitSHA        = revgnss.ReportStatus.getGitSHA_();
            s.branch        = revgnss.ReportStatus.getGitBranch_();
            s.matlabVersion = version;
            s.timestamp     = datestr(now, 'yyyy-mm-dd'); %#ok<TNOW1,DATST>

            % Load validation summary; never fail report generation.
            summaryDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            vs = revgnss.ValidationSummary.read(summaryDir);

            if isfield(vs, 'nPassingSelectedTests') && isnumeric(vs.nPassingSelectedTests)
                s.nPassingSelectedTests = vs.nPassingSelectedTests;
                s.nSelectedTests        = vs.nSelectedTests;
            else
                s.nPassingSelectedTests = 0;
                s.nSelectedTests        = 0;
            end
            s.allPass = (s.nPassingSelectedTests == s.nSelectedTests) && ...
                        (s.nSelectedTests > 0);

            s.reportRunPassed    = revgnss.ReportStatus.safeBool_(vs, 'reportRunPassed',    false);
            s.pdfVerified        = revgnss.ReportStatus.safeBool_(vs, 'pdfVerified',        false);
            s.allToggleReportRun = revgnss.ReportStatus.safeBool_(vs, 'allToggleReportRun', false);
            s.invokedMainScript  = revgnss.ReportStatus.safeBool_(vs, 'invokedMainScript',  false);
            s.pdfTextVerified    = revgnss.ReportStatus.safeBool_(vs, 'pdfTextVerified',    false);
            s.texVerified        = revgnss.ReportStatus.safeBool_(vs, 'texVerified',        false);
            if isfield(vs, 'validationWarnings') && iscell(vs.validationWarnings)
                s.validationWarnings = vs.validationWarnings;
            else
                s.validationWarnings = {};
            end

            % Freshness: require matching stage AND matching runtime SHA.
            runtimeSHA = revgnss.ReportStatus.getGitSHA_();
            vsStageNum = 0;
            if isfield(vs, 'stage')
                vsStageNum = str2double(strtrim(num2str(vs.stage)));
                if isnan(vsStageNum); vsStageNum = 0; end
            end
            vsSHA = '';
            if isfield(vs, 'gitSHA'); vsSHA = strtrim(char(vs.gitSHA)); end
            s.validationArtifactFresh = (vsStageNum >= 49) && strcmp(vsSHA, runtimeSHA);
            if ~s.validationArtifactFresh
                s.validationWarnings{end+1} = ...
                    'No fresh local validation summary for this commit. Run: setenv(''OO_V1_VALIDATE_REPORT'',''true''); setenv(''OO_V1_VALIDATION_STAGE'',''49''); run_oo_reverse_gnss_report';
            end

            if isfield(vs, 'selectedTestNames')
                s.selectedTests = vs.selectedTestNames;
            else
                s.selectedTests = {};
            end
            if isfield(vs, 'notes') && ~isempty(vs.notes)
                s.validationNote = vs.notes;
            else
                s.validationNote = '';
            end

            s.missingScientificStages = revgnss.ReportStatus.missingStages_();
            s.implementedStage24Items = revgnss.ReportStatus.implementedItems_();
        end

        function lines = summaryLines()
            % summaryLines  Formatted cell array for embedding in report pages.
            s = revgnss.ReportStatus.current();
            lines = {};
            lines{end+1} = sprintf('Stage        : %s -- %s', s.stage, s.stageTitle);
            lines{end+1} = sprintf('Branch       : %s', s.branch);
            lines{end+1} = sprintf('Commit SHA   : %s', s.gitSHA);
            lines{end+1} = sprintf('Validation   : %s  (full suite NOT RUN)', s.validationMode);
            lines{end+1} = sprintf('Tests passed : %d / %d selected', ...
                s.nPassingSelectedTests, s.nSelectedTests);
            lines{end+1} = sprintf('All-toggle   : %s', mat2str(s.allToggleReportRun));
            lines{end+1} = sprintf('PDF verified : %s', mat2str(s.pdfVerified));
            lines{end+1} = sprintf('MATLAB       : %s', s.matlabVersion);
            lines{end+1} = sprintf('Status date  : %s', s.timestamp);
        end

    end

    methods (Static, Access = private)

        function sha = getGitSHA_()
            sha = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [s, out] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', repoRoot));
                if s == 0; sha = strtrim(out); end
            catch; end
        end

        function br = getGitBranch_()
            br = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [s, out] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', repoRoot));
                if s == 0; br = strtrim(out); end
            catch; end
        end

        function v = safeBool_(s, f, def)
            if isfield(s, f); v = logical(s.(f)); else; v = def; end
        end

        function list = missingStages_()
            list = {
                'Full CI / full test-suite validation (current: targeted random smoke, 2-5 tests only)'
                'Calibrated antenna PCO/PCV and ANTEX hardware-bias products (geometry model is reference-point only)'
                'Quaternion / error-state attitude EKF (current ZYX Euler is documented but singular at pitch +/-90 deg)'
                'Full per-row LOS metadata for runtime finite-diff Jacobian consistency (production path uses H-only summary)'
                'Multi-antenna single-asset attitude scenario validation'
                'Integer ambiguity fixing for carrier IF (LAMBDA/MLAMBDA; Stage 47 adds float IF rows; Stage 48 adds float traceability; Stage 49 adds float WL/NL diagnostics; no integer fixing)'
                'Calibrated inter-frequency biases / DCB / differential phase biases (not modelled in v1)'
                'Integer ambiguity resolution (LAMBDA/MLAMBDA)'
                'False-fix-risk control and ratio/residual validation'
                'Monte Carlo / NIS / NEES stochastic consistency validation'
                'Scientific troposphere: Niell/GMF/VMF3/GPT3/ERA5 mapping functions'
                'Scientific ionosphere: Klobuchar/IONEX/higher-order ionosphere models'
                'Full IERS/EOP GCRS/ITRF reference-frame and Earth-orientation products'
                'Full relativistic GNSS clock modelling (Schwarzschild, gravitational redshift)'
                'Higher-fidelity orbit dynamics: drag, SRP, third bodies, precise orbit products'
                'Real TWSTFT / relay / transponder physics'
                'External GNSS product ingestion: SP3, CLK, RINEX, IONEX, ANTEX'
            };
        end

        function list = implementedItems_()
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
            };
        end

    end
end
