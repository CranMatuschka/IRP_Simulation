classdef GuardDecision
    % GuardDecision  A threshold test that cannot be flipped by arithmetic noise.
    %
    % EXECUTION-PLAN A5, AND IT IS A REPRODUCIBILITY DEFECT, NOT A TUNING ISSUE. Measured
    % 2026-08-05: the shape-leakage guard in revgnss.GroundDifferencedRotationSolver is a hard
    % binary -- predLeak > sigTheta -- that decides whether a ~0.5 m geometry correction is
    % applied. On the smoke fixture it sat at 0.0339 against 0.0329 deg, a 3 % margin. Running
    % the SAME scenario serially and with federated.parallel = true perturbed the arithmetic at
    % the 1e-14 level, flipped the comparison, and moved 33 of 148 numeric fields: solvedPos by
    % 0.55 m, jointShapeStep_m by 2x, the beam spot by 3.8 km, coherent gain by 0.99 dB. Any BLAS
    % update, different core count or compiler flag can flip it again.
    %
    % A near-threshold comparison is not a decision, it is a coin flip that moves the answer by
    % half a metre -- and calling the untouched branch "the correct failure mode" only disguises
    % it. THREE OUTCOMES, not two:
    %
    %   'pass'          the value clears the threshold by more than the dead-band
    %   'fail'          it misses by more than the dead-band
    %   'indeterminate' it is INSIDE the dead-band: the data cannot distinguish the two, and
    %                   saying so is the honest answer. The conservative branch is taken, and
    %                   the caller reports the margin so a reader can see how close it was.
    %
    % WHY A DEAD-BAND ACTUALLY FIXES IT, rather than moving the problem to the band edge. The
    % observed perturbation is 1e-14 relative; the band is 10 % relative by default, twelve
    % orders of magnitude wider. A case that lands inside maps deterministically to
    % 'indeterminate' on every machine. Only a case whose margin sits within 1e-14 of the BAND
    % EDGE could still flip -- possible, but no longer the routine occurrence it was at the
    % threshold itself, where any 3 %-margin result was already a coin toss.
    %
    % THE MARGIN IS ALWAYS REPORTED. A guard that passes by 0.1 % and one that passes by 100x
    % are not the same result, and a boolean cannot tell them apart.
    %
    %   d = revgnss.GuardDecision.evaluate(value, threshold, 'ge')   % pass when value >= thr
    %   d = revgnss.GuardDecision.evaluate(value, threshold, 'le', 0.2)
    %       d.outcome        'pass' | 'fail' | 'indeterminate'
    %       d.pass           true only for 'pass' -- 'indeterminate' is NOT a pass
    %       d.margin         signed relative distance from the threshold
    %       d.text           one line, ready to put in a reason string

    properties (Constant)
        DEFAULT_DEAD_BAND = 0.10;    % relative half-width
    end

    methods (Static)

        function d = evaluate(value, threshold, sense, deadBand)
            % evaluate  The three-way test. sense = 'ge' (pass when value >= threshold) or
            % 'le' (pass when value <= threshold).
            if nargin < 3 || isempty(sense); sense = 'ge'; end
            if nargin < 4 || isempty(deadBand)
                deadBand = revgnss.GuardDecision.DEFAULT_DEAD_BAND;
            end
            d = struct('outcome', 'fail', 'pass', false, 'value', value, ...
                'threshold', threshold, 'margin', NaN, 'deadBand', deadBand, ...
                'sense', sense, 'text', '');

            if ~isfinite(value) || ~isfinite(threshold)
                d.outcome = 'fail';
                d.text = sprintf('non-finite (value %.4g, threshold %.4g)', value, threshold);
                return
            end
            scale = max(abs(threshold), realmin);
            rel = (value - threshold)/scale;          % >0 means value exceeds the threshold
            if strcmpi(sense, 'le'); rel = -rel; end  % >0 now always means "toward pass"
            d.margin = rel;

            if abs(rel) <= deadBand
                d.outcome = 'indeterminate'; d.pass = false;
                d.text = sprintf(['INDETERMINATE: %.5g vs threshold %.5g is a %.1f %% margin, ' ...
                    'inside the %.0f %% dead-band -- the data cannot distinguish the two ' ...
                    'branches, so the conservative one is taken'], ...
                    value, threshold, 100*rel, 100*deadBand);
            elseif rel > 0
                d.outcome = 'pass'; d.pass = true;
                d.text = sprintf('%.5g vs threshold %.5g (+%.1f %%)', value, threshold, 100*rel);
            else
                d.outcome = 'fail'; d.pass = false;
                d.text = sprintf('%.5g vs threshold %.5g (%.1f %%)', value, threshold, 100*rel);
            end
        end

        function b = deadBandFor(cfg, path, dflt)
            % deadBandFor  Config lookup with a default, so every guard reads the same knob
            % shape without each one re-implementing the walk.
            if nargin < 3 || isempty(dflt); dflt = revgnss.GuardDecision.DEFAULT_DEAD_BAND; end
            b = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && isnumeric(c) && isfinite(c) && c >= 0; b = double(c); end
        end
    end
end
