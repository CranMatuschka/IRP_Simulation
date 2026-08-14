classdef JointConstrainedAttitudeResolver
    % JointConstrainedAttitudeResolver  Rigid-body joint integer/attitude search.
    %
    % WHY THIS EXISTS. BaselineCarrierAmbiguityResolver resolves each
    % (tower, baseline) cell INDEPENDENTLY -- it loops ti, bi and writes
    % ambiguityStatus{ti,bi} with its own RMS and ratio test per cell. That
    % discards the strongest constraint available: all 15 observables
    % (5 towers x 3 baselines) must be explained by ONE rotation of a rigid
    % body whose geometry is known by construction. 15 observables against
    % 3 attitude DOF is massively overdetermined, and a single cell can always
    % be fitted by something, which is why the per-cell ratio came out 1.0229
    % and only 5 of 15 cells fixed.
    %
    % THE DISCRIMINATOR. A one-cycle integer error is lambda ~ 0.19 m at L1.
    % Absorbing it by rotating instead needs a rotation large enough to move the
    % DD by a whole wavelength, and that SAME rotation must then explain the other
    % rows simultaneously. MEASURED on att010 (GEO, 5 towers, 4 antennas, 2 m
    % baselines): the first integer flip needs 22 to 44.5 deg depending on axis,
    % and 0 of 729 candidates over a +/-2 deg window carried a different integer
    % set. Wrong integer sets are not merely rejected here, they are unreachable.
    %
    % THE SURVIVING DEGENERACY IS HARMLESS. Shifting every tower's integer on
    % baseline i by a common k_i and absorbing it into the hardware bias
    % (beta_i -> beta_i - lambda*k_i) is invisible to the joint cost. But it is
    % equally invisible to ATTITUDE, which enters only through (R b_i).e_t, so
    % that combined shift leaves the attitude term untouched. Hence this search
    % works on BETWEEN-TOWER DIFFERENCES, which are free of beta by
    % construction: it never needs the bias calibrated, estimated or deleted.
    %
    % WHAT THIS DELIVERS, AND WHAT IT DOES NOT. It delivers the INTEGERS. It does
    % NOT deliver an attitude: euler_best is a diagnostic and must not be injected
    % into the filter. MEASURED DD attitude sensitivity on the reference geometry
    % is 1.1 / 5.4 / 1.7 mm per deg on the three axes -- the between-tower
    % difference throws away roughly 94 % of the 18 / 4.8 / 34.9 mm per deg the
    % single difference carries, because the ~17 deg Earth subtense from GEO makes
    % |e_t - e_p| ~ 0.2. Against a one-epoch DD residual of ~0.076 cycles (14.5 mm)
    % the winning candidate is therefore noise-placed and lands wherever the grid
    % lets it, a CORNER in the measured case. Attitude accuracy comes afterwards,
    % from the EKF running the integer-fixed rows over the whole arc, not from
    % this one epoch.
    %
    % HONEST LIMITS, STATE THEM WHEREVER THIS IS QUOTED.
    %   - Phase wind-up is NOT modelled anywhere in this simulation, and an
    %     integer fix is exactly the operation a slow unmodelled carrier-phase
    %     rotation corrupts. Every fix here is optimistic relative to reality.
    %   - The search is bounded by the attitude prior. Given the flip distances
    %     above the integers survive a prior error many times the window, but a
    %     prior wrong by tens of degrees would fix the wrong set silently, because
    %     with one integer hypothesis in the window the ratio cannot refuse.
    %   - The fix rides on ONE epoch of phase. There is no arc averaging in it and
    %     no re-search after a cycle slip.
    %   - The third axis is geometrically weak and no integer work changes that.

    methods (Static)

        function out = solve(cfgSearch, geom, zSD, cfgLambda)
            % solve  Joint rigid-body integer/attitude search.
            %
            % INPUTS
            %   cfgSearch : struct with fields
            %       windowDeg   [3x1] half-width of the candidate grid (deg)
            %       stepDeg     [3x1] grid step (deg)
            %       ratioThresh scalar, accept only if second/best >= this
            %       maxRmsCycles scalar, reject if best RMS exceeds this
            %   geom      : struct with fields
            %       gFun    function handle g = gFun(eulerCandidate) returning
            %               [nT x nB] modelled single-differenced range
            %               (antenna ai vs antenna 1) in METRES, for the
            %               candidate attitude. This is the ONLY geometry
            %               dependency, so the caller owns towers, lever arms
            %               and the satellite position estimate.
            %       euler0  [3x1] prior attitude (rad), centre of the grid
            %       active  [nT x nB] logical, which cells have data
            %   zSD       : [nT x nB] observed single-differenced carrier (m)
            %   cfgLambda : struct with field lambda_m (L1 wavelength, m)
            %
            % OUTPUT (struct)
            %   accepted, euler_best, N_dd, rmsBest_cycles, rmsSecond_cycles,
            %   ratio, nCandidates, nRowsUsed, pivotTower, classification
            out = revgnss.JointConstrainedAttitudeResolver.emptyResult_();
            if ~isstruct(cfgSearch) || ~isstruct(geom) || isempty(zSD); return; end
            lam = cfgLambda.lambda_m;
            if ~isfinite(lam) || lam <= 0; return; end

            [nT, nB] = size(zSD);
            active = geom.active;
            % A baseline needs at least two towers or it cannot be differenced.
            useB = false(1, nB);
            for bi = 1:nB
                useB(bi) = sum(active(:, bi)) >= 2;
            end
            if ~any(useB); out.classification = 'noDifferenceableBaseline'; return; end

            % Build the candidate grid around the prior.
            w = cfgSearch.windowDeg(:) * pi/180;
            s = cfgSearch.stepDeg(:)   * pi/180;
            ax = cell(3,1);
            for k = 1:3
                if s(k) <= 0; ax{k} = 0; else; ax{k} = -w(k):s(k):w(k); end
            end
            [G1, G2, G3] = ndgrid(ax{1}, ax{2}, ax{3});
            cand = [G1(:) G2(:) G3(:)];
            nC = size(cand, 1);
            out.nCandidates = nC;
            if nC < 2; out.classification = 'degenerateGrid'; return; end

            costs = inf(nC, 1);
            Nstore = cell(nC, 1);
            nRowsUsed = 0; pivotTower = 0;

            for ci = 1:nC
                eulC = geom.euler0(:) + cand(ci, :).';
                g = geom.gFun(eulC);              % [nT x nB] modelled SD, metres
                if isempty(g) || ~isequal(size(g), [nT nB]); continue; end
                sse = 0; nUse = 0;
                Ndd = zeros(nT, nB);
                for bi = 1:nB
                    if ~useB(bi); continue; end
                    tIdx = find(active(:, bi));
                    p = tIdx(1);                  % pivot tower for this baseline
                    if pivotTower == 0; pivotTower = p; end
                    % Between-tower difference kills the hardware bias exactly.
                    dObs = (zSD(tIdx, bi) - zSD(p, bi));
                    dMod = (g(tIdx, bi)   - g(p, bi));
                    % Given the candidate attitude, the integer follows by
                    % rounding -- this is where the rigid-body constraint acts,
                    % because the SAME attitude must round every row correctly.
                    nFloat = (dObs - dMod) / lam;
                    nInt   = round(nFloat);
                    resid  = nFloat - nInt;       % cycles
                    % Drop the pivot's own zero row from the cost.
                    keep = true(numel(tIdx), 1); keep(1) = false;
                    sse  = sse + sum(resid(keep).^2);
                    nUse = nUse + sum(keep);
                    Ndd(tIdx, bi) = nInt;
                end
                if nUse < 1; continue; end
                costs(ci)  = sqrt(sse / nUse);    % joint RMS in cycles
                Nstore{ci} = Ndd;
                nRowsUsed  = nUse;
            end

            if all(~isfinite(costs)); out.classification = 'noCandidateScored'; return; end
            [sorted, order] = sort(costs, 'ascend');
            best = order(1);
            out.rmsBest_cycles = sorted(1);
            out.nRowsUsed  = nRowsUsed;
            out.pivotTower = pivotTower;
            out.euler_best = geom.euler0(:) + cand(best, :).';
            out.N_dd       = Nstore{best};

            % THE RATIO MUST COMPARE INTEGER SETS, NOT NEIGHBOURING ATTITUDES.
            % The grid here is over ATTITUDE, so the runner-up candidate is an
            % adjacent attitude half a step away, and on this geometry it carries
            % the SAME integers. sorted(2)/sorted(1) then measures the CURVATURE of
            % the cost surface in attitude, which is not the question a ratio test
            % is asked. Measured on att010 at GEO with 2 m baselines: 0 of 729
            % candidates over a +/-2 deg window produced an integer set different
            % from the winner's, the first flip needing 22-44 deg of rotation, and
            % the neighbour ratio came out 1.0012 -- so the old test refused a fix
            % that was not merely unambiguous but maximally so.
            %
            % The competing hypotheses are the distinct INTEGER SETS. So the ratio
            % is the best cost achieved by any candidate whose integers differ from
            % the winner's, over the winner's cost. When no such candidate exists
            % the integer solution is unique over the searched window, the ratio is
            % infinite, and refusing is not available -- there is nothing to confuse
            % it with. That is exactly the discriminator a per-cell fix throws away:
            % a single cell can always be fitted by something, and att003's
            % per-cell ratio of 1.0229 on a 0.0607 cycle residual is what that
            % looks like.
            out.neighbourRatio = NaN;                 % diagnostic ONLY, see above
            if numel(sorted) >= 2 && sorted(1) > 0
                out.neighbourRatio = sorted(2) / sorted(1);
            end
            Nbest = Nstore{best};
            altIdx = 0;
            for si = 2:numel(order)
                ci = order(si);
                if isempty(Nstore{ci}); continue; end
                if ~isequal(Nstore{ci}, Nbest); altIdx = si; break; end
            end
            out.nDistinctIntegerSets = revgnss.JointConstrainedAttitudeResolver. ...
                countDistinctIntegerSets_(Nstore);
            out.integerUniqueOverWindow = (altIdx == 0);
            if altIdx == 0
                out.rmsSecondIntegerSet_cycles = Inf;
                out.ratio = Inf;
            else
                out.rmsSecondIntegerSet_cycles = sorted(altIdx);
                if out.rmsBest_cycles > 0
                    out.ratio = sorted(altIdx) / out.rmsBest_cycles;
                else
                    out.ratio = Inf;
                end
            end
            % Kept for continuity with the earlier reporting, but it is the
            % neighbouring-attitude cost, NOT the runner-up hypothesis.
            out.rmsSecond_cycles = sorted(min(2, numel(sorted)));

            % Two independent gates, both must pass. The RMS gate asks "does the
            % winner actually fit"; the ratio gate asks "is it distinguishable from
            % the best COMPETING INTEGER SET".
            %
            % THE RMS GATE HAS TO BE SCALED, AND A FIXED CYCLE COUNT CANNOT DO IT.
            % resid = nFloat - round(nFloat) is bounded to [-0.5, 0.5] BY
            % CONSTRUCTION, so the cost can never exceed 0.5 however wrong the
            % attitude or the integers are, and residuals that are uniform on that
            % interval -- i.e. pure noise, no signal whatsoever -- give an RMS of
            % 1/sqrt(12) = 0.2887. The inherited threshold of 0.30 cycles sits ABOVE
            % that null, so it could not refuse random data. Paired with a ratio that
            % is correctly +Inf whenever the integer set is unique over the window
            % (which is the normal case at GEO: 0 of 729 candidates differ), that left
            % acceptance unconditional. A gate that cannot refuse is not a gate.
            %
            % So the real gate is the expected DD noise: sigma_DD = 2*sigma_phi, and
            % the residual after a CORRECT fix is that, in cycles.
            %
            % GATE THE STATISTIC, NOT THE ROW. The cost is an RMS over nRowsUsed rows,
            % and an RMS concentrates: for n iid N(0, s) samples its mean is ~s and its
            % standard deviation is ~s/sqrt(2n). So k sigma on the STATISTIC is
            % s*(1 + k/sqrt(2n)), NOT k*s. k*s was the first attempt here and it did
            % NOT bind: with s = 0.1051 cycles it put the gate at 0.3153, above the
            % 0.30 outer bound, so min() handed back 0.30 and the gate stayed inert.
            % The log line prints the operative gate precisely so that this failure is
            % visible instead of assumed away.
            %
            % Measured on att010: s = 0.105101 cycles -- sigma_phi resolves to 0.010 m
            % in this scenario, NOT masterConfig's 0.005 -- and n = 12, so the 3-sigma
            % gate is 0.1695. The winner sits at 0.076065, i.e. 0.72 s, a fit slightly
            % TIGHTER than the assigned noise, while the 0.2887 null is now refused.
            rmsGate = cfgSearch.maxRmsCycles;
            out.expectedRms_cycles = NaN;
            if isfield(cfgLambda,'ddSigma_cycles') && isfinite(cfgLambda.ddSigma_cycles) ...
                    && cfgLambda.ddSigma_cycles > 0 && out.nRowsUsed >= 1
                k = 3.0;
                if isfield(cfgSearch,'maxRmsSigmaMultiple') && ...
                        isfinite(cfgSearch.maxRmsSigmaMultiple) && cfgSearch.maxRmsSigmaMultiple > 0
                    k = cfgSearch.maxRmsSigmaMultiple;
                end
                out.expectedRms_cycles = cfgLambda.ddSigma_cycles;
                rmsGate = min(rmsGate, cfgLambda.ddSigma_cycles * ...
                    (1 + k / sqrt(2 * out.nRowsUsed)));
            end
            out.rmsGate_cycles = rmsGate;
            rmsOk   = out.rmsBest_cycles <= rmsGate;
            ratioOk = out.ratio >= cfgSearch.ratioThresh;
            out.accepted = rmsOk && ratioOk;
            if out.accepted
                out.classification = 'jointRigidBodyFixed';
            elseif ~rmsOk && ~ratioOk
                out.classification = 'rejectedRmsAndRatio';
            elseif ~rmsOk
                out.classification = 'rejectedJointRms';
            else
                out.classification = 'rejectedJointRatio';
            end
        end

    end

    methods (Static, Access = private)
        function out = emptyResult_()
            out = struct( ...
                'accepted',                    false, ...
                'euler_best',                  zeros(3,1), ...
                'N_dd',                        [], ...
                'rmsBest_cycles',              NaN, ...
                'rmsGate_cycles',              NaN, ...
                'expectedRms_cycles',          NaN, ...
                'rmsSecond_cycles',            NaN, ...
                'rmsSecondIntegerSet_cycles',  NaN, ...
                'ratio',                       NaN, ...
                'neighbourRatio',              NaN, ...
                'integerUniqueOverWindow',     false, ...
                'nDistinctIntegerSets',        0, ...
                'nCandidates',                 0, ...
                'nRowsUsed',                   0, ...
                'pivotTower',                  0, ...
                'classification',              'notAttempted');
        end

        function n = countDistinctIntegerSets_(Nstore)
            % countDistinctIntegerSets_  How many integer hypotheses the window holds.
            % One means the fix is unique over the searched attitude range and the
            % ratio test has nothing to compare against; more than one means the
            % ratio is doing real work.
            n = 0; seen = {};
            for k = 1:numel(Nstore)
                if isempty(Nstore{k}); continue; end
                isNew = true;
                for j = 1:numel(seen)
                    if isequal(seen{j}, Nstore{k}); isNew = false; break; end
                end
                if isNew; seen{end+1} = Nstore{k}; n = n + 1; end %#ok<AGROW>
            end
        end
    end
end
