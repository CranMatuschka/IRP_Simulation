classdef TruthEndpointReplay < handle
    % TruthEndpointReplay  Replays one spacecraft's stored TRUTH state as the minimal object
    % revgnss.ReciprocalEndpointTruthProvider.spacecraft needs, so a post-processor that owns only
    % recorded trajectories can drive the real four-timestamp physics chain.
    %
    % WHY THIS EXISTS. revgnss.SwarmRelativeSolver runs AFTER the federated fleet, as a read-only
    % post-processor: it holds each asset's recorded truth trajectory, never a live
    % revgnss.SpaceAsset with a stepping clock. The four-timestamp chain
    % (revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl ->
    % revgnss.ReciprocalEndpointTruthProvider.spacecraft) reads exactly five things from whatever
    % it is handed -- r_ecef_m, v_ecef_mps, attitude_euler_rad, clock.getBiasMeters() and
    % clock.getDriftMetersPerSecond(). This class supplies those five from stored arrays and
    % nothing more, so the solver can use the REAL physics instead of a synthetic observable
    % without either duplicating the light-time solve or re-running the simulation.
    %
    % NOT A SpaceAsset. Deliberately minimal and duck-typed: no propagation, no stepping, no
    % measurement generation. seek(k) moves it to a recorded epoch; every property then reads that
    % epoch. If a caller needs anything beyond the five fields above it will fail loudly rather
    % than silently receive a default, which is the intent.
    %
    % ATTITUDE IS REQUIRED, NOT OPTIONAL. The ISL transmit/receive phase-centre offsets default to
    % [0.8;0.2;0.3] m, so the body-to-inertial rotation places the antenna up to ~0.9 m from the
    % centre of mass. Replaying with an assumed attitude would inject that as a per-endpoint
    % geometry error, which is why revgnss.ReportRunner records the truth attitude history and
    % why isUsable rejects a payload that lacks it.

    properties
        r_ecef_m (3,1) double = [0;0;0]
        v_ecef_mps (3,1) double = [0;0;0]
        attitude_euler_rad (3,1) double = [0;0;0]
        clock                                   % duck-typed clock with the two accessors used
    end

    properties (Access = private)
        pos_ (3,:) double = zeros(3,0)
        vel_ (3,:) double = zeros(3,0)
        att_ (3,:) double = zeros(3,0)
        bias_m_ (1,:) double = zeros(1,0)
        drift_mps_ (1,:) double = zeros(1,0)
        nEpoch_ (1,1) double = 0
    end

    methods (Static)
        function tf = isUsable(assetResult, nEpoch)
            % isUsable  True when the stored payload can drive the four-timestamp chain.
            % Every field is REQUIRED; there is no partial mode, because a missing attitude or
            % drift would otherwise be silently defaulted into the physics.
            %
            % The CLOCK series is exempt from the length test on purpose: models.clocks.ClockModel
            % records its history one sample SHORT of the state grid (3600 vs 3601 for a 3600 s
            % run, because the first sample is written after the first step), so a plain
            % numel >= nEpoch test rejects every real run. The constructor interpolates the clock
            % onto the state time grid instead -- the same interp1 the surrounding solver already
            % applies to truthClkTraj_m. Only a non-empty series with a matching time vector is
            % required here.
            tf = isempty(revgnss.TruthEndpointReplay.unusableReason(assetResult, nEpoch));
        end

        function reason = unusableReason(assetResult, nEpoch)
            % unusableReason  Which specific field blocks the replay (for honest reporting).
            reason = '';
            if ~isstruct(assetResult); reason = 'assetResultNotStruct'; return; end
            need = {'truthTraj','truthVelTraj','truthAttTraj_rad','truthClkTraj_m', ...
                    'truthClkDriftTraj_mps','truthClkTime_s'};
            for i = 1:numel(need)
                if ~isfield(assetResult,need{i}) || isempty(assetResult.(need{i}))
                    reason = ['missing:' need{i}]; return
                end
            end
            % State-grid series must cover every epoch; the clock series need only be
            % interpolatable onto it (see isUsable).
            if size(assetResult.truthTraj,2) < nEpoch
                reason = 'shortSeries:truthTraj'; return
            end
            if size(assetResult.truthVelTraj,2) < nEpoch
                reason = 'shortSeries:truthVelTraj'; return
            end
            if size(assetResult.truthAttTraj_rad,2) < nEpoch
                reason = 'shortSeries:truthAttTraj_rad'; return
            end
            if numel(assetResult.truthClkTime_s) ~= numel(assetResult.truthClkTraj_m)
                reason = 'clockTimeSeriesLengthMismatch'; return
            end
            if numel(assetResult.truthClkDriftTraj_mps) < 2
                reason = 'shortSeries:truthClkDriftTraj_mps'; return
            end
        end
    end

    methods
        function obj = TruthEndpointReplay(assetResult, nEpoch, timeGrid_s)
            % timeGrid_s is the solver's epoch grid (1 x nEpoch). The clock bias is recorded on
            % its OWN grid, one sample shorter than the state grid, so it is interpolated onto
            % timeGrid_s exactly as the surrounding solver does for truthClkTraj_m. Drift is
            % recorded on the state grid and is only trimmed.
            n = nEpoch;
            obj.pos_ = assetResult.truthTraj(:,1:n);
            obj.vel_ = assetResult.truthVelTraj(:,1:n);
            obj.att_ = assetResult.truthAttTraj_rad(:,1:n);

            tg = timeGrid_s(:).';
            if numel(tg) ~= n
                error('TruthEndpointReplay:timeGrid', ...
                    'timeGrid_s must have %d samples, got %d.', n, numel(tg));
            end
            obj.bias_m_ = interp1(assetResult.truthClkTime_s(:).', ...
                assetResult.truthClkTraj_m(:).', tg, 'linear', 'extrap');

            d = assetResult.truthClkDriftTraj_mps(:).';
            if numel(d) >= n
                obj.drift_mps_ = d(1:n);
            else
                dt = assetResult.truthStateTime_s(:).';
                obj.drift_mps_ = interp1(dt(1:numel(d)), d, tg, 'linear', 'extrap');
            end

            obj.nEpoch_ = n;
            obj.clock   = revgnss.TruthEndpointReplayClock();
            obj.seek(1);
        end

        function seek(obj, k)
            % seek  Point every accessor at recorded epoch k.
            if ~(k >= 1 && k <= obj.nEpoch_)
                error('TruthEndpointReplay:epochOutOfRange', ...
                    'Epoch %d is outside the recorded range 1..%d.', k, obj.nEpoch_);
            end
            obj.r_ecef_m           = obj.pos_(:,k);
            obj.v_ecef_mps         = obj.vel_(:,k);
            obj.attitude_euler_rad = obj.att_(:,k);
            obj.clock.setState(obj.bias_m_(k), obj.drift_mps_(k));
        end
    end
end
