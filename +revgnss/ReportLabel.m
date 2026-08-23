classdef ReportLabel
    % ReportLabel  Human-readable labels for the reverse-GNSS report.
    %
    %   The generated report must never expose internal MATLAB mode strings,
    %   class names, or CamelCase config identifiers. Every raw config/summary
    %   value that would otherwise be printed verbatim is routed through this
    %   adapter, which maps known identifiers to plain-English labels and falls
    %   back to a CamelCase/underscore "prettifier" so an unmapped value is still
    %   rendered as readable words rather than a raw identifier.
    %
    %   Usage:
    %     revgnss.ReportLabel.humanize('ekfFloat')      -> 'float carrier ambiguity EKF'
    %     revgnss.ReportLabel.frameLabel('rac')         -> 'radial / along-track / cross-track'
    %     revgnss.ReportLabel.orbitClassLabel('GEO')    -> 'GEO (geostationary)'
    %
    %   humanize() is the general entry point used everywhere report text is
    %   generated. The category helpers exist for call-site clarity but all
    %   defer to the same dictionary.

    methods (Static)

        function s = humanize(raw)
            % humanize  Map an internal identifier to a plain-English label.
            %   Non-char input returns ''. Whitespace is trimmed. A known
            %   identifier maps via the dictionary; an unknown one is prettified.
            if isstring(raw) && isscalar(raw); raw = char(raw); end
            if ~ischar(raw); s = ''; return; end
            key = strtrim(raw);
            if isempty(key); s = ''; return; end
            d = revgnss.ReportLabel.dictionary_();
            if isKey(d, key)
                s = d(key);
            else
                s = revgnss.ReportLabel.prettify_(key);
            end
        end

        function s = measurementFamilyLabel(raw)
            % measurementFamilyLabel  Label for a code/carrier/Doppler family.
            s = revgnss.ReportLabel.humanize(raw);
        end

        function s = frameLabel(raw)
            % frameLabel  Label for a coordinate frame identifier.
            if isstring(raw) && isscalar(raw); raw = char(raw); end
            if ~ischar(raw); s = ''; return; end
            switch lower(strtrim(raw))
                case 'eci';  s = 'Earth-centred inertial (ECI)';
                case 'ecef'; s = 'Earth-centred Earth-fixed (ECEF)';
                case 'rac';  s = 'radial / along-track / cross-track (RAC)';
                case 'rsw';  s = 'radial / along-track / cross-track (RAC)';
                case 'body'; s = 'spacecraft body frame';
                case 'ned';  s = 'north / east / down (NED)';
                otherwise;   s = revgnss.ReportLabel.humanize(raw);
            end
        end

        function s = orbitClassLabel(raw)
            % orbitClassLabel  Label for an orbit-class identifier.
            if isstring(raw) && isscalar(raw); raw = char(raw); end
            if ~ischar(raw); s = ''; return; end
            switch upper(strtrim(raw))
                case 'GEO'; s = 'GEO (geostationary)';
                case 'MEO'; s = 'MEO (medium Earth orbit)';
                case 'LEO'; s = 'LEO (low Earth orbit)';
                case 'HEO'; s = 'HEO (highly elliptical orbit)';
                otherwise;  s = upper(strtrim(raw));
            end
        end

        function s = enabledLabel(tf)
            % enabledLabel  'enabled' / 'disabled' from a logical.
            if islogical(tf) || isnumeric(tf)
                if any(tf(:)); s = 'enabled'; else; s = 'disabled'; end
            else
                s = revgnss.ReportLabel.humanize(tf);
            end
        end

    end

    methods (Static, Access = private)

        function d = dictionary_()
            % dictionary_  Cached raw->human map. Built once per session.
            persistent D
            if ~isempty(D); d = D; return; end
            m = containers.Map('KeyType', 'char', 'ValueType', 'char');

            % --- Measurement / observable families ---
            m('singleFrequency')        = 'single-frequency code';
            m('dualFrequency')          = 'two-frequency code';
            m('ionosphereFree')         = 'ionosphere-free code';
            m('ionoFreeCode')           = 'ionosphere-free code';
            m('off')                    = 'disabled';
            m('none')                   = 'none';
            m('diagnostic')             = 'diagnostic only (not in filter)';
            m('ekfFloat')               = 'float carrier ambiguity EKF';

            % --- Ambiguity state layout ---
            m('floatPerTowerSignal')            = 'one float ambiguity per tower and signal';
            m('floatPerTowerReceiverSignal')    = 'one float ambiguity per tower, receiver and signal';

            % --- Receiver / clock architecture ---
            m('spacecraftReceiverClockOnly')    = 'spacecraft receiver clock only';
            m('includeTowerClocksInEKF')        = 'spacecraft and tower clocks estimated';
            m('perfectTruth')                   = 'perfect (truth) tower clocks';
            m('perfectCorrection')              = 'perfect tower-clock correction';
            m('truthHistoryProductNoisy')       = 'synthetic broadcast tower-clock product (noisy)';
            m('noisyCorrection')                = 'noisy tower-clock correction';

            % --- Clock gauge ---
            m('externalTowerCorrections')       = 'external tower-clock corrections';
            m('fixReferenceTower')              = 'fixed reference tower';
            m('meanGroundClockGauge')           = 'mean ground-clock gauge';

            % --- Atmosphere ---
            m('simpleMapped')                   = 'mapped zenith delay';
            m('saastamoinen')                   = 'Saastamoinen zenith delay';
            m('syntheticSimpleMappedV1')        = 'synthetic mapped zenith delay';
            m('syntheticKnownZero')             = 'synthetic, known and zero';

            % --- Attitude estimation ---
            m('carrierLeverArmQuaternionEkf')   = 'carrier lever-arm quaternion EKF';
            m('starTrackerGyroscope')           = 'star tracker and inertial gyroscope';
            m('coarseBaselineIntegerSearch')    = 'coarse baseline integer search';
            m('calibratedDifferentialAmbiguity')= 'calibrated differential ambiguity';
            m('rawL1Only')                      = 'raw L1 only';
            m('controlledRawCarrier')           = 'guarded raw-carrier integer fixing';
            m('rawDualFrequencyPair')           = 'raw L1+L2 integer pair';
            m('fixedDualFrequencyRawAll')       = 'fixed L1+L2 (all baselines)';
            m('mixedFixedFloat')                = 'mixed fixed / float';
            m('useFixedOnlyOrExplicitMixed')    = 'fixed-only or explicit mixed';
            m('screenedNotFormal')              = 'screened (not a formal integer test)';
            m('notCalibratedExternalProduct')   = 'not independently calibrated';
            m('neglectedShortBaselineV1')       = 'neglected (short baselines)';

            % --- Orbit / dynamics ---
            m('twoBody')                        = 'two-body';
            m('twoBodyRk4')                     = 'two-body (RK4)';
            m('j2')                             = 'J2';
            m('j2Rk4')                          = 'J2 (RK4)';
            m('j2Rk4DefaultOrConfigured')       = 'J2 (RK4)';
            m('j2TruthJ2EstimatorSameForceFamily') = 'J2 truth and filter use the same force family';
            m('twoBodyDefaultJ2Available')      = 'two-body default (J2 available)';
            m('constantOmegaV1')                = 'constant Earth-rotation rate';

            % --- Light-time / Sagnac / Doppler ---
            m('sagnacFirstOrder')               = 'first-order Sagnac';
            m('iterativeOneWay')                = 'iterative one-way light-time';
            m('geometricLightTime')             = 'geometric light-time';
            m('firstOrderCorrection')           = 'first-order correction';
            m('simplifiedV1')                   = 'simplified';
            m('frameConsistentV2')              = 'frame-consistent range-rate';
            m('notImplementedNoIERS')           = 'not implemented (no IERS/EOP)';
            m('notImplemented')                 = 'not implemented';
            m('notApplied')                     = 'not applied';
            m('notApplicable')                  = 'not applicable';
            m('notEvaluated')                   = 'not evaluated';
            m('notAvailable')                   = 'not available';

            % --- Covariance / residual policies ---
            m('diagonalOnly')                   = 'diagonal only';
            m('blockTowerClockProduct')         = 'block covariance for shared tower-clock product';
            m('simplifiedV1NotApplied')         = 'simplified (not applied)';
            m('arcBiasAbsorbsConstantProductBias') = 'arc ambiguity absorbs constant product bias';
            m('rawResidualJump')                = 'raw residual jump';
            m('modelStepCompensatedResidualJump') = 'model-step-compensated residual jump';
            m('partialCovarianceAware')         = 'partially covariance-aware';
            m('fullCovarianceAware')            = 'fully covariance-aware';

            % --- Attitude parameterisation ---
            m('quaternionErrorState')           = 'quaternion error-state';
            m('eulerZYX')                       = 'Euler Z-Y-X';

            % --- Scientific profile / claim ---
            m('singleAssetOneWaySyntheticClosedV1') = 'single-asset one-way synthetic closed-loop';
            m('controlledSynthetic')            = 'controlled synthetic scenario';
            m('blockedWithReasons')             = 'blocked (with stated reasons)';

            D = m; d = m;
        end

        function s = prettify_(raw)
            % prettify_  Safety net: turn an unmapped identifier into words.
            %   Splits camelCase and underscores into space-separated words and
            %   normalises trailing version tags (e.g. 'fooBarV2' -> 'foo bar (v2)').
            s = raw;
            s = strrep(s, '_', ' ');
            % Insert a space before each internal capital letter or digit run.
            s = regexprep(s, '([a-z])([A-Z])', '$1 $2');
            s = regexprep(s, '([A-Za-z])([0-9])', '$1 $2');
            s = regexprep(s, '([0-9])([A-Za-z])', '$1 $2');
            s = lower(strtrim(s));
            % Re-tag a standalone version token as "(vN)".
            s = regexprep(s, '\<v ?([0-9]+)\>', '(v$1)');
            if isempty(s); s = raw; return; end
            % Capitalise only the first character for a sentence-like label.
            s(1) = upper(s(1));
        end

    end
end
