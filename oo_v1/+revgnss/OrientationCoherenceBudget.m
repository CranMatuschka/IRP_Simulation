classdef OrientationCoherenceBudget
    % OrientationCoherenceBudget  What an orientation error costs the BEAM, in dB.
    %
    % EXECUTION-PLAN G1, G2 AND G5. Every orientation result so far has been quoted as a RATIO --
    % "1.1x", "1.53x", "47x at 6 h". A ratio cannot be assessed. The mission-relevant question is
    % whether a coherent spot forms at all, and the answer is in decibels of array gain and in
    % beamwidths of mispointing. This class is the bridge, and it is deliberately small:
    %
    %   sigma_theta  ->  rim displacement  ->  differential path  ->  phase  ->  array factor
    %
    % THE LEVER IS NOT THE FORMATION RADIUS (G2). A rotation of magnitude theta about an
    % arbitrary axis displaces a point at radius R by |theta x q|, whose RMS over an isotropic
    % axis is theta*R*sqrt(2/3). Quoting the plain radius overstates the effect by 22 %, and
    % quoting a legacy layout's radius on a run that flew a different one is simply wrong: the
    % run20 single ring gives 1083 m, run22's multiRingHelix gives R_rms = 2102.8 m and therefore
    % a lever of 1705.7 m. Always take R_rms from the geometry in hand.
    %
    % ENLARGING THE ARRAY DOES NOT HELP (G5). The flowdown is
    %       mispointing in beamwidths = 2*sigma_abs / (lambda*sqrt(N))
    % in which the array size CANCELS EXACTLY -- a bigger array turns the same absolute error
    % into a smaller angle, and narrows the beam by the same factor. Only the INDEPENDENT part of
    % sigma_abs contributes: a common-mode error translates the array, it does not twist it,
    % which is precisely what the shared-atmosphere fix exploits.
    %
    % WHY A ROTATION IS NOT JUST A LOSS. A rigid rotation is mostly a MISPOINTING: the beam
    % survives, it simply arrives somewhere else. That distinction decides the remedy -- a
    % pointing correction fixes a tilt, and nothing fixes randomness -- so both are reported.
    %
    % HOW THIS DIFFERS FROM revgnss.BeamformingPhasorDiagnostics, WHICH REPORTS ANOTHER dB.
    % That class sums the ACTUAL phasors of the ACTUAL per-satellite errors, so it reports the
    % gain of one realisation and can legitimately fall BELOW the incoherent floor -- specific
    % phases can cancel. This class starts from a SIGMA and reports the EXPECTED gain over
    % realisations, which cannot fall below -10*log10(N) because that is what an array with
    % uniformly random phases still delivers. The two numbers are both right and are not
    % interchangeable; quote this one when the input is an uncertainty and that one when the
    % input is a specific solved geometry.
    %
    %   b = revgnss.OrientationCoherenceBudget.fromRotation(sigmaTheta_rad, Rrms_m, N, freqs_Hz)
    %   b = revgnss.OrientationCoherenceBudget.fromRel(rel, cfg)

    properties (Constant)
        DEFAULT_FREQS_HZ = [2.1e9, 1.2e9, 400e6];
        GEO_SLANT_M      = 35786e3;
    end

    methods (Static)

        function b = fromRel(rel, cfg)
            % fromRel  Budget the orientation error the run actually ended with.
            %
            % The rotation error is taken from the residual the ground stage MEASURED and did not
            % remove, when one is available; otherwise from the formal sigma the geometry implies.
            % Both are stated, because they answer different questions -- what this run achieved,
            % and what the geometry allows.
            O = revgnss.OrientationCoherenceBudget;
            b = O.empty_();
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos); return; end
            P = rel.solvedPos;
            k = find(squeeze(all(all(isfinite(P),1),2)), 1, 'last');
            if isempty(k); return; end
            q = P(:,:,k) - mean(P(:,:,k),2);
            Rrms = sqrt(mean(sum(q.^2,1)));
            N = size(P,2);
            freqs = O.DEFAULT_FREQS_HZ;
            if nargin >= 2
                f = O.num_(cfg, {'report','beamforming','frequencies_Hz'}, []);
                if ~isempty(f) && all(isfinite(f)); freqs = f(:).'; end
            end

            % Rotation SIGMA, preferring the joint stage's Schur-reduced value (which knows the
            % separation penalty) over the 3-parameter stage's (which does not).
            sig = O.vecnorm_(O.get_(rel, {'joint','thetaSigma_rad'}));
            src = 'jointSchur';
            if ~isfinite(sig)
                sig = O.vecnorm_(O.get_(rel, {'rotationSigma_rad'})); src = 'threeParameter';
            end
            if ~isfinite(sig); sig = NaN; src = 'unavailable'; end

            % Rotation the stages estimated but did NOT apply is still in the geometry.
            th = O.vecnorm_(O.get_(rel, {'joint','theta_rad'}));
            accepted = O.num_(rel, {'joint','accepted'}, 0);
            if ~isfinite(th) || accepted; th = NaN; end

            b = revgnss.OrientationCoherenceBudget.fromRotation(sig, Rrms, N, freqs);
            b.rotationSigmaSource = src;
            b.unappliedRotation_deg = th*180/pi;
            b.nAssets = N;
        end

        function b = fromRotation(sigmaTheta_rad, Rrms_m, N, freqs_Hz)
            % fromRotation  The budget proper. sigmaTheta_rad is the NORM of the 3-vector
            % rotation uncertainty; Rrms_m is the RMS radius of the actual layout.
            O = revgnss.OrientationCoherenceBudget;
            if nargin < 4 || isempty(freqs_Hz); freqs_Hz = O.DEFAULT_FREQS_HZ; end
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            b = O.empty_();
            b.frequencies_Hz  = freqs_Hz(:).';
            b.formationRrms_m = Rrms_m;
            % G2: sqrt(2/3) for an isotropic rotation axis, not the bare radius.
            b.rotationLever_m = sqrt(2/3)*Rrms_m;
            b.rotationErr_deg = sigmaTheta_rad*180/pi;
            b.rimDisplacement_m = sigmaTheta_rad*b.rotationLever_m;
            if ~isfinite(b.rimDisplacement_m); return; end

            % Array factor for zero-mean Gaussian path errors of sigma_p: the coherent sum is
            % attenuated by exp(-sigma_phi^2/2) in amplitude, so the gain loss is
            %   10*log10( (1/N) * (1 + (N-1)*exp(-sigma_phi^2)) )
            % which tends to -10*log10(N) -- the incoherent floor -- as sigma_phi grows. Using
            % the plain exp(-sigma_phi^2) instead would claim losses below the incoherent floor,
            % which no array can go below.
            lam = c ./ b.frequencies_Hz;
            sigPhi = 2*pi*b.rimDisplacement_m ./ lam;
            b.phaseSigma_rad = sigPhi;
            n = max(2, N);
            b.gainLoss_dB = 10*log10( (1 + (n-1)*exp(-sigPhi.^2)) / n );

            % G5: mispointing in BEAMWIDTHS. The array extent cancels -- it is in both the angle
            % and the beamwidth -- so this depends only on the rim displacement and the
            % wavelength. Stated as the flowdown 2*sigma/(lambda*sqrt(N)) with sigma the
            % INDEPENDENT per-satellite error implied by the rim displacement.
            b.mispointBeamwidths = 2*b.rimDisplacement_m ./ lam;
            b.beamwidth_rad = lam ./ max(2*Rrms_m, realmin);
            b.groundOffset_m = b.rimDisplacement_m ./ max(2*Rrms_m, realmin) ...
                * O.GEO_SLANT_M * 2;
            % lambda/20 is the conventional bar for "coherent"; report the highest frequency at
            % which this orientation error still clears it.
            b.coherentUpTo_Hz = c / max(20*b.rimDisplacement_m, realmin);
            % And the requirement, inverted: what rim accuracy would 0.1 beamwidths need?
            b.rimFor0p1Beamwidth_m = 0.05*lam;
            b.available = true;
        end

        function print(b, label)
            if nargin < 2; label = 'orientation'; end
            if ~isstruct(b) || ~isfield(b,'available') || ~b.available
                fprintf('  Orientation coherence budget: unavailable\n'); return
            end
            fprintf('  Orientation coherence budget (%s, from %s):\n', label, b.rotationSigmaSource);
            fprintf('    sigma_theta %.5f deg | R_rms %.1f m | lever %.1f m -> rim %.4f m\n', ...
                b.rotationErr_deg, b.formationRrms_m, b.rotationLever_m, b.rimDisplacement_m);
            fprintf('    coherent (lambda/20) up to %.0f MHz\n', b.coherentUpTo_Hz/1e6);
            for i = 1:numel(b.frequencies_Hz)
                fprintf('    %6.0f MHz  loss %7.2f dB | mispointing %8.2f beamwidths | need rim <= %.4f m for 0.1 bw\n', ...
                    b.frequencies_Hz(i)/1e6, b.gainLoss_dB(i), b.mispointBeamwidths(i), ...
                    b.rimFor0p1Beamwidth_m(i));
            end
            if isfinite(b.unappliedRotation_deg)
                fprintf('    NOTE %.5f deg of estimated rotation was NOT applied and remains in the geometry.\n', ...
                    b.unappliedRotation_deg);
            end
        end
    end

    methods (Static, Access = private)

        function b = empty_()
            b = struct('available', false, 'frequencies_Hz', [], 'formationRrms_m', NaN, ...
                'rotationLever_m', NaN, 'rotationErr_deg', NaN, 'rimDisplacement_m', NaN, ...
                'phaseSigma_rad', [], 'gainLoss_dB', [], 'mispointBeamwidths', [], ...
                'beamwidth_rad', [], 'groundOffset_m', NaN, 'coherentUpTo_Hz', NaN, ...
                'rimFor0p1Beamwidth_m', [], 'rotationSigmaSource', 'unavailable', ...
                'unappliedRotation_deg', NaN, 'nAssets', NaN);
        end

        function v = get_(s, path)
            v = []; c = s;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            v = c;
        end

        function n = vecnorm_(v)
            n = NaN;
            if isnumeric(v) && ~isempty(v) && all(isfinite(v(:))); n = norm(double(v(:))); end
        end

        function v = num_(s, path, dflt)
            v = dflt; c = s;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (isnumeric(c) || islogical(c)); v = double(c); end
        end
    end
end
