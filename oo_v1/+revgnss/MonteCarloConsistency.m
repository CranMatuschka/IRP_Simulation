classdef MonteCarloConsistency
    %MONTECARLOCONSISTENCY  Monte-Carlo NEES/NIS filter-consistency harness.
    %   The shipped consistency verdict comes from ONE deterministic run, so its NEES/NIS
    %   is a single sample; chi-squared consistency is only meaningful over an ensemble.
    %   run() draws the initial error from P0, varies the measurement/atmosphere seed
    %   (cfg.simulation.seed) AND the tower/receiver clock-truth realisations
    %   (cfg.simulation.mcSeedOffset), runs the REAL pipeline per draw, pools the
    %   post-burn-in per-epoch NIS (dof = measurement rows) and position NEES (dof = 3),
    %   and band-checks the pooled sums with a two-sided chi-squared interval
    %   (revgnss.ChiSquareConsistency).
    %
    %   Use revgnss.ConfigFactory.matchedErrorBaselineConfig as baseCfg for a two-sided
    %   verdict: masterConfig is conservative-by-design (R/Q inflated) and sits BELOW the
    %   band. Result is labelled 'partialCovarianceAwareSynthetic' -- consistency
    %   evidence, not real-world proof.
    %
    %   result = revgnss.MonteCarloConsistency.run(baseCfg)
    %   result = revgnss.MonteCarloConsistency.run(baseCfg, struct('nSeeds',30,'duration_s',3600))

    methods (Static)

        function result = run(baseCfg, opts)
            if nargin < 2 || isempty(opts); opts = struct(); end
            nSeeds   = revgnss.MonteCarloConsistency.opt_(opts, 'nSeeds', 20);
            conf     = revgnss.MonteCarloConsistency.opt_(opts, 'confidence', 0.99);
            burnFrac = revgnss.MonteCarloConsistency.opt_(opts, 'burnInFraction', 0.5);
            baseSeed = revgnss.MonteCarloConsistency.opt_(opts, 'baseSeed', 1000);
            durOvr   = revgnss.MonteCarloConsistency.opt_(opts, 'duration_s', []);
            % initErrorScale multiplies the drawn initial error WITHOUT changing P0, i.e.
            % it makes the filter's prior over-confident (true error > stated sigma). =1
            % is the honest P0 draw; >1 is a deliberate inconsistency (negative control).
            initScale = revgnss.MonteCarloConsistency.opt_(opts, 'initErrorScale', 1);

            sumNIS = 0; dofNIS = 0; sumNEES = 0; dofNEES = 0; nUsed = 0;
            perSeedNisPerDof = nan(1, nSeeds);

            for j = 1:nSeeds
                cfg = baseCfg;
                if ~isempty(durOvr); cfg.simulation.duration_s = durOvr; end
                cfg.report.writePdf   = false; cfg.report.writeMat = false;
                cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
                cfg.plots.enable      = false;
                try; cfg.validation.scientificCampaign.enable = false; catch; end
                cfg.simulation.seed         = baseSeed + j;
                cfg.simulation.mcSeedOffset = j * 1000;   % vary the clock-truth realisations

                % Draw the initial error from P0 (reuses ScenarioFactory's initialError branch).
                rs = RandStream('mt19937ar', 'Seed', baseSeed + j + 500000);
                cfg.estimator.initialError.pos_m         = initScale * cfg.estimator.P0_pos_m       * randn(rs, 3, 1);
                cfg.estimator.initialError.vel_mps       = initScale * cfg.estimator.P0_vel_mps     * randn(rs, 3, 1);
                cfg.estimator.initialError.euler_deg     = initScale * rad2deg(cfg.estimator.P0_euler_rad * randn(rs, 3, 1));
                cfg.estimator.initialError.omega_radps   = initScale * cfg.estimator.P0_omega_radps * randn(rs, 3, 1);
                cfg.estimator.initialError.clockBias_m   = initScale * cfg.estimator.P0_bRx_m       * randn(rs);
                cfg.estimator.initialError.clockDrift_mps = initScale * cfg.estimator.P0_bdotRx_mps * randn(rs);

                sim = revgnss.ReverseGNSSSimulation(cfg);
                sim.initialize();
                sim.run();
                diag = sim.simData;

                nis  = diag.getNIS();  nis  = nis(:);
                mr   = diag.getNumMeasurementRows(); mr = mr(:);
                nees = diag.getNEES(); nees = nees(:);
                nE   = numel(nis);
                if nE < 4; continue; end
                keep = (floor(burnFrac * nE) + 1) : nE;
                nisK = nis(keep); mrK = mr(keep); neesK = nees(keep);

                gN = isfinite(nisK) & isfinite(mrK) & mrK > 0;
                sumNIS = sumNIS + sum(nisK(gN)); dofNIS = dofNIS + sum(mrK(gN));
                if any(gN); perSeedNisPerDof(j) = sum(nisK(gN)) / sum(mrK(gN)); end

                gE = isfinite(neesK) & neesK >= 0;
                sumNEES = sumNEES + sum(neesK(gE)); dofNEES = dofNEES + 3 * sum(gE);
                nUsed = nUsed + 1;
            end

            result = struct('nSeeds', nSeeds, 'nUsed', nUsed, 'confidence', conf, ...
                'interpretation', 'partialCovarianceAwareSynthetic', ...
                'perSeedNisPerDof', perSeedNisPerDof);

            result.nisSum = sumNIS; result.nisDof = dofNIS;
            result.nisPerDof = sumNIS / max(dofNIS, 1);
            [result.nisBand, result.nisInBand, result.nisBelowBand, result.nisAboveBand] = ...
                revgnss.MonteCarloConsistency.band_(sumNIS, dofNIS, conf);

            result.neesSum = sumNEES; result.neesDof = dofNEES;
            result.neesPerDof = sumNEES / max(dofNEES, 1);
            [result.neesBand, result.neesInBand] = ...
                revgnss.MonteCarloConsistency.band_(sumNEES, dofNEES, conf);
        end
    end

    methods (Static, Access = private)

        function v = opt_(opts, name, default)
            v = default;
            if isstruct(opts) && isfield(opts, name) && ~isempty(opts.(name)); v = opts.(name); end
        end

        function [band, inBand, belowBand, aboveBand] = band_(statSum, dof, conf)
            if dof <= 0
                band = [NaN NaN]; inBand = false; belowBand = false; aboveBand = false; return
            end
            [lo, hi] = revgnss.ChiSquareConsistency.bounds(dof, conf);
            band = [lo, hi];
            inBand    = (statSum >= lo) && (statSum <= hi);
            belowBand = statSum < lo;
            aboveBand = statSum > hi;
        end
    end
end
