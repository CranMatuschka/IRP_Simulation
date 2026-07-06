classdef GeoRealWorldScenarioGuard
    % GeoRealWorldScenarioGuard  Hard guard for Stage 86 GEO truth comparison.

    methods (Static)
        function assertValid(cfg)
            errs = {};

            if ~revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'orbit','useOrbitPropagator'}, false)
                errs{end+1} = 'orbit.useOrbitPropagator must be true.';
            end
            truthMode = revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'orbit','truth','mode'}, '');
            orbitMode = revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'orbit','mode'}, '');
            dynMode = revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'estimator','dynamics','mode'}, '');
            if strcmpi(truthMode,'stationaryEcef') || strcmpi(orbitMode,'stationaryEcef')
                errs{end+1} = 'stationaryEcef orbit is forbidden.';
            end
            if strcmpi(dynMode,'constantVelocity')
                errs{end+1} = 'constantVelocity EKF dynamics are forbidden.';
            end
            if any(strcmpi(truthMode, {'j2','j2Rk4'})) && any(strcmpi(dynMode, {'twoBody','two_body','twobody'}))
                errs{end+1} = 'J2 truth with twoBody EKF is an intentional dynamics mismatch.';
            end
            if ~(strcmpi(truthMode,'j2Rk4') && strcmpi(orbitMode,'j2Rk4') && strcmpi(dynMode,'j2'))
                errs{end+1} = 'Stage 86 requires orbit.truth.mode=j2Rk4, orbit.mode=j2Rk4, estimator.dynamics.mode=j2.';
            end

            towerMode = revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'estimator','towerClockMode'}, '');
            if strcmpi(towerMode,'perfectCorrection')
                errs{end+1} = 'perfectCorrection tower-clock mode is forbidden.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','knownAmbiguityAttitudeValidation'}, false) || ...
                    strcmpi(revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'estimator','attitudeCarrierMode'}, ''), 'validationKnownAmbiguity') || ...
                    strcmpi(revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'estimator','attitudeInitMode'}, ''), 'knownAttitudeCalibration') || ...
                    revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','attitudeInit','knownAttitudeCalibration','allow'}, false)
                errs{end+1} = 'Known-truth attitude or ambiguity validation is forbidden.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','integerAmbiguityFixing','enable'}, false) || ...
                    revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','integerAmbiguityFixing','enabled'}, false)
                errs{end+1} = 'Integer ambiguity fixing is forbidden; use float ambiguities only.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'carrierSlip','syntheticSlipInjection','enable'}, false) || ...
                    revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'validation','stress','slips','enable'}, false)
                errs{end+1} = 'Synthetic cycle-slip injection is forbidden in the main scenario.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','estimateAttitudeFromPseudorange'}, false) || ...
                    revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','attitude','useCodePartials'}, false) || ...
                    revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','attitude','useDopplerPartials'}, false) || ...
                    ~revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'estimator','attitude','useCarrierPartials'}, false)
                errs{end+1} = 'Stage 86 requires carrier attitude partials on, code/Doppler attitude partials off.';
            end
            if ~strcmp(revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, {'validation','unsupportedFeaturePolicy'}, ''), 'error')
                errs{end+1} = 'validation.unsupportedFeaturePolicy must be error.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'validation','allowTruthModelMismatch'}, false)
                errs{end+1} = 'validation.allowTruthModelMismatch must be false.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'scientificProfile','allowRealWorldClaim'}, false)
                errs{end+1} = 'scientificProfile.allowRealWorldClaim must be false.';
            end

            if revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'measurement','sigmaFloor_m'}, 0) < 0.01
                errs{end+1} = 'measurement.sigmaFloor_m must be at least 0.01 m.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'errors','codeNoise','sigma_m'}, 0) < 0.60 || ...
                    revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'signals','L1','codeSigma0_m'}, 0) < 0.60
                errs{end+1} = 'Code sigma must be at least 0.60 m on the Stage 86 path.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'measurements','doppler','sigma_mps'}, 0) < 0.03
                errs{end+1} = 'Doppler sigma must be at least 0.03 m/s.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'measurements','carrier','sigma_m'}, 0) < 0.010
                errs{end+1} = 'Carrier sigma must be at least 0.010 m.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getNum_(cfg, {'clocks','tower','product','sigmaBias_m'}, 0) < 0.10
                errs{end+1} = 'Tower product sigmaBias_m must be at least 0.10 m.';
            end

            if ~revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'covariance','productClock','enable'}, false)
                errs{end+1} = 'covariance.productClock.enable must be true.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'covariance','productClock','applyToCode'}, false) && ...
                    ~revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'covariance','sharedErrors','applyTowerClockToCode'}, false)
                errs{end+1} = 'productClock.applyToCode contradicts sharedErrors.applyTowerClockToCode=false.';
            end
            if revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'covariance','productClock','crossCodeDoppler'}, false) && ...
                    ~revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'covariance','productClock','applyToDoppler'}, false)
                errs{end+1} = 'crossCodeDoppler=true requires productClock.applyToDoppler=true.';
            end

            tropModel = revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'errors','troposphere','model','enable'}, false);
            tropStoch = revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'errors','troposphere','stochastic','enable'}, false);
            ionoModel = revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'errors','ionosphere','model','enable'}, false);
            ionoStoch = revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'errors','ionosphere','stochastic','enable'}, false);
            if tropModel && ~tropStoch
                errs{end+1} = 'Troposphere model enabled with zero stochastic residual.';
            end
            if ionoModel && ~ionoStoch
                errs{end+1} = 'Ionosphere model enabled with zero stochastic residual.';
            end

            if ~isempty(errs)
                error('GeoRealWorldScenarioGuard:invalidConfig', '%s', strjoin(errs, newline));
            end
        end

        function assertRealisticSimulation(cfg)
            % assertRealisticSimulation  MD Stage 93 name; alias for assertValid.
            %   The "realistic synthetic truth-estimation comparison" guard. Kept as an
            %   alias (not a second class) to honour the project no-proliferation rule.
            revgnss.GeoRealWorldScenarioGuard.assertValid(cfg);
        end

        function assertModelFamilyConsistent(cfg)
            % assertModelFamilyConsistent  MD Stage 88/97 family-parity rule.
            %   Errors when the truth dynamics family differs from the EKF dynamics family
            %   UNLESS the run is explicitly labelled a mismatch analysis
            %   (cfg.validation.analysisType='explicitMismatchAnalysis' AND
            %    cfg.validation.allowTruthModelMismatch=true). Reduced-dynamics filtering
            %   (e.g. two-body EKF vs J2 truth) is a legitimate operational choice, but it
            %   must be opted into explicitly, never the silent default. Callers gate WHEN
            %   this runs (see ConfigFactory.finalizeConfig / ReportRunner) so it never
            %   fires on non-realistic runners.
            gs = @(p, d) revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, p, d);
            tf = revgnss.GeoRealWorldScenarioGuard.dynamicsFamily_(gs({'orbit','truth','mode'}, ''));
            ef = revgnss.GeoRealWorldScenarioGuard.dynamicsFamily_(gs({'estimator','dynamics','mode'}, ''));
            if strcmp(tf, ef); return; end
            analysisType = gs({'validation','analysisType'}, '');
            allowMM = revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, {'validation','allowTruthModelMismatch'}, false);
            if strcmpi(analysisType, 'explicitMismatchAnalysis') && allowMM
                return;   % explicitly opted into a reduced-dynamics / mismatch analysis
            end
            error('GeoRealWorldScenarioGuard:modelFamilyMismatch', ...
                ['Truth dynamics family (%s, from orbit.truth.mode) differs from EKF dynamics ', ...
                 'family (%s, from estimator.dynamics.mode). Match the estimator to the truth ', ...
                 'family, or set cfg.validation.analysisType=''explicitMismatchAnalysis'' and ', ...
                 'cfg.validation.allowTruthModelMismatch=true to run an explicit reduced-dynamics ', ...
                 'mismatch analysis.'], tf, ef);
        end

        function audit = auditImperfectionSources(cfg)
            % auditImperfectionSources  MD Stage 95 truth-estimation separation audit.
            %   Returns COMPUTED (never hard-coded) flags describing where the estimator's
            %   imperfection comes from, plus a per-model table for the report. Honest in
            %   every state: reports sameModelFamilies=false / reducedDynamics=true for a
            %   two-body-EKF reduced-dynamics run, and =true / false once truth and EKF match.
            gs = @(p, d) revgnss.GeoRealWorldScenarioGuard.getStr_(cfg, p, d);
            gl = @(p, d) revgnss.GeoRealWorldScenarioGuard.getLogical_(cfg, p, d);
            pick = @revgnss.GeoRealWorldScenarioGuard.pick_;

            tf = revgnss.GeoRealWorldScenarioGuard.dynamicsFamily_(gs({'orbit','truth','mode'}, ''));
            ef = revgnss.GeoRealWorldScenarioGuard.dynamicsFamily_(gs({'estimator','dynamics','mode'}, ''));
            audit.truthDynamicsFamily = tf;
            audit.ekfDynamicsFamily   = ef;
            audit.sameModelFamilies   = strcmp(tf, ef);
            audit.reducedDynamicsWithProcessNoise = ~audit.sameModelFamilies && ...
                ((strcmp(tf,'J2') && strcmp(ef,'twoBody')) || strcmp(ef,'kinematic'));

            audit.mismatchAnalysis = strcmpi(gs({'validation','analysisType'},''), 'explicitMismatchAnalysis') || ...
                gl({'validation','allowTruthModelMismatch'}, false);
            audit.perfectCorrection = strcmpi(gs({'estimator','towerClockMode'},''), 'perfectCorrection');

            % Truth-assisted DIAGNOSTICS: labelled, non-leaking (KAV run, external-attitude ref).
            audit.truthAssistedDiagnostics = gl({'estimator','runKnownAmbiguityValidation'}, false) || ...
                strcmpi(gs({'estimator','diffAtt','referenceMode'},''), 'externalInitialAttitude');
            % Truth LEAKAGE into the main filter: the genuinely forbidden reads.
            audit.truthLeakageInMainFilter = gl({'estimator','knownAmbiguityAttitudeValidation'}, false) || ...
                strcmpi(gs({'estimator','attitudeInitMode'},''), 'knownAttitudeCalibration') || ...
                strcmpi(gs({'estimator','attitudeCarrierMode'},''), 'validationKnownAmbiguity');
            audit.realWorldClaim = gl({'scientificProfile','allowRealWorldClaim'}, false);

            audit.realisticSyntheticTruthEstimationComparison = ...
                (audit.sameModelFamilies || audit.reducedDynamicsWithProcessNoise) && ...
                ~audit.perfectCorrection && ~audit.truthLeakageInMainFilter && ~audit.realWorldClaim;

            % Per-model rows: {model, truthFamily, estimatorFamily, sameFamily?, imperfectionSource}.
            tropOn = gl({'errors','troposphere','enable'}, false);
            ionoOn = gl({'errors','ionosphere','enable'}, false);
            pcoOn  = gl({'effects','antennaPCO','enable'}, false);
            rows = cell(0,5);
            rows(end+1,:) = {'Orbit dynamics', tf, ef, pick(audit.sameModelFamilies,'yes','no'), ...
                'initial state error + covariance, residual-acceleration process noise'};
            rows(end+1,:) = {'Receiver clock', 'stochastic', 'bias+drift EKF states', 'yes', ...
                'initial covariance + clock process noise'};
            rows(end+1,:) = {'Tower clock', 'stochastic', 'noisy delayed product', 'yes', ...
                'product latency/quantisation + bias/drift noise'};
            rows(end+1,:) = {'Troposphere', pick(tropOn,'mapped ZTD','off'), pick(tropOn,'mapped ZTD','off'), ...
                pick(tropOn,'yes','n/a'), 'stochastic ZWD residual'};
            rows(end+1,:) = {'Ionosphere', pick(ionoOn,'mapped 1st-order','off'), pick(ionoOn,'mapped 1st-order','off'), ...
                pick(ionoOn,'yes','n/a'), 'stochastic residual'};
            rows(end+1,:) = {'Antenna PCO', pick(pcoOn,'PCO','off'), pick(pcoOn,'PCO','off'), ...
                pick(pcoOn,'yes','n/a'), 'calibration uncertainty'};
            rows(end+1,:) = {'Carrier ambiguity', 'generated (unknown)', 'estimated float', 'yes', ...
                'unknown float ambiguity states'};
            audit.rows = rows;
        end
    end

    methods (Static, Access = private)
        function fam = dynamicsFamily_(mode)
            % dynamicsFamily_  Map an orbit/EKF dynamics mode string to its model FAMILY.
            m = lower(strtrim(mode));
            switch m
                case {'j2rk4','j2','twobodyj2','two_body_j2'}; fam = 'J2';
                case {'twobody','two_body','twobodyrk4'};      fam = 'twoBody';
                case {'constantvelocity'};                     fam = 'kinematic';
                case {'stationaryecef'};                       fam = 'static';
                otherwise; fam = m;
            end
        end
        function s = pick_(cond, a, b)
            if cond; s = a; else; s = b; end
        end
        function v = getNum_(s, path, def)
            v = revgnss.GeoRealWorldScenarioGuard.get_(s, path, def);
            if isempty(v) || ~isnumeric(v); v = def; end
        end
        function v = getStr_(s, path, def)
            v = revgnss.GeoRealWorldScenarioGuard.get_(s, path, def);
            if isempty(v) || ~ischar(v); v = def; end
        end
        function v = getLogical_(s, path, def)
            v = revgnss.GeoRealWorldScenarioGuard.get_(s, path, def);
            if isempty(v); v = def; else; v = logical(v); end
        end
        function v = get_(s, path, def)
            v = s;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v,path{k})
                    v = v.(path{k});
                else
                    v = def;
                    return;
                end
            end
        end
    end
end
