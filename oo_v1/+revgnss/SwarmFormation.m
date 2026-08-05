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

        function [rho, phase] = ringLayout_(cfg, memberIndex, nSec, baseline_m, phase0)
            % ringLayout_  Where member `memberIndex` sits: its ring RADIUS and its phase on it.
            %
            % WHY THIS EXISTS. The original layout put EVERY member on ONE ring of radius
            % baseline_m, evenly spaced in phase, so the chord between neighbours is
            % 2*rho*sin(pi/nSec) -- it SHRINKS as members are added. At nSec=5 that is 1176 m
            % (the intended ~1 km); at nSec=19 it collapses to 329 m. Measured consequence at
            % N=20: nearest-neighbour spacing 328 m instead of ~1000 m, which diluted the shape
            % solve by 27x (0.149 m -> 4.11 m) because a fixed range bias is a 3x larger ANGULAR
            % error on a 3x shorter baseline. cfg.formation.baseline_m is therefore the ring
            % RADIUS, not the inter-satellite separation its comment claims.
            %
            % 'multiRingHelix' instead holds the SEPARATION fixed and adds RINGS: ring k has
            % radius k*spacing and carries round(2*pi*k) members, so the along-ring chord and the
            % ring-to-ring step are both ~spacing. Members-per-ring 6, 13, 19, ... grows with
            % circumference exactly as it must for constant spacing.
            mode = 'helix';
            spacing = baseline_m;
            if isfield(cfg,'formation')
                if isfield(cfg.formation,'mode'); mode = char(cfg.formation.mode); end
                if isfield(cfg.formation,'spacing_m') && ~isempty(cfg.formation.spacing_m)
                    spacing = cfg.formation.spacing_m;
                end
            end
            if ~strcmpi(mode,'multiRingHelix')
                rho = baseline_m;
                phase = phase0 + 2*pi*(memberIndex-1)/nSec;
                return
            end
            % Fill rings outward until every member has a home.
            k = 1; placed = 0;
            while true
                nk = max(1, round(2*pi*k));            % members this ring holds at ~spacing chord
                if memberIndex <= placed + nk
                    idxInRing = memberIndex - placed;
                    rho = k * spacing;
                    % Stagger alternate rings by half a step so radial neighbours do not line up.
                    phase = phase0 + 2*pi*(idxInRing-1)/nk + mod(k,2)*pi/nk;
                    return
                end
                placed = placed + nk; k = k + 1;
                if k > 1000
                    error('SwarmFormation:ringLayout','Could not place member %d.', memberIndex);
                end
            end
        end

        function [dr_hill, dv_hill] = helixOffsetHill(baseline_m, meanMotion_radps, phase_rad, crossAmp)
            % helixOffsetHill  Hill-frame relative position [m] and velocity [m/s]
            % (in the rotating frame) at t=0 for one projected-circular member.
            %
            % crossAmp (default 1) scales ONLY the cross-track (z) amplitude. crossAmp=1 gives the
            % classic planar projected-circular helix: z = rho*sin = 2x, so ALL members lie in the
            % plane z=2x and the instantaneous formation is planar (out-of-plane shape only 2nd-order
            % observable from ranging). A per-member VARYING crossAmp makes z a per-member multiple of
            % x, so the formation spans 3-D -> the full shape is first-order observable. Each member
            % still flies a valid bounded CW relative orbit (in-plane 2:1 no-drift ellipse + an
            % independent bounded cross-track harmonic of amplitude crossAmp*rho).
            if nargin < 4 || isempty(crossAmp); crossAmp = 1.0; end
            rho = baseline_m; n = meanMotion_radps; ph = phase_rad;
            dr_hill = [ (rho/2)*sin(ph);   rho*cos(ph);   crossAmp*rho*sin(ph) ];
            dv_hill = [ (rho/2)*n*cos(ph); -rho*n*sin(ph); crossAmp*rho*n*cos(ph) ];
        end

        function ca = crossAmp_(cfg, i, nSec)
            % crossAmp_  Per-member cross-track amplitude scale from cfg.formation.crossTrackSpread
            % (default 0 -> ca=1 for every member -> the classic planar helix, byte-identical). A
            % spread s>0 fans the members linearly over [1-s, 1+s], giving distinct z:x ratios ->
            % a non-degenerate 3-D formation.
            s = 0;
            if isfield(cfg,'formation') && isfield(cfg.formation,'crossTrackSpread') && ...
                    isnumeric(cfg.formation.crossTrackSpread) && isscalar(cfg.formation.crossTrackSpread)
                s = cfg.formation.crossTrackSpread;
            end
            ca = 1 + s * (2*(i-1)/max(nSec-1,1) - 1);
        end

        function [r0Cells, v0Cells] = secondaryEciInitialStates(cfg, orbitProp)
            % secondaryEciInitialStates  Per-secondary t=0 ECI initial state [3x1] r0/v0 (the
            % helix ICs that buildSecondaryCaches then propagates). Extracted so the federated
            % instance layer can run each swarm member as its OWN single-asset absolute orbit by
            % injecting r0/v0 via cfg.orbit.eciState0. This is the SAME arithmetic as the IC
            % section of buildSecondaryCaches (kept in sync; that method is the truth path).
            nSec = revgnss.SwarmFormation.nSecondaries(cfg);
            r0Cells = cell(1, nSec); v0Cells = cell(1, nSec);
            if nSec < 1 || isempty(orbitProp); return; end

            baseline = 1000.0; phase0 = 0.0; mode = 'helix';
            if isfield(cfg,'formation')
                if isfield(cfg.formation,'baseline_m'); baseline = cfg.formation.baseline_m; end
                if isfield(cfg.formation,'phase0_rad'); phase0 = cfg.formation.phase0_rad; end
                if isfield(cfg.formation,'mode');       mode   = cfg.formation.mode;       end
            end
            if ~any(strcmpi(mode, {'helix','multiRingHelix'}))
                error('SwarmFormation:unsupportedMode', ...
                    ['cfg.formation.mode="%s" is not supported ' ...
                     '(only "helix" or "multiRingHelix").'], mode);
            end

            [r_c, v_c] = orbitProp.initialEciState();
            nMean = orbitProp.meanMotion();
            Rhat = r_c / norm(r_c);
            What = cross(r_c, v_c); What = What / norm(What);
            Shat = cross(What, Rhat);
            A = [Rhat, Shat, What];         % Hill -> ECI rotation (columns R,S,W)
            omega = [0; 0; nMean];          % Hill-frame angular velocity (about W)
            for i = 1:nSec
                [rhoI, phase] = revgnss.SwarmFormation.ringLayout_(cfg, i, nSec, baseline, phase0);
                ca = revgnss.SwarmFormation.crossAmp_(cfg, i, nSec);
                [dr_h, dv_h] = revgnss.SwarmFormation.helixOffsetHill(rhoI, nMean, phase, ca);
                dr_eci = A * dr_h;
                dv_eci = A * (dv_h + cross(omega, dr_h));   % rotating -> inertial relative velocity
                r0Cells{i} = r_c + dr_eci;
                v0Cells{i} = v_c + dv_eci;
            end
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
            if ~any(strcmpi(mode, {'helix','multiRingHelix'}))
                error('SwarmFormation:unsupportedMode', ...
                    ['cfg.formation.mode="%s" is not supported ' ...
                     '(only "helix" or "multiRingHelix").'], mode);
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
                [rhoI, phase] = revgnss.SwarmFormation.ringLayout_(cfg, i, nSec, baseline, phase0);
                ca = revgnss.SwarmFormation.crossAmp_(cfg, i, nSec);
                [dr_h, dv_h] = revgnss.SwarmFormation.helixOffsetHill(rhoI, nMean, phase, ca);
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
