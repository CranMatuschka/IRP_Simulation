classdef ConsiderCovariance
    %CONSIDERCOVARIANCE  Linear consider ("Schmidt") covariance for parameters the
    %   filter does NOT estimate.
    %
    %   WHY THIS EXISTS. The EKF's P accounts for measurement noise and geometry only:
    %   P^-1 = P0^-1 + sum H' R^-1 H. It cannot account for an error source that is
    %   absent from the measurement model, because such a source leaves no trace in the
    %   innovation -- the state absorbs it and the residuals go to zero at the wrong
    %   state. The formal sigma is then a true statement about PRECISION and a false
    %   statement about ACCURACY. A consider covariance restores the missing term.
    %
    %   WHEN IT IS THE RIGHT TOOL. Only for parameters that genuinely cannot be
    %   estimated. If a parameter IS estimable, estimating it is strictly better: it
    %   REMOVES the error instead of merely widening the error bars. Consider covariance
    %   is a last resort, and using it on an estimable parameter is a way of excusing an
    %   avoidable error.
    %
    %   Worked example -- the common-mode code DCB in this repo:
    %   cfg.biases.interFrequency.code.truth.{L1_m,L2_m} injects ONE scalar per signal,
    %   applied identically to every tower (CodeMeasurementBuilder.oneCodeDcb_), with no
    %   model counterpart. cfg.hardware.txCodeBias estimates PER-TOWER biases with a
    %   reference-tower gauge, so it spans only tower-to-tower DIFFERENCES -- of which a
    %   common-mode bias has none. The bias is therefore NOT estimable with the existing
    %   state set, which is exactly the situation a consider parameter is for.
    %
    %   METHOD. For a consider parameter c entering the truth but not the model, the
    %   converged estimate responds linearly for small c:
    %       S = d(xhat)/dc          [nx x 1] sensitivity
    %       P_consider = P_filter + S * sigma_c^2 * S'
    %   S is obtained here by FINITE-DIFFERENCING THE WHOLE ESTIMATOR across two runs
    %   that differ only in c. That is exact for the linear response and needs no
    %   analytic derivation, at the cost of one extra simulation.
    %
    %   INTERPRETING sigma_c. sigma_c is your prior 1-sigma on the parameter, and it must
    %   come from outside this run -- a published DCB uncertainty, a calibration spec.
    %   Setting sigma_c equal to the value you injected makes the run a 1-sigma
    %   realisation, so the band covers it almost by construction; that demonstrates the
    %   mechanism but is NOT independent evidence of covariance realism. State which you
    %   are doing.
    %
    %   The band stays CENTRED ON ZERO. A consider term says "a bias of unknown sign
    %   exists at this magnitude", so it widens the band symmetrically. It never shifts
    %   it: a bias whose value were known would simply be subtracted.
    %
    %   See also: revgnss.OrbitFrame, revgnss.ClockExactReportBuilder

    methods (Static)

        function S = positionSensitivity(diagWith, diagWithout)
            %POSITIONSENSITIVITY  [3 x N] d(rhat)/dc from two runs differing only in c.
            %   diagWith    diagnostics from the run WITH the parameter active
            %   diagWithout diagnostics from the run with the parameter zeroed
            %   S is per unit of the parameter as configured in the "with" run, i.e.
            %   sigma_c is then expressed in multiples of that nominal value.
            eWith    = diagWith.getPositionErrorVecs();
            eWithout = diagWithout.getPositionErrorVecs();
            n = min(size(eWith,2), size(eWithout,2));
            % Truth is identical across the two runs, so differencing the ERRORS gives
            % the difference of the ESTIMATES with the truth term cancelling exactly.
            S = eWith(:,1:n) - eWithout(:,1:n);
        end

        function [sigRac, sigRacFilter] = racSigma(diag, S, sigma_c, rTruth, vTruth)
            %RACSIGMA  [3 x N] consider-augmented RAC 1-sigma, and the filter-only value.
            %   sigma_axis^2 = u' P_pos u  +  (u' S)^2 * sigma_c^2
            %   with u the RAC basis vector and P_pos the FULL 3x3 position block
            %   (diagonal-only fallback when PposOffDiag_m2 is absent, as elsewhere).
            P = diag.getPdiag();
            d = diag.getData();
            Xoff = [];
            if isfield(d,'PposOffDiag_m2'); Xoff = d.PposOffDiag_m2; end
            n = min([size(P,2), size(S,2), size(rTruth,2), size(vTruth,2)]);
            w = 7.2921150e-5;
            try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
            om = [0;0;w];
            sigRac       = nan(3,n);
            sigRacFilter = nan(3,n);
            for k = 1:n
                rk = rTruth(:,k);
                [rH,aH,hH,ok] = revgnss.OrbitFrame.racBasis(rk, vTruth(:,k) + cross(om,rk));
                if ~ok; continue; end
                pv = max(P(1:3,k), 0);
                if ~isempty(Xoff) && k <= size(Xoff,2) && all(isfinite(Xoff(:,k)))
                    xo = Xoff(:,k);
                    Ppos = [pv(1) xo(1) xo(2); xo(1) pv(2) xo(3); xo(2) xo(3) pv(3)];
                else
                    Ppos = diag2_(pv);
                end
                B = [rH, aH, hH];
                for a = 1:3
                    u = B(:,a);
                    vFilter = u' * Ppos * u;
                    vConsid = (u' * S(:,k))^2 * sigma_c^2;
                    sigRacFilter(a,k) = sqrt(max(vFilter, 0));
                    sigRac(a,k)       = sqrt(max(vFilter + vConsid, 0));
                end
            end
        end

    end
end

function M = diag2_(v)
% Local helper: MATLAB's diag() is shadowed by the 'diag' diagnostics argument name
% used throughout this file's callers, so build the matrix explicitly.
M = [v(1) 0 0; 0 v(2) 0; 0 0 v(3)];
end
