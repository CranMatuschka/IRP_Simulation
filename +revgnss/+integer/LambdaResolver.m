classdef LambdaResolver
    % LambdaResolver  Thin wrapper around the TU Delft LAMBDA 4.0 toolbox.
    %
    % Turns an EKF float-ambiguity block into an integer-fixed vector, with an explicit
    % accept/reject decision. The ILS search itself is NOT reimplemented -- LAMBDA 4.0
    % (Massarweh, Verhagen & Teunissen 2024; Teunissen 1993/1995) is the canonical,
    % peer-reviewed implementation and is called as a black box.
    %
    % EXTERNAL DEPENDENCY -- the toolbox is NOT vendored into this repository.
    %   Its files carry only "Copyright: Geoscience & Remote Sensing department @ TUDelft"
    %   with NO licence grant, so redistributing them here would be unlicensed. It is
    %   therefore treated like the Orekit bridge: a user-installed dependency located via
    %   cfg.estimator.lambda.toolboxPath, with graceful degradation when absent (resolve()
    %   returns the FLOAT solution and says why -- it never errors and never silently
    %   pretends to have fixed anything).
    %   Download: contact LAMBDAtoolbox-CITG-GRS@tudelft.nl
    %
    % THE PRECONDITION THAT MATTERS MOST (docs/plans/ISL_LAMBDA/03 section 1):
    %   LAMBDA finds the integer vector nearest a float vector UNDER THE ASSUMPTION that
    %   the truth is an integer. The UNDIFFERENCED ambiguities in this codebase are NOT:
    %   they absorb the per-arc clock/hardware bias (CarrierMeasurementBuilder.m:280), so
    %   B = lambda*N + bias. Feeding those to LAMBDA "fixes" them to a meaningless integer
    %   and injects a bias-sized error. Callers MUST pass a differenced (or bias-calibrated)
    %   vector. resolve() cannot verify that for you -- but the success-rate gate below
    %   will usually reject such a vector, and assertIntegerParametrisation() makes the
    %   requirement explicit at the call site.
    %
    %   [aFix, info] = revgnss.integer.LambdaResolver.resolve(aHat_cyc, Qa_cyc, cfg)

    methods (Static)

        function tf = isAvailable(cfg)
            % isAvailable  True when the LAMBDA toolbox can actually be called.
            tf = false;
            try
                revgnss.integer.LambdaResolver.addToPath(cfg);
                tf = ~isempty(which('LAMBDA')) && ~isempty(which('decorrelateVC'));
            catch; end
        end

        function p = addToPath(cfg)
            % addToPath  Put the external toolbox on the MATLAB path (idempotent).
            % Adds BOTH the root (LAMBDA.m, Ps_LAMBDA.m) and LAMBDA_toolbox/ (the helpers).
            % Uses fullfile: the shipped examples use a Windows separator
            % ('..\LAMBDA_toolbox', RUN_example_1.m:27) which breaks on macOS/Linux.
            p = '';
            try; p = cfg.estimator.lambda.toolboxPath; catch; end
            if isempty(p) || ~ischar(p) && ~isstring(p); return; end
            p = char(p);
            if ~isfolder(p); return; end
            addpath(p);
            sub = fullfile(p, 'LAMBDA_toolbox');
            if isfolder(sub); addpath(sub); end
        end

        function [aHat_cyc, Qa_cyc] = toCycles(aHat_m, Qa_m, lambda_m)
            % toCycles  Metres -> cycles for both the vector and the FULL covariance.
            %
            %   a_cyc = D * a_m,  Qa_cyc = D * Qa_m * D',   D = diag(1./lambda)
            %
            % The full matrix is required: ILS decorrelation lives or dies on the
            % off-diagonals. (The pre-existing IntegerAmbiguityFixer reads only
            % P(i,i) -- that is integer ROUNDING, the weakest estimator, and is exactly
            % what this wrapper replaces.)
            n = numel(aHat_m);
            lam = lambda_m(:);
            if isscalar(lam); lam = repmat(lam, n, 1); end
            assert(numel(lam) == n, 'LambdaResolver:lambdaSize', ...
                'lambda_m must be scalar or match numel(aHat_m)=%d.', n);
            assert(all(lam > 0), 'LambdaResolver:lambdaPositive', 'lambda_m must be > 0.');
            D = diag(1 ./ lam);
            aHat_cyc = D * aHat_m(:);
            Qa_cyc   = D * Qa_m * D';
            Qa_cyc   = 0.5 * (Qa_cyc + Qa_cyc.');   % symmetrise numerical asymmetry
        end

        function [aFix_cyc, info] = resolve(aHat_cyc, Qa_cyc, cfg)
            % resolve  Integer-fix a float ambiguity vector, or refuse and say why.
            %
            % Returns aFix_cyc = aHat_cyc (i.e. the FLOAT solution) whenever the fix is
            % not accepted, so a caller that ignores info still behaves safely.
            info = revgnss.integer.LambdaResolver.blankInfo_();
            aHat_cyc = aHat_cyc(:);
            aFix_cyc = aHat_cyc;
            info.n = numel(aHat_cyc);
            if info.n == 0; info.decision = 'no-ambiguities'; return; end

            o = revgnss.integer.LambdaResolver.opts_(cfg);
            info.method         = o.method;
            info.minSuccessRate = o.minSuccessRate;

            if ~o.enable
                info.decision = 'disabled-by-config'; return
            end
            if ~revgnss.integer.LambdaResolver.isAvailable(cfg)
                % Graceful degradation: no toolbox -> float, explicitly reported.
                info.decision = 'unavailable-toolbox';
                info.message  = ['LAMBDA 4.0 not found. Set cfg.estimator.lambda.toolboxPath ' ...
                                 'to the toolbox folder (external dependency; not vendored).'];
                return
            end
            info.available = true;

            Qa_cyc = 0.5 * (Qa_cyc + Qa_cyc.');
            if ~all(isfinite(Qa_cyc(:))) || ~all(isfinite(aHat_cyc))
                info.decision = 'reject-nonfinite'; return
            end
            ev = eig(Qa_cyc);
            if any(ev <= 0)
                info.decision = 'reject-notPositiveDefinite';
                info.message  = sprintf('min eig(Qa) = %.3e', min(ev));
                return
            end

            % ---- success rate BEFORE fixing: the honest gate ----------------------
            % Ps_LAMBDA method 1 = Integer Bootstrapping (exact), a rigorous LOWER bound
            % for ILS. Refusing below minSuccessRate is the false-fix protection that the
            % pre-existing IntegerAmbiguityFixer explicitly lacks ("falseFixRisk:false").
            try
                [SR, FR] = Ps_LAMBDA(Qa_cyc, 1, 1);
            catch ME
                info.decision = 'error-successRate';
                info.message  = ME.message; return
            end
            info.successRate = SR;
            info.failureRate = FR;
            if ~isfinite(SR) || SR < o.minSuccessRate
                info.decision = 'reject-lowSuccessRate';
                info.message  = sprintf('SR=%.6f < required %.6f', SR, o.minSuccessRate);
                return
            end

            % ---- the ILS search itself -------------------------------------------
            try
                [aCand, sqnorm, nFixed, srLam, Zmat] = ...
                    LAMBDA(aHat_cyc, Qa_cyc, o.method, o.nCands);
            catch ME
                info.decision = 'error-lambda';
                info.message  = ME.message; return
            end
            info.nFixed     = nFixed;
            info.sqnorm     = sqnorm(:)';
            info.srReported = srLam;
            info.zMatrixOk  = ~isempty(Zmat);

            if isempty(aCand) || nFixed < 1
                info.decision = 'reject-noFix';   % IA estimators legitimately return none
                return
            end

            % PARTIAL FIXES ARE REFUSED -- this is a safety guard, not a limitation.
            % With PAR (method 5) LAMBDA fixes only a SUBSET and returns the CONDITIONED
            % FLOAT for the rest. Those components are real-valued by construction, so
            % rounding them would INVENT integers the estimator explicitly declined to fix,
            % and a caller with applyFix on would then inject them as a millimetre-sigma
            % hard constraint -- fabricated numbers at high confidence. LAMBDA reports only
            % the COUNT nFixed, not which components, so the fixed subset cannot be safely
            % recovered here. Refuse rather than guess.
            % Reachable whenever minSuccessRate < 0.99 (LAMBDA.m:155 hardcodes the internal
            % PAR threshold at 0.99); at the 0.999 default the full-AR branch is forced and
            % this never triggers -- which is exactly why it must be an explicit guard.
            if nFixed < info.n
                info.decision = 'reject-partialFix';
                info.message  = sprintf( ...
                    ['LAMBDA fixed %d of %d components (partial/PAR). The unfixed ones are ' ...
                     'conditioned FLOATS, not integers; injecting them would fabricate ' ...
                     'integers at the constraint sigma. Raise minSuccessRate (>=0.99) or ' ...
                     'use method 3 (full ILS).'], nFixed, info.n);
                return
            end

            % ---- ratio (discrimination) test --------------------------------------
            % Accept only when the best candidate is clearly better than the runner-up.
            if numel(sqnorm) >= 2 && sqnorm(1) > 0
                info.ratio = sqnorm(2) / sqnorm(1);
                if info.ratio < o.ratioThreshold
                    info.decision = 'reject-ratioTest';
                    info.message  = sprintf('ratio=%.3f < %.3f', info.ratio, o.ratioThreshold);
                    return
                end
            end

            aFix_cyc      = aCand(:,1);
            info.accepted = true;
            info.decision = 'accepted';
        end

        function assertIntegerParametrisation(isDifferencedOrCalibrated, context)
            % assertIntegerParametrisation  Make the precondition explicit at the call site.
            %
            % LAMBDA is only VALID on a parametrisation whose truth is integer. In this
            % codebase that means a differenced (between-antenna / between-satellite) or
            % bias-calibrated vector -- NOT the raw undifferenced ambiguity, which absorbs
            % the per-arc clock bias. Call this before resolve() so the assumption is
            % recorded rather than implied.
            if nargin < 2; context = 'ambiguity vector'; end
            assert(islogical(isDifferencedOrCalibrated) && isDifferencedOrCalibrated, ...
                'LambdaResolver:nonIntegerParametrisation', ...
                ['%s is not a differenced or bias-calibrated ambiguity, so its truth is ' ...
                 'NOT an integer (it absorbs the per-arc clock/hardware bias). Fixing it ' ...
                 'would inject a bias-sized error. See docs/plans/ISL_LAMBDA/03.'], context);
        end

    end

    methods (Static, Access = private)

        function o = opts_(cfg)
            o = struct('enable', false, 'method', 3, 'minSuccessRate', 0.999, ...
                'nCands', 2, 'ratioThreshold', 2.0, 'toolboxPath', '');
            try
                L = cfg.estimator.lambda;
                if isfield(L,'enable');         o.enable         = logical(L.enable); end
                if isfield(L,'method');         o.method         = L.method; end
                if isfield(L,'minSuccessRate'); o.minSuccessRate = L.minSuccessRate; end
                if isfield(L,'nCands');         o.nCands         = max(2, round(L.nCands)); end
                if isfield(L,'ratioThreshold'); o.ratioThreshold = L.ratioThreshold; end
                if isfield(L,'toolboxPath');    o.toolboxPath    = L.toolboxPath; end
            catch; end
        end

        function info = blankInfo_()
            info = struct('accepted', false, 'decision', 'not-run', 'message', '', ...
                'n', 0, 'nFixed', 0, 'successRate', NaN, 'failureRate', NaN, ...
                'srReported', NaN, 'ratio', NaN, 'sqnorm', [], 'method', NaN, ...
                'minSuccessRate', NaN, 'available', false, 'zMatrixOk', false);
        end

    end
end
