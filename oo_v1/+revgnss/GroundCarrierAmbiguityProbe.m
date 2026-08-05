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
    %   out = revgnss.GroundCarrierAmbiguityProbe.run(cfg, results, rel)
    %       out.bands(b).name, .wavelength_m, .fixRate, .nTrials
    %                    .medianAbsFloatErr_cyc   how far the float sat from the true integer
    %                    .p95AbsFloatErr_cyc      the tail that actually decides fixing

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
                'nEpochsUsed', 0, 'geomErrRms_m', NaN);

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

            for k = 1:nEp
                okTw = find(visTw(:,k)).';
                if numel(okTw) < P.MIN_TOWERS; continue; end
                Pk = rel.solvedPos(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                rhoP = zeros(N,nTw);
                for m = okTw
                    for i = 1:N
                        rhoP(i,m) = norm(Pk(:,i) - towerPos(:,m));
                    end
                end
                ref = okTw(1);
                for m = okTw
                    if m == ref; continue; end
                    for i = 2:N
                        ddTrue = (rhoT(i,m,k)-rhoT(1,m,k)) - (rhoT(i,ref,k)-rhoT(1,ref,k));
                        ddPred = (rhoP(i,m)-rhoP(1,m)) - (rhoP(i,ref)-rhoP(1,ref));
                        geomAcc(end+1) = ddTrue - ddPred;                     %#ok<AGROW>
                        for b = 1:nb
                            lam = BANDS{b,2}; amp = BANDS{b,3};
                            nDD = Nint(i,m,b) - Nint(1,m,b) - Nint(i,ref,b) + Nint(1,ref,b);
                            phi = ddTrue + lam*nDD + amp*sigPhase*randn(rsP);
                            fl  = (phi - ddPred)/lam;
                            fixOk(b)  = fixOk(b) + (round(fl) == nDD);
                            nTrial(b) = nTrial(b) + 1;
                            floatErr{b}(end+1) = abs(fl - nDD);               %#ok<AGROW>
                        end
                    end
                end
                nUsed = nUsed + 1;
            end

            if nUsed < 1; out.reason = 'noUsableEpochs'; return; end
            bands = struct('name',{},'wavelength_m',{},'fixRate',{},'nTrials',{}, ...
                'medianAbsFloatErr_cyc',{},'p95AbsFloatErr_cyc',{});
            for b = 1:nb
                bands(b).name = BANDS{b,1};
                bands(b).wavelength_m = BANDS{b,2};
                bands(b).fixRate = fixOk(b)/max(nTrial(b),1);
                bands(b).nTrials = nTrial(b);
                bands(b).medianAbsFloatErr_cyc = median(floatErr{b});
                bands(b).p95AbsFloatErr_cyc = prctile(floatErr{b}, 95);
            end
            out.applicable   = true;
            out.reason       = 'ok';
            out.bands        = bands;
            out.nEpochsUsed  = nUsed;
            out.geomErrRms_m = sqrt(mean(geomAcc.^2));
            out.phaseSigma_m = sigPhase;
        end
    end

    methods (Static, Access = private)
        function v = getNum_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && isnumeric(c); v = c; end
        end
    end
end
