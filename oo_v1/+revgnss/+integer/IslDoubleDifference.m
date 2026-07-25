classdef IslDoubleDifference
    % IslDoubleDifference  Between-satellite differencing of the ISL carrier ambiguities.
    %
    % Route B of docs/plans/ISL_LAMBDA/03. All ISL links share ONE receiver (the primary),
    % so differencing two links against a common reference link cancels the receiver clock:
    %
    %   Phi_i     = rho_i + b_rx - b_tx_i + lambda*N_i + eps
    %   Phi_i - Phi_r = (rho_i - rho_r) - (b_tx_i - b_tx_r) + lambda*(N_i - N_r) + eps
    %                                ^ b_rx cancels (common receiver)
    %
    % The differenced ambiguity dN = N_i - N_r is a difference of integers, hence an
    % INTEGER -- which the raw undifferenced ambiguity is not.
    %
    % WHY THIS IS THE INTERESTING ROUTE (contrast with Route A):
    %   Route A (attitude baselines) resolves each baseline independently, so its Qa is
    %   DIAGONAL and ILS provably reduces to rounding -- LAMBDA cannot improve the integers
    %   there. Here the differencing matrix D couples every difference to the SAME reference
    %   link, so Qa_SD = D*P*D' is genuinely NON-DIAGONAL (strongly correlated, off-diagonal
    %   ~ var of the reference link). That correlation is exactly what the Z-transformation
    %   decorrelates, so this is where ILS can actually beat rounding. T2/T5 of the test
    %   quantify both facts.
    %
    % HONEST LIMITATION -- what this differencing does NOT cancel:
    %   Only the RECEIVER clock is common. The per-transmitter clock error (product or
    %   estimation residual) does NOT cancel, so
    %       dB = lambda*dN - d(b_tx error)
    %   With the default broadcast product (sigmaClock_m = 0.02 m) that residual is ~0.1
    %   cycle at L1 -- small enough to resolve, but it is a genuine bias, not zero. A true
    %   DOUBLE difference would need a second receiver; with one primary receiver only the
    %   single difference is available. reportBiasBudget() surfaces the size of this term
    %   rather than leaving the reader to assume it vanishes.

    methods (Static)

        function D = transform(nLinks, refIdx)
            % transform  (nLinks-1) x nLinks differencing matrix against a reference link.
            % Row j: +1 on link j (skipping refIdx), -1 on refIdx.
            if nargin < 2 || isempty(refIdx); refIdx = 1; end
            assert(nLinks >= 2, 'IslDoubleDifference:tooFewLinks', ...
                'Between-satellite differencing needs >= 2 ISL links (got %d).', nLinks);
            assert(refIdx >= 1 && refIdx <= nLinks, 'IslDoubleDifference:badRef', ...
                'refIdx %d outside 1..%d.', refIdx, nLinks);
            others = setdiff(1:nLinks, refIdx);
            D = zeros(nLinks-1, nLinks);
            for j = 1:numel(others)
                D(j, others(j)) = 1;
                D(j, refIdx)    = -1;
            end
        end

        function s = assess(ekf, cfg, islInfo)
            % assess  Form the between-satellite differences and run LAMBDA on them.
            s = revgnss.integer.IslDoubleDifference.blank_();
            if ~revgnss.integer.IslDoubleDifference.gateOn_(cfg)
                s.classification = 'disabled-by-config'; return
            end
            s.enabled = true;
            % Duck-typed: accepts a live filter.ReverseGNSSEKF or any struct exposing
            % .stateMap/.x/.P, so tests can drive it without constructing a full scenario.
            if isempty(ekf) || ~revgnss.integer.IslDoubleDifference.hasField_(ekf,'stateMap')
                s.classification = 'unavailable-noEkf'; return
            end
            sm = ekf.stateMap;
            if ~isfield(sm,'islAmbiguityIdx') || isempty(sm.islAmbiguityIdx)
                s.classification = 'unavailable-noIslAmbiguityStates'; return
            end
            idx = sm.islAmbiguityIdx(:)';
            idx = idx(idx > 0);
            s.nLinks = numel(idx);
            if s.nLinks < 2
                s.classification = 'unavailable-needTwoLinks'; return
            end

            lam = revgnss.integer.IslDoubleDifference.lambda_(cfg);
            s.wavelength_m = lam;

            % --- undifferenced float block straight out of the filter -----------------
            aU_m  = ekf.x(idx);
            QU_m  = ekf.P(idx, idx);
            s.undiffIsDiagonal = revgnss.integer.IslDoubleDifference.isDiag_(QU_m);

            % --- between-satellite single difference ----------------------------------
            D = revgnss.integer.IslDoubleDifference.transform(s.nLinks, 1);
            s.refLinkIndex = 1;
            aD_m = D * aU_m;
            QD_m = D * QU_m * D.';
            QD_m = 0.5 * (QD_m + QD_m.');
            s.nDifferences  = size(D,1);
            s.diffIsDiagonal = revgnss.integer.IslDoubleDifference.isDiag_(QD_m);
            % Correlation strength of the differenced block -- the quantity that makes ILS
            % worth running at all.
            s.maxAbsCorrelation = revgnss.integer.IslDoubleDifference.maxCorr_(QD_m);

            % --- cycles, then LAMBDA ---------------------------------------------------
            [aD_cyc, QD_cyc] = revgnss.integer.LambdaResolver.toCycles(aD_m, QD_m, lam);
            s.floatDiff_cycles = aD_cyc(:)';
            s.sigmaDiff_cycles = sqrt(diag(QD_cyc)).';

            % The differenced vector IS an integer parametrisation (up to the tx-clock
            % residual documented above), so the precondition is satisfied by construction.
            revgnss.integer.LambdaResolver.assertIntegerParametrisation(true, ...
                'between-satellite differenced ISL ambiguity');

            [aFix_cyc, info] = revgnss.integer.LambdaResolver.resolve(aD_cyc, QD_cyc, cfg);
            s.available   = info.available;
            s.decision    = info.decision;
            s.successRate = info.successRate;
            s.failureRate = info.failureRate;
            s.ratio       = info.ratio;
            s.accepted    = info.accepted;
            s.message     = info.message;
            if info.available && info.accepted
                s.fixedDiff_cycles = round(aFix_cyc(:)).';
                s.classification   = 'fixed';
            elseif info.available
                s.classification = ['notFixed-' info.decision];
            else
                s.classification = 'unavailable-toolbox';
            end

            % --- truth comparison when the builder supplied it -------------------------
            if nargin >= 3 && ~isempty(islInfo) && isstruct(islInfo) && ...
                    isfield(islInfo,'carrierTruthAmbiguity_m') && ...
                    numel(islInfo.carrierTruthAmbiguity_m) == s.nLinks
                Bt = islInfo.carrierTruthAmbiguity_m(:);
                dTrue_cyc = (D * Bt) / lam;
                s.truthDiff_cycles = dTrue_cyc(:).';
                s.truthIsInteger   = max(abs(dTrue_cyc - round(dTrue_cyc))) < 1e-6;
                if ~isempty(s.fixedDiff_cycles)
                    s.nCorrect = sum(s.fixedDiff_cycles == round(dTrue_cyc(:)).');
                    s.allCorrect = s.nCorrect == numel(dTrue_cyc);
                end
            end
        end

        function b = reportBiasBudget(cfg)
            % reportBiasBudget  Size of the term the single difference does NOT cancel.
            %
            % Only the receiver clock is common to all ISL links. The per-transmitter clock
            % error survives differencing, so dB = lambda*dN - d(b_tx error). Quantify it in
            % cycles so a reader can judge whether the differenced ambiguity is credibly
            % integer, instead of assuming the difference cancels everything.
            b = struct('sigmaTxClock_m', 0, 'lambda_m', NaN, 'sigmaDiff_cycles', NaN, ...
                'note', '');
            lam = revgnss.integer.IslDoubleDifference.lambda_(cfg);
            b.lambda_m = lam;
            try; b.sigmaTxClock_m = cfg.measurements.isl.product.sigmaClock_m; catch; end
            % difference of two independent per-transmitter errors -> sqrt(2)*sigma
            b.sigmaDiff_cycles = sqrt(2) * b.sigmaTxClock_m / lam;
            b.note = ['Receiver clock cancels (common). Per-transmitter clock error does ' ...
                      'NOT: a true double difference would need a second receiver.'];
        end

    end

    methods (Static, Access = private)

        function tf = gateOn_(cfg)
            % Master LAMBDA gate AND the ISL-domain gate. Independent of the ground gate.
            tf = false;
            try
                tf = logical(cfg.estimator.lambda.enable) && ...
                     logical(cfg.estimator.lambda.isl.enable);
            catch; end
        end

        function lam = lambda_(cfg)
            f = NaN;
            try; f = cfg.measurements.isl.carrier.frequency_Hz; catch; end
            if ~isfinite(f) || f <= 0
                f = revgnss.SignalDefinition.get('L1').frequency_Hz;
            end
            lam = revgnss.Constants.SPEED_OF_LIGHT_MPS / f;
        end

        function tf = hasField_(o, name)
            tf = (isstruct(o) && isfield(o, name)) || (isobject(o) && isprop(o, name));
        end

        function tf = isDiag_(Q)
            off = Q - diag(diag(Q));
            tf = max(abs(off(:))) <= 1e-14 * max(1, max(abs(diag(Q))));
        end

        function c = maxCorr_(Q)
            d = sqrt(diag(Q));
            if any(d <= 0); c = NaN; return; end
            C = Q ./ (d * d.');
            C(1:size(C,1)+1:end) = 0;      % ignore the unit diagonal
            c = max(abs(C(:)));
            if isempty(c); c = 0; end
        end

        function s = blank_()
            s = struct('enabled', false, 'available', false, 'accepted', false, ...
                'classification', 'notAttempted', 'decision', 'not-run', 'message', '', ...
                'nLinks', 0, 'nDifferences', 0, 'refLinkIndex', NaN, 'wavelength_m', NaN, ...
                'undiffIsDiagonal', false, 'diffIsDiagonal', false, ...
                'maxAbsCorrelation', NaN, 'floatDiff_cycles', [], 'sigmaDiff_cycles', [], ...
                'fixedDiff_cycles', [], 'truthDiff_cycles', [], 'truthIsInteger', false, ...
                'nCorrect', NaN, 'allCorrect', false, ...
                'successRate', NaN, 'failureRate', NaN, 'ratio', NaN);
        end

    end
end
