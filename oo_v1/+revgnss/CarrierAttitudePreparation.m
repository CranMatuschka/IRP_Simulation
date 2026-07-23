classdef CarrierAttitudePreparation
    % CarrierAttitudePreparation  carrier-phase attitude preparation audit.
    %
    % Assesses whether the carrier measurement stack is configured to support
    % attitude-mode selection.  L2 carrier EKF, integer fixing, and quaternion
    % states are NOT implemented in v1.
    %
    % Usage:
    %   s     = revgnss.CarrierAttitudePreparation.assess(out, cfg);
    %   lines = revgnss.CarrierAttitudePreparation.summaryLines(s);

    methods (Static)

        function s = assess(out, cfg)
            % assess  Return carrier attitude preparation status struct.
            s = revgnss.CarrierAttitudePreparation.blank_();
            if nargin < 2 || isempty(out) || isempty(cfg)
                s.warnings{end+1} = 'out or cfg empty.';
                return
            end
            s.enabled          = true;
            s.measurementModes = revgnss.CarrierAttitudePreparation.measurementModeSummary(cfg);
            % Delegate row/ambiguity inventory to the carrier row metadata helper.
            inv39 = revgnss.CarrierRowMetadataInventory.inventory(out, cfg);
            s.rowInv.carrierRowMetadataAvailable = inv39.rowMetadataAvailable;
            s.rowInv.carrierRowCount             = inv39.carrierRowCount;
            s.rowInv.diffAttRowCount             = inv39.differentialAttitudeRowCount;
            s.rowInv.warnings                    = {};
            s.ambInv.ambiguityMetadataAvailable  = inv39.ambiguityMetadataAvailable;
            s.ambInv.nAmbiguities                = inv39.ambiguityStateCount;
            s.ambInv.ambiguityMode               = inv39.ambiguityMode;
            s.ambInv.nSignals                    = 1;
            s.ambInv.warnings                    = {};
            if isfield(out,'summary') && isfield(out.summary,'nReceivers')
                s.nReceivers = out.summary.nReceivers;
            elseif isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                s.nReceivers = cfg.scenario.nReceivers;
            end
            try
                g = revgnss.ReceiverGeometry.fromConfig(cfg);
                s.receiverGeometryRank = revgnss.AttitudeScenarioReadiness.geometryRank(g);
            catch ex
                s.warnings{end+1} = ['geometry: ' ex.message];
            end
            s.warnings = [s.warnings, inv39.warnings];
            s.classification = revgnss.CarrierAttitudePreparation.classify_(s);
            s.readyLevel     = revgnss.CarrierAttitudePreparation.levelFor_(s.classification);
        end

        function m = measurementModeSummary(cfg)
            % measurementModeSummary  Extract carrier-mode settings from cfg.
            m.carrierEnabled                  = false;
            m.carrierMode                     = 'none';
            m.ambiguityMode                   = 'none';
            m.attitudeCarrierMode             = 'none';
            m.hasCarrierFloat                 = false;
            m.hasCalibDiffMode                = false;
            m.hasKnownAmbiguityValidationOnly = false;
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase')
                    m.carrierEnabled = logical(cfg.measurements.carrierPhase.enable);
                end
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode')
                    m.carrierMode     = cfg.measurements.carrierMode;
                    m.hasCarrierFloat = strcmp(m.carrierMode,'ekfFloat');
                end
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    m.ambiguityMode = cfg.estimation.ambiguityMode;
                end
                if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeCarrierMode')
                    m.attitudeCarrierMode = cfg.estimator.attitudeCarrierMode;
                    m.hasCalibDiffMode    = strcmp(m.attitudeCarrierMode, ...
                        'calibratedDifferentialAmbiguity');
                end
                if isfield(cfg,'estimator') && isfield(cfg.estimator,'runKnownAmbiguityValidation')
                    m.hasKnownAmbiguityValidationOnly = ...
                        logical(cfg.estimator.runKnownAmbiguityValidation) && ~m.hasCarrierFloat;
                end
            catch; end
        end

        function inv = rowInventory(out)
            % rowInventory  Count carrier rows from out.summary.
            inv = struct('carrierRowMetadataAvailable',false,'carrierRowCount',NaN, ...
                         'diffAttRowCount',NaN,'warnings',{{}});
            try
                s = out.summary;
                if isfield(s,'totalCarrierRows') && isfield(s,'totalDiffAttRows')
                    inv.carrierRowCount             = s.totalCarrierRows;
                    inv.diffAttRowCount             = s.totalDiffAttRows;
                    inv.carrierRowMetadataAvailable = true;
                else
                    inv.warnings{end+1} = 'Carrier row count unavailable in summary.';
                end
            catch ex
                inv.warnings{end+1} = ['rowInventory: ' ex.message];
            end
        end

        function inv = ambiguityInventory(out, cfg)
            % ambiguityInventory  Derive ambiguity state count from summary and cfg.
            inv = struct('ambiguityMetadataAvailable',false,'nAmbiguities',NaN, ...
                         'ambiguityMode','unknown','nSignals',1,'warnings',{{}});
            try
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    inv.ambiguityMode = cfg.estimation.ambiguityMode;
                end
                s = out.summary;
                if isfield(s,'nTowers') && isfield(s,'nReceivers')
                    nT = s.nTowers;  nR = s.nReceivers;
                    if strcmp(inv.ambiguityMode,'floatPerTowerReceiverSignal')
                        inv.nAmbiguities = nT * nR;
                    else
                        inv.nAmbiguities = nT;
                    end
                    inv.ambiguityMetadataAvailable = true;
                else
                    inv.warnings{end+1} = 'nTowers/nReceivers not in summary.';
                end
            catch ex
                inv.warnings{end+1} = ['ambiguityInventory: ' ex.message];
            end
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array for report embedding.
            lines = {};
            if ~s.enabled
                lines{end+1} = 'CarrierAttitudePreparation: unavailable'; return
            end
            m = s.measurementModes;
            lines{end+1} = sprintf('Classification   : %s', s.classification);
            lines{end+1} = sprintf('ReadyLevel       : %d', s.readyLevel);
            lines{end+1} = sprintf('nReceivers       : %d', s.nReceivers);
            lines{end+1} = sprintf('GeometryRank     : %d', s.receiverGeometryRank);
            lines{end+1} = sprintf('CarrierEnabled   : %s', mat2str(m.carrierEnabled));
            lines{end+1} = sprintf('CarrierMode      : %s', m.carrierMode);
            lines{end+1} = sprintf('AmbiguityMode    : %s', m.ambiguityMode);
            lines{end+1} = sprintf('AttCarrierMode   : %s', m.attitudeCarrierMode);
            lines{end+1} = sprintf('HasCarrierFloat  : %s', mat2str(m.hasCarrierFloat));
            lines{end+1} = sprintf('L2EKFImpl        : %s', mat2str(s.l2CarrierEkfImplemented));
            lines{end+1} = sprintf('IntFixImpl       : %s', mat2str(s.integerFixingImplemented));
            inv = s.rowInv;
            if inv.carrierRowMetadataAvailable
                lines{end+1} = sprintf('CarrierRows      : %d', inv.carrierRowCount);
                lines{end+1} = sprintf('DiffAttRows      : %d', inv.diffAttRowCount);
            else
                lines{end+1} = 'CarrierRows      : unavailable';
            end
            ainv = s.ambInv;
            if ainv.ambiguityMetadataAvailable
                lines{end+1} = sprintf('nAmbiguities     : %d', ainv.nAmbiguities);
            else
                lines{end+1} = 'nAmbiguities     : unavailable';
            end
            for w = s.warnings
                lines{end+1} = sprintf('[warn] %s', w{1}); %#ok<AGROW>
            end
        end

    end

    methods (Static, Access = private)

        function cls = classify_(s)
            m = s.measurementModes;
            if ~m.carrierEnabled
                cls = 'not-ready-carrier-disabled'; return
            end
            if s.nReceivers < 2
                cls = 'not-ready-single-receiver'; return
            end
            if s.receiverGeometryRank < 2
                cls = 'not-ready-no-baseline-geometry'; return
            end
            if s.rowInv.carrierRowMetadataAvailable && s.rowInv.carrierRowCount == 0
                cls = 'blocked-missing-row-metadata'; return
            end
            if m.hasKnownAmbiguityValidationOnly
                cls = 'validation-known-ambiguity-only'; return
            end
            if m.hasCalibDiffMode && ~m.hasCarrierFloat
                cls = 'calibrated-differential-only'; return
            end
            if m.hasCarrierFloat
                cls = 'diagnostic-float-carrier'; return
            end
            cls = 'inconsistent';
        end

        function lv = levelFor_(cls)
            switch cls
                case {'unavailable', 'inconsistent'}
                    lv = 0;
                case {'not-ready-carrier-disabled', 'not-ready-single-receiver', ...
                      'not-ready-no-baseline-geometry', 'blocked-missing-row-metadata'}
                    lv = 1;
                case {'validation-known-ambiguity-only', 'calibrated-differential-only'}
                    lv = 2;
                case 'diagnostic-float-carrier'
                    lv = 3;
                case 'ready-for-l2-architecture'
                    lv = 4;
                otherwise
                    lv = 0;
            end
        end

        function s = blank_()
            s.enabled                  = false;
            s.classification           = 'unavailable';
            s.readyLevel               = 0;
            s.nReceivers               = 0;
            s.receiverGeometryRank     = 0;
            s.measurementModes         = struct();
            s.rowInv                   = struct('carrierRowMetadataAvailable',false, ...
                'carrierRowCount',NaN,'diffAttRowCount',NaN,'warnings',{{}});
            s.ambInv                   = struct('ambiguityMetadataAvailable',false, ...
                'nAmbiguities',NaN,'ambiguityMode','unknown','nSignals',1,'warnings',{{}});
            s.l2CarrierEkfImplemented  = false;
            s.integerFixingImplemented = false;
            s.warnings                 = {};
        end

    end
end
