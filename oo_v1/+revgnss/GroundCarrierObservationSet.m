classdef GroundCarrierObservationSet
    % GroundCarrierObservationSet  Dual-frequency tower->satellite carrier and code, per link.
    %
    % EXECUTION-PLAN F1, F3 AND F7. revgnss.GroundCarrierAmbiguityProbe measured whether the
    % integers COULD be fixed; it could not fix them, because it had no observations to fix them
    % from -- it synthesised one number per band per epoch and compared it against an integer it
    % had drawn itself. An estimator needs the actual per-link quantities, and it needs them to
    % be mutually consistent.
    %
    % IT CONSUMES, IT DOES NOT DUPLICATE. The geometry comes from
    % revgnss.GroundDifferencedRotationSolver.buildObservable -- the same truth antenna phase
    % centres, the same visibility mask, the same tower positions and the same atmospheric
    % realisation the code observable rides. There is one physics path; this class adds bands to
    % it.
    %
    % F3 -- THE BANDS ARE NOT INDEPENDENT, AND DRAWING THEM SO MAKES A CASCADE UNDEMONSTRABLE
    % IN PRINCIPLE. The probe drew four ambiguities per link, one per band. Physically there are
    % exactly TWO integers, N1 and N2; wide-lane and narrow-lane are DEFINED from them:
    %       N_WL = N1 - N2      N_NL = N1 + N2
    % A wide-lane fix is worth having precisely because it CONSTRAINS N1 - N2, so the L1 search
    % afterwards is one-dimensional per link instead of two. Four independent draws destroy that
    % relationship, and with it the entire reason for a cascade. Here N1 and N2 are the state and
    % everything else is derived.
    %
    % F7 -- A FIX MUST BE HELD. Cycle slips restart an ambiguity arc: after a slip the integer is
    % a NEW unknown and any fix carried across it is simply wrong. Modelling them is what turns
    % "99.9963 % of epochs would round correctly" into a number about a receiver rather than
    % about a static geometry. Slips are drawn per link at a configurable rate and the arc index
    % is published, so the resolver can parameterise one ambiguity PER ARC rather than per link.
    %
    % THE OBSERVATION MODEL, stated because sign errors here are invisible:
    %   code    P_j = rho + T + I/f_j^2 * f1^2 + eps         (ionosphere DELAYS the code)
    %   carrier L_j = rho + T - I/f_j^2 * f1^2 + lam_j*N_j + eps   (and ADVANCES the phase)
    % with I the L1-equivalent ionospheric delay in metres. That opposite sign is the whole basis
    % of the Melbourne-Wubbena combination the resolver uses, so it is modelled explicitly rather
    % than folded into a single "atmosphere" term.
    %
    %   obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
    %   car = revgnss.GroundCarrierObservationSet.build(cfg, obs, tVec);
    %       car.phase_m   [nBand x N x nTw x nEp]  carrier phase, metres
    %       car.code_m    [nBand x N x nTw x nEp]  code pseudorange, metres
    %       car.arcId     [N x nTw x nEp]          ambiguity arc index (increments on a slip)
    %       car.Ntrue     [2 x N x nTw x nArcMax]  the integers, for SCORING ONLY -- an
    %                                              estimator must never read this

    properties (Constant)
        F1_HZ = 1575.42e6;
        F2_HZ = 1227.60e6;
    end

    methods (Static)

        function car = build(cfg, obs, tVec)
            C = revgnss.GroundCarrierObservationSet;
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            car = struct('ok', false, 'reason', 'notAttempted');
            if ~isstruct(obs) || ~isfield(obs,'ok') || ~obs.ok
                car.reason = 'noCodeObservable'; return
            end
            [N, nTw, nEp] = size(obs.rhoTruth);
            if nEp ~= numel(tVec); car.reason = 'timeGridMismatch'; return; end

            f1 = C.F1_HZ; f2 = C.F2_HZ;
            lam1 = c/f1; lam2 = c/f2;
            car.f1_Hz = f1; car.f2_Hz = f2;
            car.lambda1_m = lam1; car.lambda2_m = lam2;
            car.lambdaWL_m = c/(f1-f2);
            car.lambdaNL_m = c/(f1+f2);

            sigPhase = C.getNum_(cfg, {'multiAsset','groundCarrierProbe','phaseSigma_m'}, 0.002);
            sigCode1 = C.getNum_(cfg, {'signals','L1','codeSigma0_m'}, 0.30);
            sigCode2 = C.getNum_(cfg, {'signals','L2','codeSigma0_m'}, 0.45);
            % L1-equivalent DIFFERENTIAL ionospheric delay between two satellites viewing the
            % same tower. Zero by default, matching the physically correct common-mode case for
            % a 2 km formation (11 arcsec of ray divergence, 18 m at a 350 km pierce point).
            sigIono  = C.getNum_(cfg, {'multiAsset','groundCarrier','differentialIonoSigma_m'}, 0.0);
            tauIono  = C.getNum_(cfg, {'multiAsset','groundCarrier','differentialIonoTau_s'}, 600);
            slipRate = C.getNum_(cfg, {'multiAsset','groundCarrier','slipRatePerLinkPerHour'}, 0.0);
            seed0    = C.getNum_(cfg, {'simulation','seed'}, 42);

            dt = 1.0;
            if nEp >= 2; dt = median(diff(tVec)); end
            if ~isfinite(dt) || dt <= 0; dt = 1.0; end

            rsN  = RandStream('mt19937ar','Seed', seed0 + 96000);
            rsP  = RandStream('mt19937ar','Seed', seed0 + 97000);
            rsC  = RandStream('mt19937ar','Seed', seed0 + 98000);
            rsI  = RandStream('mt19937ar','Seed', seed0 + 99000);
            rsS  = RandStream('mt19937ar','Seed', seed0 + 100000);

            % --- ambiguity arcs and their integers -------------------------------------------
            % One arc per link until a slip; each arc owns a FRESH pair (N1, N2). Everything
            % else -- wide-lane, narrow-lane, iono-free -- is derived from that pair (F3).
            pSlip = 1 - exp(-max(0,slipRate)*dt/3600);
            arcId = ones(N, nTw, nEp);
            nArc  = ones(N, nTw);
            for k = 2:nEp
                arcId(:,:,k) = arcId(:,:,k-1);
                if pSlip <= 0; continue; end
                hit = rand(rsS, N, nTw) < pSlip;
                if any(hit(:))
                    arcId(:,:,k) = arcId(:,:,k) + hit;
                    nArc = max(nArc, arcId(:,:,k));
                end
            end
            nArcMax = max(nArc(:));
            Ntrue = zeros(2, N, nTw, nArcMax);
            Ntrue(1,:,:,:) = randi(rsN, [-500 500], 1, N, nTw, nArcMax);
            Ntrue(2,:,:,:) = randi(rsN, [-500 500], 1, N, nTw, nArcMax);

            % --- differential ionosphere, Gauss-Markov, L1-equivalent metres -------------------
            aI = exp(-dt/max(dt,tauIono));
            qI = sigIono*sqrt(max(0,1-aI^2));
            I  = sigIono*randn(rsI, N, nTw);

            phase = nan(2, N, nTw, nEp);
            code  = nan(2, N, nTw, nEp);
            ionoL1 = zeros(N, nTw, nEp);

            r2 = (f1/f2)^2;                     % L2 ionospheric scaling
            for k = 1:nEp
                if k > 1 && sigIono > 0
                    I = aI*I + qI*randn(rsI, N, nTw);
                end
                for m = 1:nTw
                    if ~obs.visTw(m,k); continue; end
                    for i = 1:N
                        rho = obs.rhoTruth(i,m,k);
                        trop = obs.atmDiff(i,m,k);       % the SAME air column as the code
                        Ik   = I(i,m);
                        a    = arcId(i,m,k);
                        n1   = Ntrue(1,i,m,a); n2 = Ntrue(2,i,m,a);
                        ionoL1(i,m,k) = Ik;
                        % Carrier ADVANCES, code DELAYS. Modelled explicitly: the Melbourne-
                        % Wubbena combination the resolver relies on exists precisely because
                        % of this sign difference.
                        phase(1,i,m,k) = rho + trop - Ik      + lam1*n1 + sigPhase*randn(rsP);
                        phase(2,i,m,k) = rho + trop - Ik*r2   + lam2*n2 + sigPhase*randn(rsP);
                        code(1,i,m,k)  = rho + trop + Ik      + sigCode1*randn(rsC);
                        code(2,i,m,k)  = rho + trop + Ik*r2   + sigCode2*randn(rsC);
                    end
                end
            end

            car.ok = true; car.reason = 'ok';
            car.phase_m = phase; car.code_m = code;
            car.arcId = arcId; car.nArcMax = nArcMax;
            car.Ntrue = Ntrue;                     % SCORING ONLY -- never read by an estimator
            car.ionoL1_m = ionoL1;
            car.phaseSigma_m = sigPhase;
            car.codeSigma_m = [sigCode1 sigCode2];
            car.differentialIonoSigma_m = sigIono;
            car.slipRatePerLinkPerHour = slipRate;
            car.nSlips = sum(nArc(:) - 1);
            car.visTw = obs.visTw; car.towerPos = obs.towerPos;
            car.time_s = tVec(:).';
        end

        function [wl, nl] = deriveLaneIntegers(N1, N2)
            % deriveLaneIntegers  F3, in one place so no caller re-invents it wrongly.
            wl = N1 - N2;
            nl = N1 + N2;
        end
    end

    methods (Static, Access = private)
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
