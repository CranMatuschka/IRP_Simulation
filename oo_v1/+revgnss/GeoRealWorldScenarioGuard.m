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
    end

    methods (Static, Access = private)
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
