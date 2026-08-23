classdef StressScenarioFactory
    % StressScenarioFactory  Campaign stress-scenario configuration mutations.
    %
    % All methods take a base config copy and return a mutated copy; no
    % global state is modified.  Campaign runner.

    methods (Static)

        function cfg = applyCase(baseCfg, caseName, seed, dur_s)
            % applyCase  Apply named stress case and seed to baseCfg copy.
            cfg = baseCfg;
            cfg.simulation.seed       = seed;
            cfg.simulation.duration_s = dur_s;
            % Derive sub-seeds so each run is independently reproducible
            try; cfg.measurements.codeNoise.seed = seed + 100; catch; end
            try; cfg.measurements.carrierPhase.seed = seed + 200; catch; end
            % Disable report output for campaign sub-runs
            cfg.report.writePdf = false;
            cfg.report.writeMat = false;
            % Prevent recursive campaign invocation
            cfg.validation.scientificCampaign.enable = false;

            switch caseName
                case 'nominalDualFrequency'
                    % No additional mutation — use base dual-frequency setup
                case 'l1Only'
                    cfg = revgnss.StressScenarioFactory.l1Only_(cfg);
                case 'degradedClockProduct'
                    cfg = revgnss.StressScenarioFactory.degradedClock_(cfg);
                case 'slipInjection'
                    cfg = revgnss.StressScenarioFactory.slipInjection_(cfg);
                case 'reducedTowerGeometry'
                    cfg = revgnss.StressScenarioFactory.reducedGeometry_(cfg);
                otherwise
                    warning('StressScenarioFactory:unknownCase', ...
                        'Unknown campaign case: %s — using base config.', caseName);
            end
        end

    end  % public static

    methods (Static, Access = private)

        function cfg = l1Only_(cfg)
            % Disable L2 carrier; keep L1 only.
            % Must reset per-observable enabledByFrequency masks because
            % the base cfg may have been finalized with [true,true] already.
            nSig = 2;
            try; nSig = numel(cfg.signals.names); catch; end
            if nSig >= 2
                mask = true(1, nSig);
                mask(2:end) = false;
                cfg.signals.enabledMask = mask;
                try; cfg.signals.twoFrequency.enable = false; catch; end
                % Reset per-observable masks so finalizeConfig accepts [true,false].
                try; cfg.measurements.code.enabledByFrequency    = mask; catch; end
                try; cfg.measurements.carrier.enabledByFrequency = mask; catch; end
                try; cfg.measurements.doppler.enabledByFrequency = mask; catch; end
                try; cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency = mask; catch; end
                % Disable L2-dependent IF combination rows
                try; cfg.measurements.code.ionosphereFreeRows.enable    = false; catch; end
                try; cfg.measurements.code.ionosphereFreeRows.useInEkf  = false; catch; end
                try; cfg.measurements.carrier.ionosphereFreeRows.enable = false; catch; end
                try; cfg.diagnostics.codeIonoFreeRows.enable            = false; catch; end
                try; cfg.diagnostics.carrierIonoFreeRows.enable         = false; catch; end
                try; cfg.diagnostics.ifBiasBudget.enable                = false; catch; end
                try; cfg.diagnostics.ionosphereFreeCombination.enable   = false; catch; end
                try; cfg.diagnostics.wideLaneNarrowLane.enable          = false; catch; end
                try; cfg.diagnostics.l2CarrierArchitecture.enable       = false; catch; end
                try; cfg.diagnostics.codeIonoFreeConsistency.enable     = false; catch; end
                try; cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = false; catch; end
            end
            try; cfg.ar.l2CarrierEkfRows.enable = false; catch; end
            if ~isfield(cfg,'diagnostics'); cfg.diagnostics = struct(); end
            cfg.diagnostics.l1OnlyScenario = true;
        end

        function cfg = degradedClock_(cfg)
            % Multiply product clock sigmas by a scale factor (default 3).
            scale = 3.0;
            try; scale = cfg.validation.stress.clockProduct.scaleBiasSigma; catch; end
            scaleDrift = scale;
            try; scaleDrift = cfg.validation.stress.clockProduct.scaleDriftSigma; catch; end
            try
                cfg.clocks.tower.product.sigmaBias_m    = ...
                    cfg.clocks.tower.product.sigmaBias_m    * scale;
                cfg.clocks.tower.product.sigmaDrift_mps = ...
                    cfg.clocks.tower.product.sigmaDrift_mps * scaleDrift;
            catch
                warning('StressScenarioFactory:clockScaleFailed', ...
                    'Clock product sigma scaling skipped — product clock not configured as expected.');
            end
            if ~isfield(cfg,'diagnostics'); cfg.diagnostics = struct(); end
            cfg.diagnostics.degradedClockProductScenario = true;
        end

        function cfg = slipInjection_(cfg)
            % Inject synthetic cycle slips at pre-configured epochs.
            % CarrierMeasurementBuilder reads cfg.validation.stress.slips.
            if ~isfield(cfg,'validation');        cfg.validation = struct(); end
            if ~isfield(cfg.validation,'stress'); cfg.validation.stress = struct(); end
            if ~isfield(cfg.validation.stress,'slips')
                cfg.validation.stress.slips = struct();
            end
            sl = cfg.validation.stress.slips;
            sl.enable = true;
            if ~isfield(sl,'injectEpochs_s');    sl.injectEpochs_s   = [200, 500]; end
            if ~isfield(sl,'magnitude_cycles');  sl.magnitude_cycles = [5, -3];    end
            if ~isfield(sl,'towers');            sl.towers           = [1, 2];     end
            if ~isfield(sl,'signals');           sl.signals          = [1];        end
            sl.nConfiguredEpochs = numel(sl.injectEpochs_s);
            cfg.validation.stress.slips = sl;
            if ~isfield(cfg,'diagnostics'); cfg.diagnostics = struct(); end
            cfg.diagnostics.slipInjectionScenario = true;
        end

        function cfg = reducedGeometry_(cfg)
            % Keep only the first 4 towers (drop tower 5).
            if ~isfield(cfg,'towers'); return; end
            cfg.towers.activeSubset = [1, 2, 3, 4];
            if ~isfield(cfg,'diagnostics'); cfg.diagnostics = struct(); end
            cfg.diagnostics.reducedGeometryScenario = true;
        end

    end  % private static
end
