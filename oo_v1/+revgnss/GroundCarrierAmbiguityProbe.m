classdef GroundCarrierAmbiguityProbe
    % GroundCarrierAmbiguityProbe  Can the ground double-differenced carrier integers be FIXED?
    %
    % THIS IS A MEASUREMENT, NOT AN ESTIMATOR. It answers exactly one question and deliberately
    % builds nothing else: given the relative geometry the ISL layer actually produced, does the
    % predicted double difference land within half a wavelength of the true one often enough to
    % round to the correct integer? Success rate is directly comparable to the SR figures already
    % on record for this project (ground attitude AR = 1.000, ISL DD = 0.001).
    %
    % WHY THIS IS THE CRUX. The code-only rotation solve is measured and capped: 1.1x from the
    % 3-parameter solver, 1.53x from the joint solve, both far below what is needed. Carrier phase
    % is 500x more precise but ambiguous, and the previous attempt (Route 1) died because FLOAT
    % ambiguities absorbed the rotation. Fixing the integers instead of floating them is the one
    % change that could revive it -- so measure whether they fix, before building anything that
    % assumes they do.
    %
    % WHY WIDE-LANE FIRST. The DD prediction error from run20's measured geometry is
    %   0.23 * sqrt(shape^2 + rotationDisplacement^2) = 0.23 * sqrt(0.074^2 + 0.64^2) = 0.148 m
    % against half-wavelengths of 0.431 m (wide-lane) and 0.095 m (L1). Wide-lane clears by 2.9x
    % and L1 does not, which is the whole reason the ladder starts at wide-lane. Note the weak
    % tower geometry -- |u_m - u_l| ~ 0.23 because the towers span only 13 deg from GEO -- costs
    % signal but DE-MAGNIFIES the geometry error by 4.4x, which is what makes fixing possible.
    %
    % HONESTY. The carrier observable is SYNTHESISED here from the recorded truth geometry, the
    % same way revgnss.GroundDifferencedRotationSolver synthesises the code observable, because
    % nothing measurement-side survives a federated run. The integers are drawn per
    % (satellite, tower) and held constant over the arc -- no cycle slips are modelled, so this
    % is an UPPER BOUND on fix rate. Truth enters the observable; the prediction sees only
    % rel.solvedPos and the tower positions.
    %
    % COUNTED TRIALS ARE NOT INDEPENDENT TRIALS, and the fix rate must never be quoted as though
    % they were. The dominant DD error is the arc-correlated geometry error, not thermal noise:
    % the code's own sigma predicts a 2.9e-10 failure rate at 6.3 sigma while the measured rate
    % was 3.7e-5, a factor of 1e5. Those failures are one clustered excursion of a slowly-varying
    % error, not 432,000 coin flips. This class therefore reports an EFFECTIVE epoch count from
    % the lag-1 autocorrelation of the geometry error and a Wilson interval computed on THAT, so
    % a fix rate can be read with its real uncertainty instead of six false significant figures.
    %
    %   out = revgnss.GroundCarrierAmbiguityProbe.run(cfg, results, rel)
    %       out.bands(b).name, .wavelength_m, .fixRate, .nTrials
    %                    .medianAbsFloatErr_cyc   how far the float sat from the true integer
    %                    .p95AbsFloatErr_cyc      the tail that actually decides fixing
    %                    .fixRateLo, .fixRateHi   Wilson 95 % interval on the EFFECTIVE count
    %       out.nEffectiveEpochs   independent epochs after de-correlating the geometry error
    %       out.geomErrTau_s       integrated autocorrelation time of that error

    properties (Constant, Access = private)
        F1 = 1575.42e6;
        F2 = 1227.60e6;
        MIN_TOWERS = 2;
    end

    methods (Static)

        function out = run(cfg, results, rel)
            P = revgnss.GroundCarrierAmbiguityProbe;
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            out = struct('applicable', false, 'reason', 'notAttempted', 'bands', struct([]), ...
                'nEpochsUsed', 0, 'geomErrRms_m', NaN, 'nEffectiveEpochs', NaN, ...
                'geomErrTau_s', NaN, 'phaseSigma_m', NaN, 'leverArmMode', 'none');

            if ~P.getBool_(cfg, {'multiAsset','groundCarrierProbe','enable'}, false)
                out.reason = 'gateOff'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                out.reason = 'noSolvedPos'; return
            end
            N = size(rel.solvedPos,2); nEp = size(rel.solvedPos,3);
            tVec = rel.time_s(:).';
            if numel(tVec) ~= nEp; out.reason = 'timeGridMismatch'; return; end

            obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
            if ~obs.ok; out.reason = obs.reason; return; end
            towerPos = obs.towerPos; nTw = obs.nTw;
            rhoT = obs.rhoTruth; visTw = obs.visTw;
            % The carrier rides the SAME air column as the code -- reuse the realisation rather
            % than omitting it. Omitting it was a real defect in the first version of this probe:
            % it built the carrier from noise-free geometry alone, so the fix rate came out
            % identical for every differential-atmosphere level, which is impossible.
            atm = obs.atmDiff;
            if isempty(atm); atm = zeros(N, nTw, size(rhoT,3)); end

            sigPhase = P.getNum_(cfg, {'multiAsset','groundCarrierProbe','phaseSigma_m'}, 0.002);
            seed0    = P.getNum_(cfg, {'simulation','seed'}, 42);

            lam1 = c/P.F1; lam2 = c/P.F2;
            lamWL = c/(P.F1-P.F2); lamNL = c/(P.F1+P.F2);
            % Wide-lane noise amplification: sigma_WL = sigma_phase * sqrt(f1^2+f2^2)/(f1-f2)
            ampWL = sqrt(P.F1^2 + P.F2^2)/(P.F1 - P.F2);
            ampNL = sqrt(P.F1^2 + P.F2^2)/(P.F1 + P.F2);
            BANDS = { 'wide-lane', lamWL, ampWL; ...
                      'L2',        lam2,  1.0;   ...
                      'L1',        lam1,  1.0;   ...
                      'narrow-lane', lamNL, ampNL };

            % Integer truth: one per (satellite, tower), constant over the arc.
            rsN = RandStream('mt19937ar','Seed', seed0 + 94000);
            rsP = RandStream('mt19937ar','Seed', seed0 + 95000);
            Nint = round(randi(rsN, [-500 500], N, nTw, numel(BANDS)));

            nb = size(BANDS,1);
            fixOk = zeros(1,nb); nTrial = zeros(1,nb);
            floatErr = cell(1,nb); for b=1:nb; floatErr{b} = []; end
            geomAcc = []; nUsed = 0;
            % Per-epoch mean of the signed DD geometry error. This is the series whose
            % autocorrelation sets how many INDEPENDENT trials the arc really contains.
            geomEpoch = nan(1, nEp); tEpoch = nan(1, nEp);

            for k = 1:nEp
                okTw = find(visTw(:,k)).';
                if numel(okTw) < P.MIN_TOWERS; continue; end
                Pk = rel.solvedPos(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                % B1: predict at the antenna phase centre, the point the observable is
                % referenced to. Skipping this leaves a baseline-linear systematic in the DD
                % prediction error, i.e. in exactly the quantity whose half-wavelength margin
                % this probe exists to measure.
                Ak = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obs, Pk, k);
                rhoP = zeros(N,nTw);
                for m = okTw
                    for i = 1:N
                        rhoP(i,m) = norm(Ak(:,i) - towerPos(:,m));
                    end
                end
                ref = okTw(1);
                epAcc = 0; epN = 0;
                for m = okTw
                    if m == ref; continue; end
                    for i = 2:N
                        ddTrue = (rhoT(i,m,k)-rhoT(1,m,k)) - (rhoT(i,ref,k)-rhoT(1,ref,k)) ...
                               + (atm(i,m,k)-atm(1,m,k)) - (atm(i,ref,k)-atm(1,ref,k));
                        ddPred = (rhoP(i,m)-rhoP(1,m)) - (rhoP(i,ref)-rhoP(1,ref));
                        geomAcc(end+1) = ddTrue - ddPred;                     %#ok<AGROW>
                        epAcc = epAcc + (ddTrue - ddPred); epN = epN + 1;
                        for b = 1:nb
                            lam = BANDS{b,2}; amp = BANDS{b,3};
                            nDD = Nint(i,m,b) - Nint(1,m,b) - Nint(i,ref,b) + Nint(1,ref,b);
                            % B4 -- the DOUBLE difference combines FOUR raw carrier phases, so
                            % its noise is 2*sigPhase before the band amplification, not
                            % sigPhase. The factor was missing, which understated the DD phase
                            % noise by exactly 2x. It does not change the conclusion -- the
                            % wide-lane margin goes 6.30 sigma -> 6.05 sigma and still clears --
                            % but it is the number the atmosphere table was fitted against:
                            % k = 2 reproduces all three of its rows to 0.7 %, while k = 1 and
                            % k = sqrt(2) are 40-75 % off.
                            phi = ddTrue + lam*nDD + amp*2*sigPhase*randn(rsP);
                            fl  = (phi - ddPred)/lam;
                            fixOk(b)  = fixOk(b) + (round(fl) == nDD);
                            nTrial(b) = nTrial(b) + 1;
                            floatErr{b}(end+1) = abs(fl - nDD);               %#ok<AGROW>
                        end
                    end
                end
                nUsed = nUsed + 1;
                if epN > 0; geomEpoch(nUsed) = epAcc/epN; tEpoch(nUsed) = tVec(k); end
            end

            if nUsed < 1; out.reason = 'noUsableEpochs'; return; end
            [nEff, tauInt] = P.effectiveEpochs_(geomEpoch(1:nUsed), tEpoch(1:nUsed));
            bands = struct('name',{},'wavelength_m',{},'fixRate',{},'nTrials',{}, ...
                'medianAbsFloatErr_cyc',{},'p95AbsFloatErr_cyc',{}, ...
                'fixRateLo',{},'fixRateHi',{});
            for b = 1:nb
                bands(b).name = BANDS{b,1};
                bands(b).wavelength_m = BANDS{b,2};
                bands(b).fixRate = fixOk(b)/max(nTrial(b),1);
                bands(b).nTrials = nTrial(b);
                bands(b).medianAbsFloatErr_cyc = median(floatErr{b});
                bands(b).p95AbsFloatErr_cyc = prctile(floatErr{b}, 95);
                % Interval on the EFFECTIVE count, not the counted one. Reporting the counted
                % interval would claim a precision the arc-correlated geometry error cannot back.
                [bands(b).fixRateLo, bands(b).fixRateHi] = ...
                    P.wilson_(bands(b).fixRate, nEff);
            end
            out.applicable       = true;
            out.reason           = 'ok';
            out.bands            = bands;
            out.nEpochsUsed      = nUsed;
            out.geomErrRms_m     = sqrt(mean(geomAcc.^2));
            out.phaseSigma_m     = sigPhase;
            out.nEffectiveEpochs = nEff;
            out.geomErrTau_s     = tauInt;
            out.leverArmMode     = obs.leverArmMode;
        end
    end

    methods (Static, Access = private)

        function [nEff, tauInt] = effectiveEpochs_(x, t)
            % effectiveEpochs_  How many INDEPENDENT samples the arc really carries.
            %
            % n_eff = n * (1-rho)/(1+rho) with rho the lag-1 autocorrelation -- the standard
            % AR(1) correction. Deliberately applied to the per-EPOCH mean rather than to every
            % counted double difference, because the DDs within an epoch share a reference
            % satellite and a reference tower and are therefore not independent either. This is
            % the conservative reading, which is the right one when the whole point is to stop
            % over-claiming.
            nEff = numel(x); tauInt = 0;
            x = x(isfinite(x));
            n = numel(x);
            if n < 8; nEff = max(1,n); return; end
            x = x - mean(x);
            d0 = sum(x.^2);
            if d0 <= 0; return; end
            rho = sum(x(1:end-1).*x(2:end)) / d0;
            rho = max(-0.999, min(0.999, rho));
            nEff = max(1, n * (1-rho)/(1+rho));
            dt = 1.0;
            if numel(t) >= 2; dt = median(diff(t(isfinite(t)))); end
            if ~isfinite(dt) || dt <= 0; dt = 1.0; end
            if rho > 0; tauInt = -dt/log(rho); end
        end

        function [lo, hi] = wilson_(p, n)
            % wilson_  95 % Wilson score interval. Chosen over the normal approximation because
            % the rates of interest sit against p = 1, where the normal interval runs past it.
            z = 1.959963984540054;
            n = max(1, n);
            den = 1 + z^2/n;
            c   = (p + z^2/(2*n)) / den;
            h   = (z/den) * sqrt(p*(1-p)/n + z^2/(4*n^2));
            lo  = max(0, c - h); hi = min(1, c + h);
        end

        function v = getBool_(cfg, path, dflt)
            v = logical(revgnss.GroundCarrierAmbiguityProbe.getNum_(cfg, path, dflt));
        end

        function v = getNum_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (isnumeric(c) || islogical(c)); v = c; end
        end
    end
end
