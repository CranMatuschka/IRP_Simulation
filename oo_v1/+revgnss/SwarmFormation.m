classdef SwarmFormation
    % SwarmFormation  Physically-real helix swarm truth for represented secondaries.
    %
    % When cfg.scenario.nSpaceAssets > 1 the secondary assets (indices 2..N) are
    % placed on a bounded Clohessy-Wiltshire (Hill) projected-circular relative
    % orbit around the primary chief (asset 1) and propagated with the SAME orbit
    % dynamics as the primary. The along-track / cross-track projection is a circle
    % of radius = cfg.formation.baseline_m, so in 3-D each secondary traces a helix
    % whose separation from the chief stays in [baseline, 1.118*baseline] (bounded,
    % never below the configured minimum). Only the primary is EKF-estimated;
    % these trajectories are represented-only truth that can feed ISL aiding.
    %
    % Frame convention (Hill, from the chief ECI state r_c, v_c):
    %   R = r_c/|r_c| (radial), W = (r_c x v_c)/|r_c x v_c| (cross-track/normal),
    %   S = W x R (along-track). Hill state [x=radial; y=along-track; z=cross-track].
    %
    % Bounded projected-circular (helix) solution, amplitude rho = baseline:
    %   x(t) = (rho/2) sin(nt+phi),  y(t) = rho cos(nt+phi),  z(t) = rho sin(nt+phi)
    % which satisfies the CW no-drift condition dy(0)/dt = -2 n x(0).

    methods (Static)
        function n = nSecondaries(cfg)
            % nSecondaries  Number of represented-only secondary assets (>=0).
            n = 0;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                n = max(0, round(cfg.scenario.nSpaceAssets) - 1);
            end
        end

        function tf = isActive(cfg)
            % isActive  True when a helix swarm truth should be generated.
            tf = revgnss.SwarmFormation.nSecondaries(cfg) >= 1 && ...
                 isfield(cfg,'orbit') && isfield(cfg.orbit,'useOrbitPropagator') && ...
                 cfg.orbit.useOrbitPropagator;
        end

        function [dr_hill, dv_hill] = helixOffsetHill(baseline_m, meanMotion_radps, phase_rad)
            % helixOffsetHill  Hill-frame relative position [m] and velocity [m/s]
            % (in the rotating frame) at t=0 for one projected-circular member.
            rho = baseline_m; n = meanMotion_radps; ph = phase_rad;
            dr_hill = [ (rho/2)*sin(ph);   rho*cos(ph);   rho*sin(ph) ];
            dv_hill = [ (rho/2)*n*cos(ph); -rho*n*sin(ph); rho*n*cos(ph) ];
        end

        function [rCells, vCells, meta] = buildSecondaryCaches(cfg, orbitProp, tVec, primaryR_ecef)
            % buildSecondaryCaches  ECEF truth trajectories for assets 2..N.
            %   rCells{i}, vCells{i} : [3 x nEpochs] ECEF r/v for secondary i (asset i+1)
            %   meta                 : formation geometry summary (baseline, min/max sep)
            nSec = revgnss.SwarmFormation.nSecondaries(cfg);
            rCells = {}; vCells = {};
            meta = struct('active', false, 'mode', 'none', 'nSecondaries', nSec, ...
                'baseline_m', NaN, 'minSeparation_m', NaN, 'maxSeparation_m', NaN, ...
                'perAssetMinSep_m', [], 'perAssetMaxSep_m', []);
            if nSec < 1 || isempty(orbitProp); return; end

            baseline = 1000.0; phase0 = 0.0; mode = 'helix';
            if isfield(cfg,'formation')
                if isfield(cfg.formation,'baseline_m'); baseline = cfg.formation.baseline_m; end
                if isfield(cfg.formation,'phase0_rad'); phase0 = cfg.formation.phase0_rad; end
                if isfield(cfg.formation,'mode');       mode   = cfg.formation.mode;       end
            end
            if ~strcmpi(mode, 'helix')
                error('SwarmFormation:unsupportedMode', ...
                    'cfg.formation.mode="%s" is not supported (only "helix").', mode);
            end
            if baseline < 500
                warning('SwarmFormation:smallBaseline', ...
                    'cfg.formation.baseline_m=%.1f m is below the 500 m minimum separation target.', baseline);
            end

            [r_c, v_c] = orbitProp.initialEciState();
            nMean = orbitProp.meanMotion();

            % Hill frame axes at t=0
            Rhat = r_c / norm(r_c);
            What = cross(r_c, v_c); What = What / norm(What);
            Shat = cross(What, Rhat);
            A = [Rhat, Shat, What];         % Hill -> ECI rotation (columns R,S,W)
            omega = [0; 0; nMean];          % Hill-frame angular velocity (about W)

            nEp = numel(tVec);
            rCells = cell(1, nSec); vCells = cell(1, nSec);
            perMin = nan(1, nSec); perMax = nan(1, nSec);
            for i = 1:nSec
                phase = phase0 + 2*pi*(i-1)/nSec;    % distribute members around the ring
                [dr_h, dv_h] = revgnss.SwarmFormation.helixOffsetHill(baseline, nMean, phase);
                dr_eci = A * dr_h;
                dv_eci = A * (dv_h + cross(omega, dr_h));   % rotating -> inertial relative velocity
                r0 = r_c + dr_eci;
                v0 = v_c + dv_eci;
                [rE, vE] = orbitProp.propagateFromEciState(r0, v0, tVec);
                rCells{i} = rE; vCells{i} = vE;
                if nargin >= 4 && ~isempty(primaryR_ecef) && size(primaryR_ecef,2) == nEp
                    sep = vecnorm(rE - primaryR_ecef, 2, 1);
                    perMin(i) = min(sep); perMax(i) = max(sep);
                end
            end

            meta.active = true; meta.mode = 'helix'; meta.baseline_m = baseline;
            meta.perAssetMinSep_m = perMin; meta.perAssetMaxSep_m = perMax;
            if any(~isnan(perMin))
                meta.minSeparation_m = min(perMin(~isnan(perMin)));
                meta.maxSeparation_m = max(perMax(~isnan(perMax)));
            end
        end
    end
end
