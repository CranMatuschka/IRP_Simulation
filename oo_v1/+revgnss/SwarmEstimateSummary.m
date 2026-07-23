classdef SwarmEstimateSummary
    % SwarmEstimateSummary  Per-satellite estimate deliverable.
    %
    % Turns the persisted per-secondary estimate diagnostics (SimulationDataStore
    % d.secondaryOrbit.* + d.consistency.centroidNEES) into the honest answer to
    % "compare the position error of each satellite": for every secondary its
    % ABSOLUTE position error, the filter's stated 1-sigma and the +/-3-sigma
    % coverage (does the covariance cover the error?), its RELATIVE baseline error
    % to the chief (the shape quantity two-way ISL sharpens), and its per-satellite
    % NEES. All windowed to the post-convergence tail (default last 50%).
    %
    % Honesty: the ABSOLUTE column is radial<->clock WALL-LIMITED and its covariance
    % is typically OVERCONFIDENT (centroidNeesMean >> 1) -- this is a single-run
    % indicator; the AUTHORITATIVE cross-seed verdict is the MC centroid gate
    % (revgnss.MonteCarloConsistency, result.centroidVerdict). The RELATIVE baseline
    % column is the trustworthy part.
    %
    %   s = revgnss.SwarmEstimateSummary.compute(d)          % d = store.getData()
    %   lines = revgnss.SwarmEstimateSummary.format(s)       % cellstr table

    methods (Static)
        function s = compute(d, tailFrac)
            if nargin < 2 || isempty(tailFrac); tailFrac = 0.5; end
            s = struct('available', false, 'nSecondaries', 0, 'tailFraction', tailFrac, ...
                       'perSat', struct([]), 'centroidNeesMean', NaN, 'note', '');
            if ~revgnss.SwarmEstimateSummary.hasSwarmEstimate_(d); return; end

            % Store arrays are [nSec x nEpoch]; the summary wants [nEpoch x nSec].
            P = d.secondaryOrbit.posError_m.';               % -> [nEpoch x nSec]
            S = d.secondaryOrbit.posSigma_m.';
            B = []; if isfield(d.secondaryOrbit,'baselineError_m') && ~isempty(d.secondaryOrbit.baselineError_m)
                B = d.secondaryOrbit.baselineError_m.'; end
            NE = []; if isfield(d.secondaryOrbit,'neesPos') && ~isempty(d.secondaryOrbit.neesPos)
                NE = d.secondaryOrbit.neesPos.'; end

            nEp = size(P,1); nSec = size(P,2);
            keep = (floor((1 - tailFrac) * nEp) + 1) : nEp;
            if isempty(keep); keep = 1:nEp; end

            s.available = true; s.nSecondaries = nSec;
            perSat = repmat(struct('index',0,'absErrRms_m',NaN,'meanSigma_m',NaN, ...
                'coverage3sigma',NaN,'baselineErrRms_m',NaN,'neesPosMean',NaN), 1, nSec);
            for i = 1:nSec
                perSat(i).index = i + 1;                     % asset index (secondary i is asset i+1)
                e  = P(keep,i);  sg = S(keep,i);
                ge = isfinite(e);
                if any(ge)
                    perSat(i).absErrRms_m = sqrt(mean(e(ge).^2));
                    perSat(i).meanSigma_m = mean(sg(isfinite(sg)));
                    gc = isfinite(e) & isfinite(sg) & sg > 0;
                    if any(gc); perSat(i).coverage3sigma = mean(e(gc) <= 3 * sg(gc)); end
                end
                if ~isempty(B)
                    b = B(keep,i); gb = isfinite(b);
                    if any(gb); perSat(i).baselineErrRms_m = sqrt(mean(b(gb).^2)); end
                end
                if ~isempty(NE)
                    n = NE(keep,i); gn = isfinite(n);
                    if any(gn); perSat(i).neesPosMean = mean(n(gn)); end
                end
            end
            s.perSat = perSat;

            if isfield(d,'consistency') && isfield(d.consistency,'centroidNEES') && ~isempty(d.consistency.centroidNEES)
                c = d.consistency.centroidNEES(:); ck = c(min(keep,numel(c)));
                s.centroidNeesMean = mean(ck(isfinite(ck)));
            end
            s.note = ['ABSOLUTE column is radial<->clock wall-limited; its covariance is a ' ...
                'single-run indicator (centroid NEES>>1 => overconfident). The authoritative ' ...
                'cross-seed verdict is the MC centroid gate. RELATIVE baseline is the trustworthy part.'];
        end

        function lines = format(s)
            lines = {};
            if ~isstruct(s) || ~isfield(s,'available') || ~s.available
                lines{end+1} = 'Swarm estimate: not a multi-asset ''position'' run (no per-satellite estimate).';
                return;
            end
            lines{end+1} = sprintf('--- Per-satellite estimate (tail %.0f%%, %d secondaries) ---', ...
                100*s.tailFraction, s.nSecondaries);
            lines{end+1} = '  asset | abs err RMS | mean sigma | +/-3sig cov | baseline err RMS | NEES/dof';
            for i = 1:numel(s.perSat)
                p = s.perSat(i);
                lines{end+1} = sprintf('  GEO-%-2d | %8.2f m  | %8.2f m | %7.0f %%  | %10.3f m     | %8.2g', ...
                    p.index, p.absErrRms_m, p.meanSigma_m, 100*p.coverage3sigma, p.baselineErrRms_m, p.neesPosMean); %#ok<AGROW>
            end
            if isfinite(s.centroidNeesMean)
                lines{end+1} = sprintf('  formation-centroid NEES/dof (single run) = %.3g  (>>1 => absolute overconfident)', s.centroidNeesMean);
            end
            lines{end+1} = ['  NOTE: ' s.note];
        end
    end

    methods (Static, Access = private)
        function tf = hasSwarmEstimate_(d)
            tf = isstruct(d) && isfield(d,'secondaryOrbit') && isstruct(d.secondaryOrbit) && ...
                isfield(d.secondaryOrbit,'posError_m') && ~isempty(d.secondaryOrbit.posError_m);
        end
    end
end
