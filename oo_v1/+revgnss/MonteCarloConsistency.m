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
    %   For a swarm 'position' run it ALSO pools the Guard C formation-CENTROID NEES across
    %   seeds (result.centroidVerdict / .centroidNeesPerDof / .perSeedCentroidNeesPerDof) --
    %   the authoritative cross-seed absolute-trustworthiness gate that turns Guard C's single-
    %   realisation flag into a defensible statement. Each seed contributes one time-averaged
    %   sample (M independent samples), and the verdict is only VALID with the realism guards
    %   on (divergent atmosphere + truth-side dynamics); otherwise it reads
    %   'inconclusiveMatchedCrutch'. Single-asset runs read 'notApplicable'.
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

            % Guard C cross-seed centroid gate (the authoritative absolute-trustworthiness
            % test). getCentroidNEES() is per-epoch NEES/dof for the formation-centroid
            % position (span 1 = primary+secondaries, span 2 = secondaries only); NaN unless a
            % swarm 'position' run. Each seed contributes ONE sample = its post-burn-in time
            % MEAN, so the M seeds are M INDEPENDENT samples (dof = 3*M). This deliberately
            % does NOT pool per-epoch: the centroid is a slowly-varying rigid-body mode, so
            % per-epoch samples are strongly time-correlated and pooling them would over-count
            % dof and narrow the band into a false verdict. One-mean-per-seed is the textbook
            % Monte-Carlo NEES form (independent runs).
            sumCEN = 0; dofCEN = 0; sumSEC = 0; dofSEC = 0;
            perSeedCentroidNeesPerDof = nan(1, nSeeds);
            perSeedSecCentroidNeesPerDof = nan(1, nSeeds);
            % The centroid gate is only a VALID absolute test with the realism guards on
            % (divergent per-LOS atmosphere + truth-side dynamics). With them off those error
            % sources are matched (absent), so the run is not the full realistic error
            % environment: its centroid NEES cannot certify the absolute either way (matched
            % crutches can hide real error), hence 'inconclusiveMatchedCrutch' regardless of
            % the number -- even though the radial<->clock wall usually leaves it overconfident.
            atmoOn = false; dynOn = false;
            try; atmoOn = logical(baseCfg.multiAsset.towerSecondary.atmosphere.enable); catch; end
            try; dynOn  = logical(baseCfg.multiAsset.injectTruthSideDynamics);          catch; end
            realismGuardsActive = atmoOn && dynOn;

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
                % R-7 (v4): getNEES() is already PER-DOF (SimulationDataStore divides the
                % position NEES by its 3 dof), so pooling sum(neesK) against 3*count made
                % neesPerDof collapse to ~0.33 (a spurious "conservative" verdict, and the
                % true origin of the v3-reported 0.36). Pool the RAW block NEES (3*neesK)
                % against 3 dof/sample -> sum ~ chi2(3*N), neesPerDof ~ 1, valid chi2 band.
                sumNEES = sumNEES + 3 * sum(neesK(gE)); dofNEES = dofNEES + 3 * sum(gE);
                nUsed = nUsed + 1;

                % Guard C centroid gate: one time-averaged sample per seed (3 dof each).
                cen  = diag.getCentroidNEES();          cen  = cen(:);  cenK = cen(keep);
                gC = isfinite(cenK) & cenK >= 0;
                if any(gC)
                    m = mean(cenK(gC));                 % per-dof time-mean, this seed
                    perSeedCentroidNeesPerDof(j) = m;
                    sumCEN = sumCEN + 3 * m; dofCEN = dofCEN + 3;   % one independent 3-dof sample
                end
                sec  = diag.getSecondaryCentroidNEES(); sec  = sec(:);  secK = sec(keep);
                gS = isfinite(secK) & secK >= 0;
                if any(gS)
                    m = mean(secK(gS));
                    perSeedSecCentroidNeesPerDof(j) = m;
                    sumSEC = sumSEC + 3 * m; dofSEC = dofSEC + 3;
                end
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

            % --- Guard C cross-seed centroid gate (formation-centroid absolute position) ---
            result.realismGuardsActive = realismGuardsActive;
            result.centroidAvailable   = dofCEN > 0;
            result.perSeedCentroidNeesPerDof    = perSeedCentroidNeesPerDof;
            result.perSeedSecCentroidNeesPerDof = perSeedSecCentroidNeesPerDof;

            result.centroidNeesSum = sumCEN; result.centroidNeesDof = dofCEN;
            result.centroidNeesPerDof = sumCEN / max(dofCEN, 1);
            [result.centroidNeesBand, result.centroidNeesInBand, ...
                result.centroidNeesBelowBand, result.centroidNeesAboveBand] = ...
                revgnss.MonteCarloConsistency.band_(sumCEN, dofCEN, conf);

            result.secCentroidNeesSum = sumSEC; result.secCentroidNeesDof = dofSEC;
            result.secCentroidNeesPerDof = sumSEC / max(dofSEC, 1);
            [result.secCentroidNeesBand, result.secCentroidNeesInBand] = ...
                revgnss.MonteCarloConsistency.band_(sumSEC, dofSEC, conf);

            result.centroidVerdict = revgnss.MonteCarloConsistency.centroidVerdict_( ...
                result.centroidAvailable, realismGuardsActive, ...
                result.centroidNeesInBand, result.centroidNeesBelowBand, result.centroidNeesAboveBand);
        end
    end

    methods (Static, Access = private)

        function v = opt_(opts, name, default)
            v = default;
            if isstruct(opts) && isfield(opts, name) && ~isempty(opts.(name)); v = opts.(name); end
        end

        function verdict = centroidVerdict_(available, guardsActive, inBand, belowBand, aboveBand)
            % Interpret the pooled cross-seed centroid-NEES band into an absolute-
            % trustworthiness verdict. The gate is only VALID with the realism guards on
            % (else truth==model -> NEES~1 is a matched crutch, not evidence).
            if ~available
                verdict = 'notApplicable';            % no swarm 'position' run -> no centroid
            elseif ~guardsActive
                verdict = 'inconclusiveMatchedCrutch'; % guards off -> centroid NEES is not a test
            elseif aboveBand
                verdict = 'overconfidentAbsolute';    % filter claims better absolute than it has
            elseif belowBand
                verdict = 'conservativeAbsolute';     % under-confident (honest, safe direction)
            elseif inBand
                verdict = 'consistent';               % absolute centroid is trustworthy
            else
                verdict = 'unknown';
            end
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
