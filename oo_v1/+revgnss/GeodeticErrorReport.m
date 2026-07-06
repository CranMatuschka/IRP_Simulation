classdef GeodeticErrorReport
    % GeodeticErrorReport  Presentation-only geodetic position-error report for the
    % primary (estimated) asset. The filter state stays ECEF Cartesian; this rotates
    % the ECEF position error and covariance into local East/North/Up at the truth
    % sub-point so the three components are directly comparable in metres.
    %
    % Vertical dominance: for a space asset viewed from beacons BELOW it all
    % lines-of-sight lie in an upward cone (VDOP >> HDOP), so the Up (height) error
    % dominates the ground-only solution. One-way ISL from swarm-mates supplies
    % non-vertical geometry and collapses that Up error — the vertHorizRatio field
    % quantifies exactly that.
    %
    % Metricised local error (arc-length, equal to the ENU error to first order):
    %   dE = R_ENU(E,:) * (r_est - r_truth), etc. with R_ENU from the truth lat/lon.

    methods (Static)
        function s = fromSim(sim)
            % fromSim  Build the geodetic error report from a finished simulation.
            d = sim.simData;
            errVec = d.getPositionErrorVecs();          % [3 x N] est - truth, ECEF [m]
            N = size(errVec, 2);
            if isprop(sim,'orbitTruthCache') && isfield(sim.orbitTruthCache,'r_ecef_m') && ...
                    ~isempty(sim.orbitTruthCache.r_ecef_m)
                truth = sim.orbitTruthCache.r_ecef_m(:, 1:N);
            else
                truth = repmat(sim.asset.r_ecef_m(:), 1, N);
            end
            Ppos = sim.ekf.P(sim.ekf.stateMap.r_idx, sim.ekf.stateMap.r_idx);   % final 3x3 ECEF pos cov
            s = revgnss.GeodeticErrorReport.compute(truth, errVec, Ppos);
        end

        function s = compute(truthEcef, errVecEcef, Ppos_ecef)
            % compute  N/E/U error, RMS, 3-sigma envelope and vertical-dominance ratio.
            N = size(errVecEcef, 2);
            dENU = zeros(3, N);          % rows East, North, Up [m]
            for k = 1:N
                [lat, lon, ~] = models.frames.GeometryUtils.ecef2geodetic(truthEcef(:,k));
                Renu = models.frames.GeometryUtils.enu2ecef(lat, lon)';   % ECEF->ENU
                dENU(:,k) = Renu * errVecEcef(:,k);
            end
            iS = max(1, N - round(0.2*N) + 1);
            rmsFn = @(x) sqrt(mean(x.^2));
            s.dEast = dENU(1,:); s.dNorth = dENU(2,:); s.dUp = dENU(3,:);
            s.rmsE_m = rmsFn(dENU(1,iS:end));
            s.rmsN_m = rmsFn(dENU(2,iS:end));
            s.rmsU_m = rmsFn(dENU(3,iS:end));
            s.p95U_m = prctile(abs(dENU(3,iS:end)), 95);
            s.rmsHoriz_m = hypot(s.rmsE_m, s.rmsN_m);
            s.vertHorizRatio = s.rmsU_m / max(s.rmsHoriz_m, eps);
            % 3-sigma envelope from the ENU-rotated final covariance (at the last truth point)
            [lat, lon, ~] = models.frames.GeometryUtils.ecef2geodetic(truthEcef(:,end));
            Renu = models.frames.GeometryUtils.enu2ecef(lat, lon)';
            Penu = Renu * Ppos_ecef * Renu';
            sig = sqrt(max(diag(Penu), 0));
            s.sig3E_m = 3*sig(1); s.sig3N_m = 3*sig(2); s.sig3U_m = 3*sig(3);
            % Covariance-based dilution indicators (VDOP-like >> HDOP-like when
            % geometry is vertical-starved): ratio of Up to horizontal 1-sigma.
            s.vdopLike = sig(3); s.hdopLike = hypot(sig(1), sig(2));
        end

        function printSummary(s, fid)
            if nargin < 2; fid = 1; end
            fprintf(fid, 'GEODETIC (primary asset, local ENU) last-20%% RMS:\n');
            fprintf(fid, '  East  = %8.4f m   North = %8.4f m   Up(height) = %8.4f m  (p95 %.4f m)\n', ...
                s.rmsE_m, s.rmsN_m, s.rmsU_m, s.p95U_m);
            fprintf(fid, '  horizontal RMS = %.4f m ; vertical/horizontal ratio = %.2f\n', ...
                s.rmsHoriz_m, s.vertHorizRatio);
            fprintf(fid, '  final 3-sigma envelope: E=%.4f N=%.4f U=%.4f m\n', ...
                s.sig3E_m, s.sig3N_m, s.sig3U_m);
        end
    end
end
