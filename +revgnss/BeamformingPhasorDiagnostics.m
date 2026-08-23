classdef BeamformingPhasorDiagnostics
    % BeamformingPhasorDiagnostics  Coherent-beamforming phase budget of the formation.
    %
    % Treats the estimated formation as a sparse transmit array and asks what the
    % RELATIVE position and clock error cost in coherent gain. The answer is the
    % classical phasor sum: each spacecraft contributes a unit phasor whose angle is
    % its residual path-phase error, and the resultant length is the array factor.
    %
    % THE MAP
    %   e_i   = (|p - rHat_i| - |p - r_i|) + (bHat_i - b_i)      path error [m]
    %   e_i  <- e_i - mean(e)                                    piston is free
    %   psi_i = -2*pi*e_i/lambda                                 phase error [rad]
    %   AF    = (1/N) sum_i exp(j*psi_i)     lossDb = 20*log10|AF|
    %
    % Ruze's exp(-sigma_psi^2) is the SMALL-ERROR ENVELOPE of that exact sum, useful
    % to roughly sigma_psi < 1 rad and meaningless beyond it, so the exact sum is what
    % is reported and Ruze is carried alongside only for comparison.
    %
    % FOCUSED, NOT PLANE-WAVE. A formation of extent D observing a target at range R
    % has Fresnel distance 2*D^2/lambda. For a km-class GEO formation at S-band that
    % exceeds the slant range, i.e. the user sits in the RADIATING NEAR FIELD and a
    % plane-wave array factor is simply the wrong model. Exact element-to-target
    % ranges are used throughout, so the payload is correct in either regime and
    % reports which one it is in.
    %
    % COMMON-MODE IS NOT ALWAYS FREE. "Beamforming needs only relative geometry" is a
    % FAR-FIELD statement. At finite range the elements see the target along
    % directions differing by ~D/R, so a common translation d leaks differential path
    % error of order |d|*D/R. The payload separates the shape-only term from the total
    % so that leak is visible rather than silently attributed to formation shape.
    %
    % HONESTY GATE. A phasor diagram drawn on a formation solution that no measurement
    % constrained looks exactly like one drawn on a good solution -- better, usually,
    % because an unconstrained follower set that shares an initial condition stays
    % perfectly self-consistent. coherenceClaimStatus therefore refuses the claim
    % unless physical range rows were consumed AND there are at least as many scalar
    % constraints as relative degrees of freedom. Consumers must print the status.

    properties (Constant)
        C_mps = 299792458
        % Sub-satellite point is placed on a sphere of this radius along the centroid
        % radius vector. Only DIFFERENCES of element-to-target ranges matter here and
        % the target is tens of thousands of km away, so metre-level target placement
        % error is irrelevant to every quantity in this payload.
        EarthRadius_m = 6378137
    end

    methods (Static)

        function payload = empty()
            % empty  The canonical field set, populated for "nothing to report".
            payload = struct( ...
                'available',                    false, ...
                'reason',                       'notComputed', ...
                'nAssets',                      0, ...
                'assetNames',                   {{}}, ...
                'time_s',                       NaN, ...
                'targetMode',                   'unavailable', ...
                'targetEcef_m',                 [], ...
                'truthEcef_m',                  [], ...
                'slantRange_m',                 NaN, ...
                'apertureExtent_m',             NaN, ...
                'losSpread_rad',                NaN, ...
                'pathError_m',                  [], ...
                'pathErrorRms_m',               NaN, ...
                'shapeOnlyPathError_m',         [], ...
                'shapeOnlyPathErrorRms_m',      NaN, ...
                'commonOffset_m',               NaN, ...
                'commonOffsetLeakRms_m',        NaN, ...
                'geometryPathErrorRms_m',       NaN, ...
                'clockPathErrorRms_m',          NaN, ...
                'clockTermAvailable',           false, ...
                'frequencies_Hz',               [], ...
                'wavelengths_m',                [], ...
                'arrayFactorMagnitude',         [], ...
                'coherentGainLoss_dB',          [], ...
                'ruzeGainLoss_dB',              [], ...
                'sigmaOverLambda',              [], ...
                'fresnelDistance_m',            [], ...
                'nearField',                    false(1,0), ...
                'groundFootprint_m',            [], ...
                'coherenceFrequency_Hz',        NaN, ...
                'coherenceCriterionLambdaFraction', NaN, ...
                'incoherentFloor_dB',           NaN, ...
                'sweepFrequencies_Hz',          [], ...
                'sweepGainLoss_dB',             [], ...
                'physicalRangeRowsConsumed',    0, ...
                'physicalRangeLinkCount',       0, ...
                'relativePositionDof',          0, ...
                'rangeOnlyObservabilityStatus', 'unavailable', ...
                'formalToRealisedSigmaRatio',   NaN, ...
                'coherenceClaimStatus',         'unavailable', ...
                'coherenceClaimExplanation',    '', ...
                'definitionPathError',          revgnss.BeamformingPhasorDiagnostics.definitionPathError());
        end

        function text = definitionPathError()
            text = ['pathError_m(i) = (norm(p - rHat_i) - norm(p - r_i)) + ' ...
                '(bHat_i - b_i), mean-removed  [per-element residual path length ' ...
                'toward the target p; the mean is an overall beam phase and is free]'];
        end

        function series = emptySeries()
            % emptySeries  Canonical field set for the per-epoch phasor time series.
            series = struct( ...
                'available',              false, ...
                'reason',                 'notComputed', ...
                'nAssets',                0, ...
                'time_s',                 [], ...
                'frequencies_Hz',         [], ...
                'pathErrorRms_m',         [], ...
                'geometryPathErrorRms_m', [], ...
                'clockPathErrorRms_m',    [], ...
                'rawPathErrorRms_m',      [], ...
                'coherentGainLoss_dB',    [], ...
                'rawCoherentGainLoss_dB', [], ...
                'finalPathError_m',       [], ...
                'clockTermAvailable',     false, ...
                'geometrySource',         'unavailable', ...
                'targetMode',             'unavailable', ...
                'slantRange_m',           NaN, ...
                'apertureExtent_m',       NaN, ...
                'nearField',              false(1,0), ...
                'lambdaOver20_m',         [], ...
                'tailPathErrorRms_m',     NaN, ...
                'coherenceFrequency_Hz',  NaN, ...
                'rawCoherenceFrequency_Hz', NaN, ...
                'tailCoherentGainLoss_dB',[], ...
                'spotDisplacement_m',     [], ...
                'spotDisplacementEast_m', [], ...
                'spotDisplacementNorth_m',[], ...
                'residualPathErrorRms_m', [], ...
                'residualGainLoss_dB',    [], ...
                'beamFootprint_m',        [], ...
                'tailSpotDisplacement_m', NaN, ...
                'tailResidualPathErrorRms_m', NaN, ...
                'tailResidualGainLoss_dB',[], ...
                'tiltFraction',           NaN);
        end

        function series = computeSeries(rel, results, cfg)
            % computeSeries  Per-epoch beamforming path-error budget from the RELATIVE-LAYER
            % solution, i.e. the geometry the crosslink network actually produced.
            %
            % WHY THIS EXISTS SEPARATELY FROM compute(). compute() is fed
            % jointFormationDiagnostics: the raw per-asset EKF estimate, final epoch only. That
            % number is blind to everything the ISL network does -- the four-timestamp ranging, the
            % delay calibration, the link topology -- because none of it ever reaches the EKF state
            % it reads. Driving the same phasor maths from rel.solvedPos closes that gap, and
            % reporting BOTH shows what the crosslink layer bought.
            %
            % The quantity is unchanged and deliberately so: e_i = (|p - rHat_i| - |p - r_i|) +
            % (bHat_i - b_i), mean removed. Position error and clock error are the same currency
            % (metres of path toward the target) and only their SPREAD across the array costs gain.
            %
            % Exact element-to-target ranges are used, not a plane-wave projection: a km-class
            % formation at S-band puts the ground user inside the radiating near field, where the
            % plane-wave array factor is the wrong model. nearField records which regime each
            % frequency is in.
            CE = revgnss.BeamformingPhasorDiagnostics;
            series = CE.emptySeries();
            if nargin < 3; cfg = struct(); end
            if ~CE.getBool_(cfg,{'beamforming','enable'},true)
                series.reason = 'disabledByConfig'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                series.reason = 'noRelativeSolution'; return
            end
            P = rel.solvedPos;                                   % [3 x N x nEp], estimated frame
            if ndims(P) ~= 3 || size(P,1) ~= 3
                series.reason = 'malformedSolvedPos'; return
            end
            [~, N, nEp] = size(P);
            if N < 2 || nEp < 1
                series.reason = 'fewerThanTwoAssets'; return
            end
            [T, Raw, ok] = CE.truthAndRaw_(results, N, nEp);
            if ~ok
                series.reason = 'truthTrajectoryUnavailable'; return
            end

            clockErr = [];
            if isfield(rel,'solvedClockError_m') && ~isempty(rel.solvedClockError_m) && ...
                    isequal(size(rel.solvedClockError_m), [N nEp])
                clockErr = rel.solvedClockError_m;
            end
            series.clockTermAvailable = ~isempty(clockErr);

            tVec = 1:nEp;
            if isfield(rel,'time_s') && numel(rel.time_s) == nEp; tVec = rel.time_s(:).'; end

            freq = CE.getVec_(cfg,{'beamforming','frequencies_Hz'});
            freq = freq(isfinite(freq) & freq > 0);
            if isempty(freq); freq = [2.1e9 1.2e9 4.0e8]; end     % S / L / UHF reference set
            freq = sort(freq(:).','descend');
            nF = numel(freq);
            lambda = CE.C_mps ./ freq;

            pathRms  = nan(1,nEp);  geomRms = nan(1,nEp);
            clkRms   = nan(1,nEp);  rawRms  = nan(1,nEp);
            lossDb   = nan(nF,nEp); rawLoss = nan(nF,nEp);
            spotE    = nan(1,nEp);  spotN   = nan(1,nEp);
            resRms   = nan(1,nEp);  resLoss = nan(nF,nEp);
            finalErr = [];
            extent = 0; slant = NaN; targetMode = 'centroidNadir';
            for kk = 1:nEp
                rT = T(:,:,kk);
                if any(~isfinite(rT(:))); continue; end
                [target_m, targetMode] = CE.targetPoint_(cfg, mean(rT,2));
                slant = norm(target_m - mean(rT,2));
                if ~(slant > 0); continue; end
                rangeTo = @(R) vecnorm(R - target_m, 2, 1);
                truthRange = rangeTo(rT);

                geom = rangeTo(P(:,:,kk)) - truthRange;
                geom = geom - mean(geom);
                if isempty(clockErr)
                    e = geom;  clk = zeros(1,N);
                else
                    clk = clockErr(:,kk).';
                    clk = clk - mean(clk);
                    e = geom + clk;
                    e = e - mean(e);
                end
                pathRms(kk) = CE.rms_(e);
                geomRms(kk) = CE.rms_(geom);
                clkRms(kk)  = CE.rms_(clk);

                % Same quantity from the RAW per-asset EKF, so the crosslink gain is visible.
                if ~isempty(Raw) && all(isfinite(reshape(Raw(:,:,kk),[],1)))
                    gr = rangeTo(Raw(:,:,kk)) - truthRange;
                    gr = gr - mean(gr);
                    if ~isempty(clockErr); gr = gr + clk; gr = gr - mean(gr); end
                    rawRms(kk) = CE.rms_(gr);
                end

                % ---- does the beam MOVE, or does it DIM? -----------------------------
                % A path error that varies LINEARLY across the array is a wavefront tilt: the
                % beam stays sharp and lands somewhere else. Only what is left after removing
                % the best-fit tilt actually destroys gain. Separating them matters because a
                % displaced spot is a pointing problem (calibratable against a ground beacon)
                % while lost gain is unrecoverable.
                %
                % Received phase at a ground point p+d is psi_i + k*(u_i . d) with
                % u_i = (p - r_i)/|p - r_i|, so the apparent spot offset is the least-squares
                % d that best explains e. d is constrained to the ground TANGENT plane: the
                % along-boresight component is defocus, near-degenerate here (all u_i nearly
                % parallel), and fitting it would let an ill-conditioned direction absorb
                % error that really does cost gain.
                [dEast, dNorth, resid] = CE.fitSpotOffset_(rT, target_m, e);
                spotE(kk) = dEast; spotN(kk) = dNorth;
                resRms(kk) = CE.rms_(resid);

                for f = 1:nF
                    psi = -2*pi*e/lambda(f);  psi = psi - mean(psi);
                    lossDb(f,kk) = 20*log10(max(abs(mean(exp(1i*psi))),realmin));
                    rp = -2*pi*resid/lambda(f); rp = rp - mean(rp);
                    resLoss(f,kk) = 20*log10(max(abs(mean(exp(1i*rp))),realmin));
                    if isfinite(rawRms(kk))
                        pr = -2*pi*gr/lambda(f); pr = pr - mean(pr);
                        rawLoss(f,kk) = 20*log10(max(abs(mean(exp(1i*pr))),realmin));
                    end
                end
                if kk == nEp
                    finalErr = e;
                    extent = CE.maxBaseline_(rT);
                end
            end

            tsel = max(1,floor(nEp/2)):nEp;                       % same tail convention as the solver
            series.available   = true;
            series.reason      = 'ok';
            series.nAssets     = N;
            series.time_s      = tVec;
            series.frequencies_Hz = freq;
            series.pathErrorRms_m = pathRms;
            series.geometryPathErrorRms_m = geomRms;
            series.clockPathErrorRms_m = clkRms;
            series.rawPathErrorRms_m = rawRms;
            series.coherentGainLoss_dB = lossDb;
            series.rawCoherentGainLoss_dB = rawLoss;
            series.finalPathError_m = finalErr;
            series.targetMode = targetMode;
            series.slantRange_m = slant;
            series.apertureExtent_m = extent;
            series.nearField = (2*extent^2 ./ lambda) > slant;
            series.lambdaOver20_m = lambda/20;
            series.tailPathErrorRms_m = sqrt(mean(pathRms(tsel).^2,'omitnan'));
            series.tailCoherentGainLoss_dB = mean(lossDb(:,tsel),2,'omitnan').';
            % The headline: the highest carrier this geometry could actually beamform at, i.e.
            % where lambda/20 still covers the achieved path error (~0.4 dB of loss). Frequency
            % is the honest currency here because the dB figure saturates at the 1/N floor and
            % stops distinguishing configurations long before the geometry stops improving.
            series.coherenceFrequency_Hz = CE.coherenceFreq_(series.tailPathErrorRms_m);
            if any(isfinite(rawRms))
                series.rawCoherenceFrequency_Hz = ...
                    CE.coherenceFreq_(sqrt(mean(rawRms(tsel).^2,'omitnan')));
            end
            series.spotDisplacementEast_m  = spotE;
            series.spotDisplacementNorth_m = spotN;
            series.spotDisplacement_m      = hypot(spotE, spotN);
            series.residualPathErrorRms_m  = resRms;
            series.residualGainLoss_dB     = resLoss;
            series.beamFootprint_m         = lambda*slant/max(extent,realmin);
            series.tailSpotDisplacement_m  = ...
                sqrt(mean(series.spotDisplacement_m(tsel).^2,'omitnan'));
            series.tailResidualPathErrorRms_m = sqrt(mean(resRms(tsel).^2,'omitnan'));
            series.tailResidualGainLoss_dB = mean(resLoss(:,tsel),2,'omitnan').';
            % How much of the budget is merely a mispointing? 1 = pure tilt (beam intact, aimed
            % wrong), 0 = pure randomness (beam destroyed where it stands).
            if series.tailPathErrorRms_m > 0
                series.tiltFraction = 1 - ...
                    (series.tailResidualPathErrorRms_m/series.tailPathErrorRms_m)^2;
            end
            if isfield(rel,'shapeObservationSource')
                series.geometrySource = rel.shapeObservationSource;
            else
                series.geometrySource = 'relativeSolver';
            end
        end

        function [T, Raw, ok] = truthAndRaw_(results, N, nEp)
            % truthAndRaw_  Truth trajectories and the raw per-asset EKF positions, [3 x N x nEp].
            T = nan(3,N,nEp); Raw = nan(3,N,nEp); ok = false;
            if ~isstruct(results) || ~isfield(results,'asset'); return; end
            if numel(results.asset) < N; return; end
            for i = 1:N
                a = results.asset{i};
                if ~isstruct(a) || ~isfield(a,'truthTraj') || size(a.truthTraj,2) < nEp; return; end
                T(:,i,:) = reshape(a.truthTraj(:,1:nEp), 3, 1, nEp);
                % Same accessor SwarmRelativeSolver.gatherTrajectories_ uses: the EKF history is
                % `x`, and the position rows are wherever stateMap.r_idx says -- NOT rows 1:3,
                % which is only true for some state layouts.
                if isfield(a,'history') && isfield(a.history,'x') && ~isempty(a.history.x) && ...
                        isfield(a,'stateMap') && isfield(a.stateMap,'r_idx') && ...
                        size(a.history.x,2) >= nEp
                    Raw(:,i,:) = reshape(a.history.x(a.stateMap.r_idx, 1:nEp), 3, 1, nEp);
                end
            end
            % Per-epoch finiteness is checked at the point of use. Discarding the whole array
            % because one epoch is non-finite silently deletes the raw-EKF comparison curve,
            % which is the only thing that shows what the crosslink layer bought.
            if all(~isfinite(Raw(:))); Raw = []; end
            ok = true;
        end

        function [dEast, dNorth, resid] = fitSpotOffset_(rTruth, target_m, e)
            % fitSpotOffset_  Where does the beam actually land, and what is left over?
            %
            % Solves min_d || U*d - e || over the ground tangent plane at the target, where
            % U(i,:) = [u_i.eEast, u_i.eNorth] and u_i points from satellite i to the target.
            % Returns the offset in metres along the two ground directions and the residual
            % path error that no repointing can remove.
            dEast = NaN; dNorth = NaN; resid = e;
            up = target_m/max(norm(target_m),realmin);
            ref = [0;0;1];
            if abs(up.'*ref) > 0.99; ref = [1;0;0]; end
            eEast = cross(ref, up);  n = norm(eEast);
            if ~(n > 0); return; end
            eEast = eEast/n;
            eNorth = cross(up, eEast);

            d = target_m - rTruth;                       % target as seen from each satellite
            rng_m = vecnorm(d,2,1);
            U = d ./ max(rng_m, realmin);
            A = [(eEast.'*U).', (eNorth.'*U).'];
            A = A - mean(A,1);                           % e is mean-removed, so A must be too
            ev = e(:);
            if rank(A) < 2; return; end
            sol = A\ev;
            dEast = sol(1); dNorth = sol(2);
            resid = (ev - A*sol).';
        end

        function f_Hz = coherenceFreq_(sigma_m)
            % coherenceFreq_  Carrier at which lambda/20 equals the achieved path error.
            f_Hz = NaN;
            if isfinite(sigma_m) && sigma_m > 0
                f_Hz = revgnss.BeamformingPhasorDiagnostics.C_mps/(20*sigma_m);
            end
        end

        function y = runningMedian_(x, win)
            % runningMedian_  Trend without the per-epoch measurement noise, matching the
            % smoothing the other multi-asset figures use. Statistics are always quoted from the
            % RAW series; this only shapes the drawn curve.
            y = x;
            if nargin < 2 || isempty(win); win = max(5, round(numel(x)/60)); end
            if numel(x) < 3; return; end
            y = movmedian(x, win, 'omitnan', 'Endpoints', 'shrink');
        end

        function payload = compute(diagnostics, jointEstimate, multiAssetTruth, cfg)
            % compute  Build the payload from the joint formation diagnostics.
            %
            % diagnostics supplies the final-epoch geometry and the range provenance
            % that the honesty gate needs; jointEstimate/multiAssetTruth supply the
            % clock terms, which the formation diagnostics do not carry.
            payload = revgnss.BeamformingPhasorDiagnostics.empty();
            if nargin < 4; cfg = struct(); end
            CE = revgnss.BeamformingPhasorDiagnostics;

            if ~isstruct(diagnostics) || ~isfield(diagnostics,'available') || ...
                    ~diagnostics.available
                payload.reason = 'formationDiagnosticsUnavailable';
                return
            end
            if ~CE.getBool_(cfg,{'beamforming','enable'},true)
                payload.reason = 'disabledByConfig';
                return
            end
            rT = diagnostics.finalTruthEcef_m;
            rE = diagnostics.finalEstimateEcef_m;
            if isempty(rT) || isempty(rE) || ~isequal(size(rT),size(rE)) || size(rT,1) ~= 3
                payload.reason = 'finalGeometryUnavailable';
                return
            end
            nAssets = size(rT,2);
            if nAssets < 2
                payload.reason = 'fewerThanTwoAssets';
                return
            end
            if any(~isfinite(rT(:))) || any(~isfinite(rE(:)))
                payload.reason = 'nonFiniteGeometry';
                return
            end

            % ---- clock error per element, in metres of path -------------------
            [clockError_m, clockAvailable] = CE.finalClockError_m_( ...
                jointEstimate, multiAssetTruth, nAssets);

            % ---- target point --------------------------------------------------
            centroid_m = mean(rT,2);
            [target_m, targetMode] = CE.targetPoint_(cfg, centroid_m);
            slantRange_m = norm(target_m - centroid_m);
            if ~(slantRange_m > 0)
                payload.reason = 'degenerateTargetGeometry';
                return
            end

            % ---- exact focused path error --------------------------------------
            rangeTo = @(R) vecnorm(R - target_m, 2, 1);
            geometryTerm_m = rangeTo(rE) - rangeTo(rT);
            pathError_m = geometryTerm_m + clockError_m;
            pathError_m = pathError_m - mean(pathError_m);

            % ---- shape-only term, isolating the common-translation leak --------
            % Removing the mean POSITION offset (not the mean path error) leaves the
            % genuine formation-shape error. What the two differ by is the finite-range
            % leak described in the class header.
            positionError_m = rE - rT;
            commonOffset_m = mean(positionError_m,2);
            shapeGeometry_m = rangeTo(rT + (positionError_m - commonOffset_m)) - rangeTo(rT);
            shapeOnly_m = shapeGeometry_m - mean(shapeGeometry_m);

            apertureExtent_m = CE.maxBaseline_(rT);
            losSpread_rad = apertureExtent_m / slantRange_m;

            % ---- frequency response ---------------------------------------------
            criterion = CE.getNum_(cfg, ...
                {'beamforming','coherenceCriterionLambdaFraction'},20);
            if ~(criterion > 0); criterion = 20; end
            sigma_m = CE.rms_(pathError_m);
            if sigma_m > 0
                coherenceFrequency_Hz = CE.C_mps/(criterion*sigma_m);
            else
                coherenceFrequency_Hz = Inf;
            end
            frequencies_Hz = CE.frequencyList_(cfg, coherenceFrequency_Hz);

            nF = numel(frequencies_Hz);
            wavelengths_m = CE.C_mps ./ frequencies_Hz;
            arrayFactor = zeros(1,nF);
            lossDb = zeros(1,nF);
            ruzeDb = zeros(1,nF);
            sigmaOverLambda = zeros(1,nF);
            fresnel_m = zeros(1,nF);
            nearField = false(1,nF);
            footprint_m = zeros(1,nF);
            for index = 1:nF
                psi = -2*pi*pathError_m/wavelengths_m(index);
                psi = psi - mean(psi);
                arrayFactor(index) = abs(mean(exp(1i*psi)));
                lossDb(index) = 20*log10(max(arrayFactor(index),realmin));
                ruzeDb(index) = -4.342944819*CE.rms_(psi)^2;
                sigmaOverLambda(index) = sigma_m/wavelengths_m(index);
                fresnel_m(index) = 2*apertureExtent_m^2/wavelengths_m(index);
                nearField(index) = fresnel_m(index) > slantRange_m;
                footprint_m(index) = wavelengths_m(index)*slantRange_m/ ...
                    max(apertureExtent_m,realmin);
            end

            % ---- sweep for the loss-vs-frequency figure -------------------------
            sweep_Hz = logspace(5,10.7,300);
            sweepDb = zeros(1,numel(sweep_Hz));
            for index = 1:numel(sweep_Hz)
                psi = -2*pi*pathError_m/(CE.C_mps/sweep_Hz(index));
                psi = psi - mean(psi);
                sweepDb(index) = 20*log10(max(abs(mean(exp(1i*psi))),realmin));
            end

            % ---- provenance and the honesty gate --------------------------------
            payload.physicalRangeRowsConsumed = CE.fieldNum_(diagnostics, ...
                'physicalRangeRowsConsumed',0);
            payload.physicalRangeLinkCount = CE.fieldNum_(diagnostics, ...
                'physicalRangeLinkCount',0);
            payload.relativePositionDof = CE.fieldNum_(diagnostics, ...
                'relativePositionDof',3*(nAssets-1));
            payload.rangeOnlyObservabilityStatus = CE.fieldStr_(diagnostics, ...
                'rangeOnlyObservabilityStatus','unavailable');
            payload.formalToRealisedSigmaRatio = CE.sigmaRatio_(diagnostics);
            [claimStatus, claimExplanation] = CE.claim_(payload);

            payload.available = true;
            payload.reason = 'ok';
            payload.nAssets = nAssets;
            payload.assetNames = CE.names_(diagnostics,nAssets);
            payload.time_s = CE.finalTime_(diagnostics);
            payload.targetMode = targetMode;
            payload.targetEcef_m = target_m;
            payload.truthEcef_m = rT;
            payload.slantRange_m = slantRange_m;
            payload.apertureExtent_m = apertureExtent_m;
            payload.losSpread_rad = losSpread_rad;
            payload.pathError_m = pathError_m;
            payload.pathErrorRms_m = sigma_m;
            payload.shapeOnlyPathError_m = shapeOnly_m;
            payload.shapeOnlyPathErrorRms_m = CE.rms_(shapeOnly_m);
            payload.commonOffset_m = norm(commonOffset_m);
            payload.commonOffsetLeakRms_m = CE.rms_(pathError_m - shapeOnly_m);
            payload.geometryPathErrorRms_m = CE.rms_(geometryTerm_m - mean(geometryTerm_m));
            payload.clockPathErrorRms_m = CE.rms_(clockError_m - mean(clockError_m));
            payload.clockTermAvailable = clockAvailable;
            payload.frequencies_Hz = frequencies_Hz;
            payload.wavelengths_m = wavelengths_m;
            payload.arrayFactorMagnitude = arrayFactor;
            payload.coherentGainLoss_dB = lossDb;
            payload.ruzeGainLoss_dB = ruzeDb;
            payload.sigmaOverLambda = sigmaOverLambda;
            payload.fresnelDistance_m = fresnel_m;
            payload.nearField = nearField;
            payload.groundFootprint_m = footprint_m;
            payload.coherenceFrequency_Hz = coherenceFrequency_Hz;
            payload.coherenceCriterionLambdaFraction = criterion;
            payload.incoherentFloor_dB = 10*log10(1/nAssets);
            payload.sweepFrequencies_Hz = sweep_Hz;
            payload.sweepGainLoss_dB = sweepDb;
            payload.coherenceClaimStatus = claimStatus;
            payload.coherenceClaimExplanation = claimExplanation;
        end

        % ================================================================
        function fig = plotPhasorChain(payload)
            % plotPhasorChain  Head-to-tail phasor addition at each reported frequency.
            fig = [];
            if ~revgnss.BeamformingPhasorDiagnostics.isAvailable_(payload); return; end
            CE = revgnss.BeamformingPhasorDiagnostics;
            frequencies_Hz = payload.frequencies_Hz;
            nF = min(numel(frequencies_Hz),3);
            if nF < 1; return; end

            fig = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 1180 460]);
            layout = tiledlayout(fig,1,nF,'TileSpacing','compact','Padding','compact');
            colors = lines(3);
            nAssets = payload.nAssets;
            for index = 1:nF
                axesHandle = nexttile(layout);
                hold(axesHandle,'on');
                axis(axesHandle,'equal');
                psi = -2*pi*payload.pathError_m/payload.wavelengths_m(index);
                psi = psi - mean(psi);
                phasors = exp(1i*psi);
                chain = [0, cumsum(phasors)];
                plot(axesHandle,[0 nAssets],[0 0],'-', ...
                    'Color',[0.85 0.85 0.85],'LineWidth',7);
                text(axesHandle,nAssets/2,-0.55,'ideal |\Sigma| = N', ...
                    'Color',[0.5 0.5 0.5],'HorizontalAlignment','center','FontSize',8);
                for element = 1:nAssets
                    quiver(axesHandle,real(chain(element)),imag(chain(element)), ...
                        real(phasors(element)),imag(phasors(element)),0, ...
                        'Color',colors(index,:),'LineWidth',1.6,'MaxHeadSize',0.5);
                end
                quiver(axesHandle,0,0,real(sum(phasors)),imag(sum(phasors)),0, ...
                    'Color','k','LineWidth',2.4,'MaxHeadSize',0.22);
                plot(axesHandle,real(chain),imag(chain),'o','MarkerSize',3.5, ...
                    'MarkerFaceColor',colors(index,:),'MarkerEdgeColor','none');
                grid(axesHandle,'on'); box(axesHandle,'on');
                xlabel(axesHandle,'Re'); ylabel(axesHandle,'Im');
                limit = nAssets*0.8 + 0.8;
                xlim(axesHandle,[-limit limit]); ylim(axesHandle,[-limit limit]);
                title(axesHandle,sprintf('%s   \\sigma_e = \\lambda/%.1f\n|AF| = %.3f   %.2f dB', ...
                    CE.frequencyLabel_(frequencies_Hz(index)), ...
                    payload.wavelengths_m(index)/max(payload.pathErrorRms_m,realmin), ...
                    payload.arrayFactorMagnitude(index), ...
                    payload.coherentGainLoss_dB(index)),'FontSize',10);
            end
            title(layout,sprintf(['Phasor addition of %d signals -- relative path error ' ...
                '\\sigma_e = %.3f m  [%s]'],nAssets,payload.pathErrorRms_m, ...
                payload.coherenceClaimStatus),'FontWeight','bold','FontSize',11);
        end

        function [fig, info, figSpread] = plotCommsPhasor(rel, results, cfg)
            % plotCommsPhasor  Fixed phasor diagram at the OPERATIONAL comms carrier.
            %
            % plotPhasorChain draws whichever three frequencies the run happened to report,
            % which move between scenarios and so cannot be compared across runs. This one is
            % pinned to cfg.beamforming.communicationFrequency_Hz (default 2.1 GHz) so the same
            % picture means the same thing in every multi-asset report.
            %
            % TWO OUTPUT FIGURES, deliberately separate rather than one side-by-side pair, so
            % each can be read at full width on the page:
            %
            %   fig       -- the phasor chain at one typical settled epoch.
            %   figSpread -- the distribution of the loss over the whole settled tail.
            %
            % TWO DELIBERATE CHOICES, both to stop the figure being over-read:
            %
            % 1. EPOCH SELECTION. Once sigma_e approaches lambda the phasor sum is a random
            %    walk of N unit vectors and the per-epoch dB is a DRAW, not a measurement. At a
            %    fixed sigma_e = 0.22 m this run produced -13.35 dB at one epoch and -5.07 dB at
            %    another. Picking the final epoch, or the epoch nearest the median LOSS, just
            %    picks a different draw. The epoch is therefore chosen on the underlying
            %    physical quantity -- path-error RMS closest to its settled median -- so the
            %    GEOMETRY drawn is typical even though its dB label is still one sample.
            % 2. figSpread EXISTS FOR THAT REASON. It shows the whole settled-tail
            %    distribution of the loss with the median and the N-element incoherent floor
            %    20log10(1/sqrt(N)) marked, so the reader sees the spread the single chain
            %    cannot show. Quote the median, never the chain's own label.
            fig = []; figSpread = [];
            CE  = revgnss.BeamformingPhasorDiagnostics;
            info = struct('available',false,'reason','notComputed','frequency_Hz',NaN, ...
                'nAssets',0,'epochIndex',NaN,'time_s',NaN,'pathErrorRms_m',NaN, ...
                'medianGainLoss_dB',NaN,'incoherentFloor_dB',NaN, ...
                'p10GainLoss_dB',NaN,'p90GainLoss_dB',NaN);

            fc = CE.getNum_(cfg,{'beamforming','communicationFrequency_Hz'},2.1e9);
            if ~(isscalar(fc) && isfinite(fc) && fc > 0); info.reason='badFrequency'; return; end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                info.reason = 'noSolvedPos'; return;
            end
            P = rel.solvedPos;
            if ndims(P) ~= 3; info.reason='badSolvedPos'; return; end
            [~, N, nEp] = size(P);
            if N < 2 || nEp < 2; info.reason='tooFewAssetsOrEpochs'; return; end
            [T, ~, ok] = CE.truthAndRaw_(results, N, nEp);
            if ~ok; info.reason='noTruth'; return; end

            lambda = CE.C_mps / fc;
            tsel   = max(1,floor(nEp/2)):nEp;                 % same tail convention as computeSeries
            sig    = nan(1,numel(tsel));
            loss   = nan(1,numel(tsel));
            eKeep  = nan(N,numel(tsel));
            for q = 1:numel(tsel)
                k = tsel(q);
                rT = T(:,:,k);
                if ~all(isfinite(rT(:))) || ~all(isfinite(reshape(P(:,:,k),[],1))); continue; end
                target_m = CE.targetPoint_(cfg, mean(rT,2));
                e = vecnorm(P(:,:,k)-target_m,2,1) - vecnorm(rT-target_m,2,1);
                e = e - mean(e);                              % common phase steers, costs nothing
                eKeep(:,q) = e(:);
                sig(q)  = CE.rms_(e);
                psi = -2*pi*e/lambda; psi = psi - mean(psi);
                loss(q) = 20*log10(max(abs(mean(exp(1i*psi))),realmin));
            end
            good = find(isfinite(sig));
            if isempty(good); info.reason='noFiniteEpoch'; return; end

            medSig = median(sig(good),'omitnan');
            [~, pick] = min(abs(sig(good)-medSig));
            q = good(pick);
            e = eKeep(:,q).';
            floorDb = 20*log10(1/sqrt(N));

            info.available        = true;
            info.reason           = 'ok';
            info.frequency_Hz     = fc;
            info.nAssets          = N;
            info.epochIndex       = tsel(q);
            info.pathErrorRms_m   = sig(q);
            info.medianGainLoss_dB= median(loss(good),'omitnan');
            info.incoherentFloor_dB = floorDb;
            info.p10GainLoss_dB   = prctile(loss(good),10);
            info.p90GainLoss_dB   = prctile(loss(good),90);
            try; info.time_s = rel.time_s(tsel(q)); catch; end

            psi = -2*pi*e/lambda; psi = psi - mean(psi);
            phasors = exp(1i*psi);
            chain   = [0, cumsum(phasors)];

            % FONT SIZING. Both figures are placed at width=\linewidth in the report's
            % 0.62\textwidth plot column, i.e. ~310 pt on the page. A 820 px canvas is 615 pt,
            % so everything is scaled by ~0.5 when typeset and a nominal 10 pt label prints at
            % ~5 pt -- unreadable. Fonts are therefore set from the canvas width so the PRINTED
            % size lands near the body text, and the canvas stays large enough for the raster
            % to hold detail at 150 dpi.
            canvasW  = 820;
            printedW = 310;                                    % pt, = 0.62\textwidth
            k        = (canvasW*72/96) / printedW;             % canvas pt per printed pt
            fTick    = 10*k;  fLab = 10.5*k;  fTitle = 11.5*k;  fSub = 9.5*k;  fNote = 9*k;

            % ---- FIGURE 1: the phasor chain -------------------------------------------------
            % Axis limits come from the DATA (chain plus the ideal bar), not from the old
            % fixed +/-(0.8N+0.8) box: once the phasors scatter the chain folds back on itself
            % and spans ~2 units, so the fixed box left the whole picture in a tiny blob at
            % the centre. axis equal is kept -- the angles are the physics and must not shear.
            fig = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 canvasW 560]);
            ax1 = axes(fig); hold(ax1,'on'); axis(ax1,'equal');
            plot(ax1,[0 N],[0 0],'-','Color',[0.85 0.85 0.85],'LineWidth',9);
            for element = 1:N
                quiver(ax1,real(chain(element)),imag(chain(element)), ...
                    real(phasors(element)),imag(phasors(element)),0, ...
                    'Color',[0 0.447 0.741],'LineWidth',2.6,'MaxHeadSize',0.45);
            end
            quiver(ax1,0,0,real(sum(phasors)),imag(sum(phasors)),0, ...
                'Color','k','LineWidth',3.6,'MaxHeadSize',0.35);
            plot(ax1,real(chain),imag(chain),'o','MarkerSize',5, ...
                'MarkerFaceColor',[0 0.447 0.741],'MarkerEdgeColor','none');
            grid(ax1,'on'); box(ax1,'on');
            set(ax1,'FontSize',fTick);
            xlabel(ax1,'Re','FontSize',fLab); ylabel(ax1,'Im','FontSize',fLab);
            % Window the CHAIN, not the chain plus the full ideal bar. Including the bar's far
            % end makes the x-range ~N wide, and with axis equal a scattered chain -- which
            % spans only ~2 -- is then squashed into the left edge and unreadable. The bar is
            % still drawn from 0 to N and simply runs off the right-hand side, which carries
            % the "the total is nowhere near N" message on its own; the label states where it
            % would end.
            pad   = 0.55;
            reC   = [real(chain), 0];  imC = [imag(chain), 0];
            xr    = [min(reC)-pad, max(reC)+pad];
            yr    = [min(imC)-pad, max(imC)+pad];
            xr(2) = max(xr(2), 0.42*N);        % always show a stretch of the ideal bar
            xlim(ax1,xr); ylim(ax1,yr);
            % Bottom-right corner, not next to the bar at Im = 0: the chain routinely passes
            % through there and the label sat on top of it. Kept SHORT and clipped -- the x
            % range is set by the data and varies run to run, so a long sentence overflowed
            % the axes box on the left whenever the chain happened to be compact.
            text(ax1,xr(2)-0.03*diff(xr),yr(1)+0.07*diff(yr), ...
                sprintf('grey: all %d in step',N), ...
                'Color',[0.45 0.45 0.45],'HorizontalAlignment','right', ...
                'FontSize',fNote,'Clipping','on');
            title(ax1,sprintf('Adding the %d signals together at %s', ...
                N, CE.frequencyLabel_(fc)),'FontWeight','bold','FontSize',fTitle);
            subtitle(ax1,sprintf('arrival times spread over %s', ...
                CE.spreadInWavelengths_(sig(q), lambda)),'FontSize',fSub);

            % ---- FIGURE 2: how much that total varies over the settled tail -----------------
            figSpread = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 canvasW 470]);
            ax2 = axes(figSpread); hold(ax2,'on');
            histogram(ax2,loss(good),24,'FaceColor',[0.6 0.6 0.6],'EdgeColor','none');
            yl = [0, ylim(ax2)*[0;1]*1.10];       % headroom so the tallest bin is not flush
            plot(ax2,[info.medianGainLoss_dB info.medianGainLoss_dB],yl,'k-','LineWidth',3);
            plot(ax2,[floorDb floorDb],yl,'r--','LineWidth',2.6);
            plot(ax2,[loss(q) loss(q)],yl,'b-','LineWidth',2.2);
            ylim(ax2,yl); grid(ax2,'on'); box(ax2,'on');
            set(ax2,'FontSize',fTick);
            xlabel(ax2,'coherent gain loss [dB]','FontSize',fLab);
            ylabel(ax2,'number of epochs','FontSize',fLab);
            legend(ax2,{'settled epochs','median','no-coherence floor','the epoch drawn above'}, ...
                'Location','northwest','FontSize',fSub);
            % Title kept short: at fTitle the longer form overran the canvas and was clipped.
            title(ax2,'The same loss at every settled epoch', ...
                'FontWeight','bold','FontSize',fTitle);
            subtitle(ax2,sprintf('median %.2f dB;  middle 80%% spans %.2f to %.2f dB', ...
                info.medianGainLoss_dB, info.p10GainLoss_dB, info.p90GainLoss_dB), ...
                'FontSize',fSub);
        end

        function fig = plotPathErrorSeries(series)
            % plotPathErrorSeries  The beamforming budget over the arc, from the ISL-solved
            % geometry: differential path error against the wavelength thresholds it must beat,
            % and the coherent gain that survives at each carrier.
            fig = [];
            if ~isstruct(series) || ~isfield(series,'available') || ~series.available; return; end
            if isempty(series.pathErrorRms_m); return; end
            CE = revgnss.BeamformingPhasorDiagnostics;
            t = series.time_s(:).';
            fig = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 1180 1040]);
            tl = tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');

            sm = @(v) CE.runningMedian_(v);
            nF = numel(series.frequencies_Hz);
            cols = [0.10 0.35 0.65; 0.15 0.55 0.25; 0.75 0.30 0.20; 0.45 0.30 0.65];

            % --- panel 1: metres of differential path -------------------------------------
            % Curves are running medians so the trend is readable; every quoted statistic comes
            % from the raw series. The lambda/20 thresholds go in the LEGEND, not as yline
            % labels: at these error levels all three sit within millimetres of the axis floor
            % and their labels would print on top of one another.
            ax = nexttile(tl,1); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
            hasRaw = ~isempty(series.rawPathErrorRms_m) && any(isfinite(series.rawPathErrorRms_m));
            if hasRaw
                plot(ax,t,sm(series.rawPathErrorRms_m),'-','LineWidth',1.6, ...
                    'Color',[0.75 0.45 0.20],'DisplayName','raw per-asset EKF');
            end
            plot(ax,t,sm(series.pathErrorRms_m),'-','LineWidth',2.0, ...
                'Color',[0.10 0.35 0.65],'DisplayName','ISL relative solution');
            if series.clockTermAvailable
                plot(ax,t,sm(series.geometryPathErrorRms_m),'--','LineWidth',1.2, ...
                    'Color',[0.35 0.60 0.35],'DisplayName','geometry term');
                plot(ax,t,sm(series.clockPathErrorRms_m),':','LineWidth',1.4, ...
                    'Color',[0.60 0.35 0.60],'DisplayName','clock term');
            end
            for f = 1:nF
                plot(ax,[t(1) t(end)],series.lambdaOver20_m(f)*[1 1],'-','LineWidth',1.0, ...
                    'Color',cols(min(f,size(cols,1)),:), ...
                    'DisplayName',sprintf('\\lambda/20 at %s = %.4f m', ...
                    CE.frequencyLabel_(series.frequencies_Hz(f)), series.lambdaOver20_m(f)));
            end
            xlim(ax,[t(1) t(end)]);
            ylabel(ax,'differential path error, RMS [m]');
            legend(ax,'Location','northeast','FontSize',9,'NumColumns',2);
            set(ax,'FontSize',10); ax.YAxis.Exponent = 0;
            ax.YAxis.TickLabelFormat = '%.4g';
            nf = ''; if any(series.nearField); nf = ', radiating near field'; end
            title(ax,sprintf(['Beamforming path error from the ISL-solved geometry ' ...
                '(aperture %.0f m, slant %.0f km%s)'], ...
                series.apertureExtent_m, series.slantRange_m/1e3, nf),'FontWeight','bold');
            subtitle(ax,['e_i = (|p-rHat_i| - |p-r_i|) + (bHat_i-b_i), mean removed;  ' ...
                'the mean is a free beam phase, only the SPREAD costs gain'],'FontSize',9.5);

            % --- panel 2: does the spot MOVE, or does it DIM? -----------------------------
            ax3 = nexttile(tl,2); hold(ax3,'on'); grid(ax3,'on'); box(ax3,'on');
            if ~isempty(series.spotDisplacement_m)
                plot(ax3,t,sm(series.spotDisplacement_m),'-','LineWidth',2.0, ...
                    'Color',[0.75 0.30 0.20],'DisplayName','spot displacement on the ground');
                for f = 1:nF
                    plot(ax3,[t(1) t(end)],series.beamFootprint_m(f)*[1 1],'-','LineWidth',1.0, ...
                        'Color',cols(min(f,size(cols,1)),:), ...
                        'DisplayName',sprintf('beam width at %s = %.0f m', ...
                        CE.frequencyLabel_(series.frequencies_Hz(f)), series.beamFootprint_m(f)));
                end
            end
            xlim(ax3,[t(1) t(end)]);
            ylabel(ax3,'spot offset from the aim point [m]');
            legend(ax3,'Location','northeast','FontSize',9,'NumColumns',2);
            set(ax3,'FontSize',10); ax3.YAxis.Exponent = 0;
            ax3.YAxis.TickLabelFormat = '%.4g';
            subtitle(ax3,sprintf(['a LINEAR path error across the array is a wavefront tilt: ' ...
                'the beam stays sharp and lands elsewhere.  %.0f%% of the budget is this ' ...
                'mispointing (calibratable); the rest genuinely dims the beam'], ...
                100*max(0,min(1,series.tiltFraction))),'FontSize',9.5);

            % --- panel 3: what that costs in coherent gain --------------------------------
            ax2 = nexttile(tl,3); hold(ax2,'on'); grid(ax2,'on'); box(ax2,'on');
            floorDb = 10*log10(1/max(series.nAssets,1));
            for f = 1:nF
                plot(ax2,t,sm(series.coherentGainLoss_dB(f,:)),'-','LineWidth',1.8, ...
                    'Color',cols(min(f,size(cols,1)),:), ...
                    'DisplayName',sprintf('%s, at the aim point', ...
                    CE.frequencyLabel_(series.frequencies_Hz(f))));
                plot(ax2,t,sm(series.residualGainLoss_dB(f,:)),'--','LineWidth',1.4, ...
                    'Color',cols(min(f,size(cols,1)),:), ...
                    'DisplayName',sprintf('%s, at where it LANDS', ...
                    CE.frequencyLabel_(series.frequencies_Hz(f))));
            end
            yline(ax2,-1,'--','1 dB','Color',[0.35 0.35 0.35],'HandleVisibility','off');
            yline(ax2,floorDb,':',sprintf('1/N floor (%.1f dB)',floorDb), ...
                'Color',[0.5 0.5 0.5],'HandleVisibility','off');
            xlim(ax2,[t(1) t(end)]);
            xlabel(ax2,'time [s]'); ylabel(ax2,'coherent gain loss [dB]');
            legend(ax2,'Location','southwest','FontSize',9,'NumColumns',2);
            set(ax2,'FontSize',10); ax2.YAxis.Exponent = 0;
            ax2.YAxis.TickLabelFormat = '%.4g';
            ylim(ax2,[max(floorDb-4,-40) 1]);
            % Below the 1/N floor the phasors are effectively random and the dB value is noise
            % about that floor, NOT a meaningful ranking between configurations. Say so on the
            % figure rather than let a reader compare two incoherent cases. Kept to one short
            % line: a subtitle wider than the axes is silently clipped at BOTH ends.
            if all(series.tailCoherentGainLoss_dB <= floorDb + 1)
                note = sprintf(['incoherent at every carrier shown -- below the %.1f dB floor ' ...
                    'this value is random, do not rank configurations by it'], floorDb);
            else
                note = 'solid = at the aim point,  dashed = at where the beam actually lands';
            end
            subtitle(ax2,note,'FontSize',9.5);
        end

        function fig = plotLossVsFrequency(payload)
            % plotLossVsFrequency  Where coherence survives, with the band markers.
            fig = [];
            if ~revgnss.BeamformingPhasorDiagnostics.isAvailable_(payload); return; end
            if isempty(payload.sweepFrequencies_Hz); return; end

            fig = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 900 560]);
            axesHandle = axes(fig);
            hold(axesHandle,'on');
            plot(axesHandle,payload.sweepFrequencies_Hz/1e9,payload.sweepGainLoss_dB, ...
                '-','LineWidth',1.8,'Color',[0.10 0.35 0.65]);
            yline(axesHandle,payload.incoherentFloor_dB,':', ...
                sprintf('1/N floor (%.1f dB)',payload.incoherentFloor_dB), ...
                'Color',[0.35 0.35 0.35],'LineWidth',1.3);
            yline(axesHandle,-1,'--','1 dB','Color',[0.3 0.3 0.3]);
            if isfinite(payload.coherenceFrequency_Hz)
                xline(axesHandle,payload.coherenceFrequency_Hz/1e9,'-', ...
                    sprintf('\\lambda/%.0f at %s',payload.coherenceCriterionLambdaFraction, ...
                    revgnss.BeamformingPhasorDiagnostics.frequencyLabel_( ...
                    payload.coherenceFrequency_Hz)), ...
                    'Color',[0.15 0.55 0.25],'LineWidth',1.5,'LabelOrientation','horizontal');
            end
            for band = [0.15 0.4 2.1 8 30]
                xline(axesHandle,band,':','Color',[0.65 0.65 0.65]);
            end
            set(axesHandle,'XScale','log');
            grid(axesHandle,'on'); box(axesHandle,'on');
            xlabel(axesHandle,'carrier frequency [GHz]');
            ylabel(axesHandle,'coherent gain loss [dB]');
            ylim(axesHandle,[-30 2]);
            title(axesHandle,sprintf(['Coherent gain loss vs carrier frequency ' ...
                '(\\sigma_e = %.3f m, N = %d)'],payload.pathErrorRms_m,payload.nAssets));
        end

        function fig = plotBeamPattern(payload)
            % plotBeamPattern  Focused beam cut, ideal versus the estimated formation.
            fig = [];
            if ~revgnss.BeamformingPhasorDiagnostics.isAvailable_(payload); return; end
            if isempty(payload.frequencies_Hz); return; end
            CE = revgnss.BeamformingPhasorDiagnostics;
            % Draw at the coherence frequency where the beam is meaningful; falling back
            % to the first reported frequency keeps the figure defined when sigma is 0.
            frequency_Hz = payload.coherenceFrequency_Hz;
            if ~isfinite(frequency_Hz) || frequency_Hz <= 0
                frequency_Hz = payload.frequencies_Hz(1);
            end
            truth_m = payload.truthEcef_m;
            if isempty(truth_m) || size(truth_m,1) ~= 3; return; end
            target_m = payload.targetEcef_m;
            lambda_m = CE.C_mps/frequency_Hz;
            waveNumber = 2*pi/lambda_m;

            boresight = (target_m - mean(truth_m,2));
            boresight = boresight/norm(boresight);
            seed = [0;0;1];
            if abs(dot(seed,boresight)) > 0.9; seed = [1;0;0]; end
            crossAxis = cross(boresight,seed);
            crossAxis = crossAxis/norm(crossAxis);

            footprint_m = lambda_m*payload.slantRange_m/max(payload.apertureExtent_m,realmin);
            offsets_m = linspace(-3*footprint_m,3*footprint_m,1200);
            rangeAt = @(p) vecnorm(truth_m - p,2,1).';
            idealWeights = exp(-1i*waveNumber*rangeAt(target_m));
            actualWeights = exp(-1i*waveNumber*(rangeAt(target_m) + payload.pathError_m(:)));
            idealPattern = zeros(1,numel(offsets_m));
            actualPattern = zeros(1,numel(offsets_m));
            for index = 1:numel(offsets_m)
                ranges_m = rangeAt(target_m + crossAxis*offsets_m(index));
                steering = exp(1i*waveNumber*ranges_m);
                idealPattern(index) = abs(mean(idealWeights.*steering))^2;
                actualPattern(index) = abs(mean(actualWeights.*steering))^2;
            end

            fig = figure('Visible','off','Color','white','Units','pixels', ...
                'Position',[80 80 900 560]);
            axesHandle = axes(fig);
            hold(axesHandle,'on');
            plot(axesHandle,offsets_m/1000,10*log10(max(idealPattern,realmin)), ...
                'k-','LineWidth',2.2,'DisplayName','ideal (zero phase error)');
            plot(axesHandle,offsets_m/1000,10*log10(max(actualPattern,realmin)), ...
                '-','LineWidth',1.5,'Color',[0.15 0.55 0.25], ...
                'DisplayName','estimated formation');
            grid(axesHandle,'on'); box(axesHandle,'on');
            ylim(axesHandle,[-35 2]);
            xlabel(axesHandle,'cross-track offset at the target [km]');
            ylabel(axesHandle,'normalised gain [dB]');
            legend(axesHandle,'Location','southwest','FontSize',8);
            title(axesHandle,sprintf(['Focused beam at %s, slant %.0f km, ' ...
                '\\lambdaR/D = %.1f km'],CE.frequencyLabel_(frequency_Hz), ...
                payload.slantRange_m/1000,footprint_m/1000));
        end
    end

    methods (Static, Access = private)

        function tf = isAvailable_(payload)
            tf = isstruct(payload) && isfield(payload,'available') && ...
                ~isempty(payload.available) && payload.available && ...
                isfield(payload,'pathError_m') && ~isempty(payload.pathError_m);
        end

        function [clockError_m, available] = finalClockError_m_( ...
                jointEstimate, multiAssetTruth, nAssets)
            % finalClockError_m_  bHat - b at the final truth epoch, in metres.
            %
            % A missing clock term is reported as zero rather than as a failure: the
            % geometry half of the phase budget is still worth reporting, and
            % clockTermAvailable tells the consumer the budget is incomplete.
            clockError_m = zeros(1,nAssets);
            available = false;
            if ~isstruct(jointEstimate) || ~isstruct(multiAssetTruth); return; end
            if ~isfield(jointEstimate,'asset') || ~isfield(multiAssetTruth,'asset'); return; end
            if ~isfield(jointEstimate,'time_s') || ~isfield(multiAssetTruth,'time_s'); return; end
            if numel(jointEstimate.asset) < nAssets || ...
                    numel(multiAssetTruth.asset) < nAssets
                return
            end
            truthTime_s = multiAssetTruth.time_s(:).';
            estimateTime_s = jointEstimate.time_s(:);
            if isempty(truthTime_s) || numel(estimateTime_s) < 2; return; end
            finalTime_s = truthTime_s(end);
            values = zeros(1,nAssets);
            for assetIndex = 1:nAssets
                estimateAsset = jointEstimate.asset(assetIndex);
                truthAsset = multiAssetTruth.asset(assetIndex);
                if ~isfield(estimateAsset,'rxClockBias_m') || ...
                        ~isfield(truthAsset,'rxClockBias_m')
                    return
                end
                estimateSeries = estimateAsset.rxClockBias_m(:);
                truthSeries = truthAsset.rxClockBias_m(:);
                if numel(estimateSeries) ~= numel(estimateTime_s) || ...
                        numel(truthSeries) < numel(truthTime_s)
                    return
                end
                estimated_m = interp1(estimateTime_s,estimateSeries,finalTime_s,'linear',NaN);
                truth_m = truthSeries(numel(truthTime_s));
                if ~isfinite(estimated_m) || ~isfinite(truth_m); return; end
                values(assetIndex) = estimated_m - truth_m;
            end
            clockError_m = values;
            available = true;
        end

        function [target_m, mode] = targetPoint_(cfg, centroid_m)
            CE = revgnss.BeamformingPhasorDiagnostics;
            mode = CE.getStr_(cfg,{'beamforming','target','mode'},'centroidNadir');
            switch mode
                case 'ecef'
                    candidate = CE.getVec_(cfg,{'beamforming','target','ecef_m'});
                    if numel(candidate) == 3 && all(isfinite(candidate))
                        target_m = candidate(:);
                        return
                    end
                    mode = 'centroidNadir';
                case 'centroidNadir'
                    % handled below
                otherwise
                    mode = 'centroidNadir';
            end
            radius = norm(centroid_m);
            if ~(radius > 0)
                target_m = zeros(3,1);
                return
            end
            target_m = centroid_m*(CE.EarthRadius_m/radius);
        end

        function extent_m = maxBaseline_(positions_m)
            extent_m = 0;
            nAssets = size(positions_m,2);
            for i = 1:nAssets
                for k = i+1:nAssets
                    extent_m = max(extent_m,norm(positions_m(:,i)-positions_m(:,k)));
                end
            end
        end

        function frequencies_Hz = frequencyList_(cfg, coherenceFrequency_Hz)
            % frequencyList_  Explicit config list, else a derived coherent/partial/dead
            % triple so the phasor chain visibly curls across the three panels.
            CE = revgnss.BeamformingPhasorDiagnostics;
            explicit = CE.getVec_(cfg,{'beamforming','frequencies_Hz'});
            explicit = explicit(isfinite(explicit) & explicit > 0);
            if ~isempty(explicit)
                frequencies_Hz = sort(explicit(:).');
                return
            end
            carrier_Hz = CE.getNum_(cfg,{'signals','L1','frequency_Hz'},NaN);
            if ~(isfinite(carrier_Hz) && carrier_Hz > 0)
                carrier_Hz = CE.getNum_(cfg,{'signals','frequencyHz'},1.57542e9);
            end
            if isfinite(coherenceFrequency_Hz) && coherenceFrequency_Hz > 0
                frequencies_Hz = [coherenceFrequency_Hz, 10*coherenceFrequency_Hz, carrier_Hz];
            else
                frequencies_Hz = carrier_Hz;
            end
            frequencies_Hz = unique(frequencies_Hz(isfinite(frequencies_Hz) & frequencies_Hz > 0));
        end

        function ratio = sigmaRatio_(diagnostics)
            % sigmaRatio_  Realised relative error over the filter's own sigma.
            %
            % A ratio far above 1 means the covariance is not to be believed, which is
            % exactly the situation in which a formally tight beam claim is worthless.
            ratio = NaN;
            if ~isfield(diagnostics,'relativeBaselineError_m') || ...
                    ~isfield(diagnostics,'relativeBaselineSigma3d_m')
                return
            end
            realised = diagnostics.relativeBaselineError_m;
            formal = diagnostics.relativeBaselineSigma3d_m;
            if isempty(realised) || isempty(formal) || ~isequal(size(realised),size(formal))
                return
            end
            realisedFinal = realised(:,end);
            formalFinal = formal(:,end);
            valid = isfinite(realisedFinal) & isfinite(formalFinal) & formalFinal > 0;
            if ~any(valid); return; end
            ratio = median(realisedFinal(valid)./formalFinal(valid));
        end

        function [status, explanation] = claim_(payload)
            % claim_  Refuse a coherence claim the formation solution cannot support.
            if payload.physicalRangeRowsConsumed <= 0
                status = 'notClaimableNoPhysicalRangeRows';
                explanation = ['No physical inter-satellite range row entered the ' ...
                    'estimator, so the relative geometry is propagated rather than ' ...
                    'measured. Any coherence read from it reflects the initial ' ...
                    'condition, not an estimate.'];
                return
            end
            if payload.relativePositionDof > 0 && ...
                    payload.physicalRangeLinkCount < payload.relativePositionDof
                status = 'notClaimableInsufficientConstraints';
                explanation = sprintf(['Only %d scalar range constraints act on %d ' ...
                    'relative degrees of freedom, so the relative state is rank ' ...
                    'deficient and the unconstrained directions are unbounded.'], ...
                    payload.physicalRangeLinkCount, payload.relativePositionDof);
                return
            end
            status = 'claimable';
            explanation = ['Physical range rows were consumed and the scalar ' ...
                'constraint count covers the relative degrees of freedom.'];
            if isfinite(payload.formalToRealisedSigmaRatio) && ...
                    payload.formalToRealisedSigmaRatio > 3
                explanation = [explanation sprintf([' Note the realised relative error ' ...
                    'exceeds the filter''s own sigma by %.0fx, so the loss below is ' ...
                    'trustworthy but the covariance is not.'], ...
                    payload.formalToRealisedSigmaRatio)];
            end
        end

        function names = names_(diagnostics,nAssets)
            names = arrayfun(@(a) sprintf('GEO-%d',a),1:nAssets,'UniformOutput',false);
            if isfield(diagnostics,'names') && iscell(diagnostics.names) && ...
                    numel(diagnostics.names) == nAssets
                names = cellfun(@char,diagnostics.names(:).','UniformOutput',false);
            end
        end

        function time_s = finalTime_(diagnostics)
            time_s = NaN;
            if isfield(diagnostics,'time_s') && ~isempty(diagnostics.time_s)
                time_s = diagnostics.time_s(end);
            end
        end

        function label = frequencyLabel_(frequency_Hz)
            if frequency_Hz >= 1e9
                label = sprintf('%.2f GHz',frequency_Hz/1e9);
            elseif frequency_Hz >= 1e6
                label = sprintf('%.1f MHz',frequency_Hz/1e6);
            else
                label = sprintf('%.1f kHz',frequency_Hz/1e3);
            end
        end

        function value = rms_(values)
            values = values(isfinite(values));
            if isempty(values); value = NaN; return; end
            value = sqrt(mean(values(:).^2));
        end

        function s = spreadInWavelengths_(spread_m, lambda_m)
            % spreadInWavelengths_  Path spread as a plain-language phrase.
            % "lambda/0.5" is a true but unreadable way of saying "two wavelengths", and the
            % lambda/K form only reads naturally while K > 1, i.e. while the array is still
            % coherent. Below that, quote whole wavelengths instead.
            if ~(isscalar(spread_m) && isfinite(spread_m) && spread_m > 0) || ...
                    ~(isscalar(lambda_m) && isfinite(lambda_m) && lambda_m > 0)
                s = 'an undetermined fraction of a wavelength'; return
            end
            nWave = spread_m / lambda_m;
            if nWave < 1
                s = sprintf('%.4f m, or \\lambda/%.1f', spread_m, 1/nWave);
            else
                s = sprintf('%.4f m, or %.1f wavelengths', spread_m, nWave);
            end
        end

        function value = fieldNum_(source,name,defaultValue)
            value = defaultValue;
            if isfield(source,name) && isnumeric(source.(name)) && ...
                    isscalar(source.(name)) && isfinite(source.(name))
                value = source.(name);
            end
        end

        function value = fieldStr_(source,name,defaultValue)
            value = defaultValue;
            if isfield(source,name) && (ischar(source.(name)) || isstring(source.(name)))
                value = char(source.(name));
            end
        end

        function value = getNum_(cfg,path,defaultValue)
            value = revgnss.BeamformingPhasorDiagnostics.walk_(cfg,path,defaultValue);
            if ~(isnumeric(value) && isscalar(value) && isfinite(value))
                value = defaultValue;
            end
        end

        function value = getVec_(cfg,path)
            value = revgnss.BeamformingPhasorDiagnostics.walk_(cfg,path,[]);
            if ~isnumeric(value); value = []; end
            value = value(:).';
        end

        function value = getStr_(cfg,path,defaultValue)
            value = revgnss.BeamformingPhasorDiagnostics.walk_(cfg,path,defaultValue);
            if ~(ischar(value) || isstring(value)); value = defaultValue; end
            value = char(value);
        end

        function value = getBool_(cfg,path,defaultValue)
            value = revgnss.BeamformingPhasorDiagnostics.walk_(cfg,path,defaultValue);
            if ~(islogical(value) || isnumeric(value)) || ~isscalar(value)
                value = defaultValue;
            end
            value = logical(value);
        end

        function value = walk_(root,path,defaultValue)
            value = defaultValue;
            node = root;
            for index = 1:numel(path)
                if ~isstruct(node) || ~isfield(node,path{index}); return; end
                node = node.(path{index});
            end
            value = node;
        end
    end
end
