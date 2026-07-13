classdef ClockModel < handle
    % ClockModel  Oscillator clock model for reverse-GNSS simulation.
    %
    % Models a physical oscillator with five power-law noise types based on
    % the one-sided PSD of fractional frequency fluctuations:
    %
    %   S_y(f) = h2*f^2 + h1*f + h0 + hMinus1/f + hMinus2/f^2
    %
    %   h2       white phase modulation (WPM)
    %   h1       flicker phase modulation (FPM)
    %   h0       white frequency modulation (WFM)
    %   hMinus1  flicker frequency modulation (FFM)
    %   hMinus2  random-walk frequency modulation (RWFM)
    %
    % Allan deviation slopes by noise type:
    %   WPM:   sigma_y(tau) ~ tau^(-1)
    %   FPM:   sigma_y(tau) ~ tau^(-1)   (different coefficient)
    %   WFM:   sigma_y(tau) ~ tau^(-1/2)
    %   FFM:   sigma_y(tau) ~ tau^0      (floor)
    %   RWFM:  sigma_y(tau) ~ tau^(+1/2)
    %
    % -----------------------------------------------------------------------
    % CLOCK STATE DECOMPOSITION (two components)
    %
    % 1) WFM + RWFM STATE  [bias_s, fracFreq]:
    %      - WFM (h0):    direct phase noise each step.
    %                     Phase variance per interval dt = h0/2 * dt.
    %                     Modeled as independent Gaussian kick to bias.
    %                     NOT accumulated into fracFreq (avoids tau^+1/2 growth of WFM).
    %      - RWFM (hm2):  random walk in fractional frequency.
    %                     Freq variance per interval dt = 2*pi^2*hm2 * dt.
    %      This component is used in the EKF state vector.
    %
    % 2) COLORED COMPONENT  [coloredBias_s_current, coloredFracFreq_current]:
    %      - WPM (h2), FPM (h1), FFM (hm1) are synthesised by FFT spectral
    %        shaping over the full simulation span (precomputeNoise).
    %      - Stored as ABSOLUTE sequences; updated per step by reading the
    %        current epoch value from the precomputed array.
    %      - Not accumulated into the state; returned only via accessors.
    %
    % Total output (returned by public accessors):
    %   bias_total   = bias_s     + coloredBias_s_current
    %   frac_total   = fracFreq   + coloredFracFreq_current
    %
    % State-only accessors (for EKF internal use):
    %   getStateBiasSeconds()  -> bias_s   (WFM+RWFM only)
    %   getStateFracFreq()     -> fracFreq (RWFM only)
    %
    % -----------------------------------------------------------------------
    % EKF PROCESS NOISE  (getProcessNoiseQ)
    %
    % Standard Brown-Hwang 2-state model for WFM + RWFM:
    %   Q_11 = (h0/2 + 2*ln(2)*hm1) * dt + 2/3*pi^2*hm2*dt^3
    %   Q_12 = Q_21 = pi^2*hm2 * dt^2
    %   Q_22 = 2*pi^2*hm2 * dt
    %
    % The conservative additive 2*ln(2)*hm1*dt term in Q_11 is an approximation
    % for FFM (hMinus1).  It slightly inflates phase variance to prevent the EKF
    % from being over-confident when FFM is present.
    %
    % WPM (h2) and FPM (h1) are in the truth synthesis only; they are NOT
    % in the 2-state EKF Q because they act on timescales shorter than dt.
    %
    % -----------------------------------------------------------------------
    % Usage:
    %   cfg = revgnss.ConfigFactory.makeClockConfig('OCXO', 42, struct(), struct());
    %   clk = models.clocks.ClockModel(cfg);
    %   clk.precomputeNoise(0:1:3600);
    %   clk.step(1.0);
    %   b_m = clk.getBiasMeters();   % total bias

    properties
        name            (1,:) char    = 'unnamed'
        clockType       (1,:) char    = 'generic'

        % Internal WFM+RWFM state (corresponds to EKF state variables)
        bias_s          (1,1) double  = 0   % WFM+RWFM clock time bias [s]
        fracFreq        (1,1) double  = 0   % RWFM fractional frequency error [-]
        driftRate_fracPerSec (1,1) double = 0  % deterministic frequency drift [1/s^2]

        % Noise configuration
        noiseCoeffs     (1,1) struct        % h2, h1, h0, hMinus1, hMinus2
        deterministic   (1,1) logical = false  % if true, no stochastic noise
        driftFlickerInQ (1,1) logical = false  % opt-in: inject flicker-FM into the drift (freq) Q22
                                               % (A/B showed it inflates Q22 ~26x but leaves the
                                               %  actual/sigma ratio unchanged -> not the consistency fix)
        seed            (1,1) double  = 42
        lastTime_s      (1,1) double  = 0

        % History: stores TOTAL (state + colored) for ADEV computation
        history         (1,1) struct

        % Per-instance RNG stream (reproducible, independent of global state)
        rngStream                          % RandStream object

        % Pre-computed colored-noise absolute sequences
        noiseBias_s_vec     (:,1) double = []  % absolute colored bias [s] at each epoch
        noiseFracFreq_vec   (:,1) double = []  % absolute colored frac-freq [-] at each epoch
        noiseTimeVec_s      (:,1) double = []
        sampleIndex         (1,1) double = 1   % pointer into precomputed arrays

        % Current colored component (updated each step; added by accessors)
        coloredBias_s_current    (1,1) double = 0
        coloredFracFreq_current  (1,1) double = 0
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = ClockModel(cfg)
            % ClockModel  Constructor.
            if nargin == 0; return; end

            obj.name      = cfg.name;
            obj.clockType = cfg.clockType;

            obj.noiseCoeffs = struct('h2',0,'h1',0,'h0',0,'hMinus1',0,'hMinus2',0);
            fn = fieldnames(cfg.noiseCoeffs);
            for k = 1:numel(fn)
                obj.noiseCoeffs.(fn{k}) = cfg.noiseCoeffs.(fn{k});
            end

            if isfield(cfg,'deterministic');         obj.deterministic        = cfg.deterministic;        end
            if isfield(cfg,'driftFlickerInQ');       obj.driftFlickerInQ      = logical(cfg.driftFlickerInQ); end
            if isfield(cfg,'seed');                  obj.seed                 = cfg.seed;                 end
            if isfield(cfg,'bias_s');                obj.bias_s               = cfg.bias_s;               end
            if isfield(cfg,'fracFreq');              obj.fracFreq             = cfg.fracFreq;             end
            if isfield(cfg,'driftRate_fracPerSec'); obj.driftRate_fracPerSec = cfg.driftRate_fracPerSec; end

            % Dedicated RNG stream — independent of global rand state
            obj.rngStream = RandStream('mt19937ar', 'Seed', obj.seed);

            obj.history.time_s   = [];
            obj.history.bias_s   = [];
            obj.history.fracFreq = [];
        end

        % -------------------------------------------------------------- %
        function reset(obj, seed)
            % reset  Reset state, colored components, history, and RNG stream.
            if nargin > 1; obj.seed = seed; end
            obj.bias_s                   = 0;
            obj.fracFreq                 = 0;
            obj.lastTime_s               = 0;
            obj.sampleIndex              = 1;
            obj.coloredBias_s_current    = 0;
            obj.coloredFracFreq_current  = 0;
            obj.history.time_s           = [];
            obj.history.bias_s           = [];
            obj.history.fracFreq         = [];
            obj.noiseBias_s_vec          = [];
            obj.noiseFracFreq_vec        = [];
            % Reinitialise stream from seed so the sequence is reproducible
            obj.rngStream = RandStream('mt19937ar', 'Seed', obj.seed);
        end

        % -------------------------------------------------------------- %
        function precomputeNoise(obj, tVec_s)
            % precomputeNoise  Synthesise WPM / FPM / FFM colored-noise sequences.
            %
            % Generates absolute-valued time series for the colored components
            % (WPM h2, FPM h1, FFM hm1) using FFT spectral synthesis.
            % WFM (h0) and RWFM (hm2) are handled directly in step().
            %
            % The resulting noiseBias_s_vec(k) is the ABSOLUTE colored bias at
            % epoch k.  In step(), we read the absolute value at the current epoch
            % (not an increment), so the state is never contaminated by cumulative
            % summation of absolute colored values.

            obj.noiseTimeVec_s          = tVec_s(:);
            N                           = numel(tVec_s);
            dt                          = mean(diff(tVec_s));
            if dt <= 0
                error('ClockModel:precomputeNoise','tVec_s must be strictly increasing');
            end
            obj.sampleIndex             = 1;
            obj.coloredBias_s_current   = 0;
            obj.coloredFracFreq_current = 0;

            if obj.deterministic
                obj.noiseBias_s_vec   = zeros(N,1);
                obj.noiseFracFreq_vec = zeros(N,1);
                return
            end

            % Use per-instance stream — never touches global rng state
            % Reset stream so precomputeNoise is reproducible regardless of
            % how many step() calls have already consumed random numbers.
            reset(obj.rngStream, obj.seed);

            % Frequency axis (positive, DC excluded)
            fs    = 1 / dt;
            f_pos = (0:N-1)' * (fs/N);
            f_pos(1) = f_pos(2);   % avoid division by zero at DC

            h = obj.noiseCoeffs;

            % Colored fractional-frequency PSD (WPM, FPM, FFM only)
            Sy_frac = h.h2 * f_pos.^2 + h.h1 * f_pos + h.hMinus1 ./ f_pos;

            % Amplitude spectrum
            A_frac     = sqrt(max(Sy_frac, 0) * fs / N);

            % Random complex spectrum → Hermitian symmetry → real IFFT
            WN_frac    = randn(obj.rngStream, N, 1) + 1i*randn(obj.rngStream, N, 1);
            X_frac     = A_frac .* WN_frac;
            X_frac_sym = makeHermitian_(X_frac, N);
            y_frac_col = real(ifft(X_frac_sym));

            % Integrate frac-freq colored noise → phase (bias) colored noise
            % cumtrapz gives ABSOLUTE phase sequence, starting at 0.
            x_bias_col = cumtrapz(tVec_s, y_frac_col);

            obj.noiseBias_s_vec   = x_bias_col;
            obj.noiseFracFreq_vec = y_frac_col;
        end

        % -------------------------------------------------------------- %
        function step(obj, dt_s)
            % step  Propagate clock state by dt_s seconds.
            %
            % WFM (h0):
            %   Modeled as an independent Gaussian phase jump each step.
            %   Phase noise std = sqrt(h0 * dt / 2)  [s].
            %   Added directly to bias_s, NOT to fracFreq.
            %   This gives the correct ADEV slope tau^(-1/2) for WFM.
            %
            % RWFM (hMinus2):
            %   Gaussian frequency increment each step.
            %   Freq-noise std = sqrt(2*pi^2*hm2 * dt)  [-].
            %   Added to fracFreq (persistent random walk).
            %
            % Colored component (WPM, FPM, FFM):
            %   Read as ABSOLUTE value from precomputed sequence at the
            %   current epoch.  Returned via getBiasSeconds() etc. but
            %   NOT stored in bias_s / fracFreq.
            %
            % History records TOTAL = state + colored.

            if nargin < 2 || dt_s <= 0
                error('ClockModel:step','dt_s must be positive');
            end

            h = obj.noiseCoeffs;

            % WFM: direct phase noise — std = sqrt(h0 * dt / 2)
            sigma_wfm_bias_s = sqrt(h.h0 * dt_s / 2);

            % RWFM: fractional-frequency random walk — std = sqrt(2*pi^2*hm2 * dt)
            sigma_rwfm_frac  = sqrt(2 * pi^2 * h.hMinus2 * dt_s);

            if obj.deterministic
                n_bias_wfm   = 0;
                dn_freq_rwfm = 0;
            else
                n_bias_wfm   = randn(obj.rngStream) * sigma_wfm_bias_s;   % WFM phase jump [s]
                dn_freq_rwfm = randn(obj.rngStream) * sigma_rwfm_frac;    % RWFM freq increment [-]
            end

            % Deterministic frequency drift
            det_drift_frac = obj.driftRate_fracPerSec * dt_s;

            % Update colored component to the next epoch
            % Advance index first so we read the value at the END of this step.
            nextIdx = obj.sampleIndex + 1;
            if ~isempty(obj.noiseBias_s_vec) && nextIdx <= numel(obj.noiseBias_s_vec)
                obj.coloredBias_s_current   = obj.noiseBias_s_vec(nextIdx);
                obj.coloredFracFreq_current = obj.noiseFracFreq_vec(nextIdx);
            end
            obj.sampleIndex = nextIdx;
            % If index exceeds array, colored component keeps its last value.

            % Propagate WFM+RWFM bias state
            new_bias_s = obj.bias_s + dt_s * obj.fracFreq + n_bias_wfm;

            % Propagate RWFM fractional-frequency state
            new_frac = obj.fracFreq + det_drift_frac + dn_freq_rwfm;

            obj.lastTime_s = obj.lastTime_s + dt_s;
            obj.bias_s     = new_bias_s;
            obj.fracFreq   = new_frac;

            % Log TOTAL = state + colored
            obj.history.time_s   = [obj.history.time_s;  obj.lastTime_s];
            obj.history.bias_s   = [obj.history.bias_s;  ...
                obj.bias_s + obj.coloredBias_s_current];
            obj.history.fracFreq = [obj.history.fracFreq; ...
                obj.fracFreq + obj.coloredFracFreq_current];
        end

        % ---- Public accessors: return TOTAL (state + colored) --------- %

        function b_s = getBiasSeconds(obj)
            % getBiasSeconds  Total clock time bias [s] (state + colored component).
            b_s = obj.bias_s + obj.coloredBias_s_current;
        end

        function b_m = getBiasMeters(obj)
            % getBiasMeters  Total clock range bias [m].
            b_m = obj.getBiasSeconds() * revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end

        function y = getFractionalFrequency(obj)
            % getFractionalFrequency  Total fractional frequency (state + colored).
            y = obj.fracFreq + obj.coloredFracFreq_current;
        end

        function bdot_mps = getDriftMetersPerSecond(obj)
            % getDriftMetersPerSecond  Total clock drift [m/s].
            bdot_mps = obj.getFractionalFrequency() * revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end

        % ---- State-only accessors: WFM+RWFM component only ------------ %

        function b_s = getStateBiasSeconds(obj)
            % getStateBiasSeconds  WFM+RWFM state bias only [s] (no colored).
            b_s = obj.bias_s;
        end

        function y = getStateFracFreq(obj)
            % getStateFracFreq  RWFM fractional-frequency state only (no colored).
            y = obj.fracFreq;
        end

        function x = getStateVectorMeters(obj)
            % getStateVectorMeters  [bias_m; drift_mps] from TOTAL output.
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            x = [obj.getBiasMeters(); obj.getDriftMetersPerSecond()];
        end

        function setStateFromMeters(obj, b_m, bdot_mps)
            % setStateFromMeters  Set WFM+RWFM state from range-domain values.
            c           = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            obj.bias_s  = b_m / c;
            obj.fracFreq = bdot_mps / c;
        end

        % -------------------------------------------------------------- %
        function Q = getProcessNoiseQ(obj, dt_s, representation)
            % getProcessNoiseQ  Return 2x2 EKF process-noise matrix.
            %
            % Brown-Hwang 2-state model for WFM (h0) + RWFM (hMinus2):
            %
            %   q1  = h0/2          [WFM phase variance rate, s^2/s]
            %   q2  = 2*pi^2*hm2    [RWFM freq variance rate, 1/s]
            %   q_f = 2*ln(2)*hm1   [flicker-FM (FFM) variance term]
            %
            %   Q_s = [(q1+q_f)*dt + q2*dt^3/3,  q2*dt^2/2  ]
            %         [q2*dt^2/2,                 q2*dt + q_f*dt]   (FFM in freq, if enabled)
            %
            % Flicker FM (hMinus1) is a FREQUENCY noise, so its variance is added to
            % the drift (frequency) state Q22 where it physically acts -- otherwise
            % the RWFM-only Q22 is too small and the drift +/-3sigma envelope
            % under-covers the true frequency wander. The historical conservative
            % FFM term in the phase entry Q11 is retained. Gated by driftFlickerInQ
            % (default false): an A/B test showed adding FFM inflates Q22 ~26x but
            % leaves the actual-error/filter-sigma ratio unchanged, so it does NOT
            % restore drift +/-3sigma consistency (that is an R / observability issue,
            % not a process-noise magnitude issue). Kept as an opt-in lever.
            %
            % WPM (h2) and FPM (h1) are excluded from Q: they affect
            % timescales << dt and are represented in the truth model only.
            %
            % representation: 'meters' (default) or 'seconds'

            if nargin < 3; representation = 'meters'; end
            h = obj.noiseCoeffs;

            q1    = h.h0 / 2;                     % WFM phase variance rate
            q2    = 2 * pi^2 * h.hMinus2;         % RWFM freq-drift variance rate
            q_ffm = 2 * log(2) * h.hMinus1;       % flicker-FM (FFM) variance term

            % Drift (frequency) process-noise entry: RWFM, plus flicker-FM when enabled.
            q22 = q2 * dt_s;
            if obj.driftFlickerInQ
                q22 = q22 + q_ffm * dt_s;
            end

            % Discrete-time integral: Q over interval dt
            Q_s = [(q1 + q_ffm)*dt_s + q2*dt_s^3/3,  q2*dt_s^2/2; ...
                    q2*dt_s^2/2,                       q22];

            % Ensure symmetry (floating-point safety)
            Q_s = (Q_s + Q_s') / 2;

            if strcmp(representation, 'meters')
                c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                T = diag([c, c]);
                Q = T * Q_s * T';
            else
                Q = Q_s;
            end
        end

        % -------------------------------------------------------------- %
        function [tau, adev] = allanDeviation(obj, tauVec_s)
            % allanDeviation  Empirical ADEV from history.bias_s (TOTAL bias).
            %
            % Returns sigma_y(tau) — Allan deviation (NOT Allan variance).
            % For deterministic clocks the empirical history is all zeros
            % and this returns all zeros (use theoreticalAllanDeviation instead).

            if isempty(obj.history.bias_s)
                error('ClockModel:allanDeviation', ...
                    'No history available. Run simulation first.');
            end

            t    = obj.history.time_s;
            x_s  = obj.history.bias_s;
            tau  = tauVec_s(:);
            adev = nan(size(tau));

            if numel(t) < 4; return; end
            dt = mean(diff(t));

            for k = 1:numel(tau)
                m = round(tau(k) / dt);
                if m < 1 || m > floor(numel(x_s)/2); continue; end
                n = floor(numel(x_s) / m);
                if n < 3; continue; end
                sum_sq = 0;
                for j = 1:(n-2)
                    x1 = mean(x_s((j-1)*m+1 : j*m));
                    x2 = mean(x_s(j*m+1     : (j+1)*m));
                    x3 = mean(x_s((j+1)*m+1 : (j+2)*m));
                    sum_sq = sum_sq + (x3 - 2*x2 + x1)^2;
                end
                adev(k) = sqrt(sum_sq / (2 * (n-2) * tau(k)^2));
            end
        end

        % -------------------------------------------------------------- %
        function [tau, adev_th] = theoreticalAllanDeviation(obj, tauVec_s)
            % theoreticalAllanDeviation  Theoretical sigma_y(tau) from h-coefficients.
            %
            % IEEE Std 1139-2008 power-law ADEV formulas.
            % Returns sigma_y(tau) — Allan DEVIATION, not variance.

            h    = obj.noiseCoeffs;
            tau  = tauVec_s(:);
            var_y = zeros(size(tau));

            var_y = var_y + 3 * h.h2 ./ (4*pi^2 * tau.^2);          % WPM
            var_y = var_y + 1.038 * h.h1 ./ (4*pi^2 * tau.^2);      % FPM
            var_y = var_y + h.h0 ./ (2 * tau);                       % WFM
            var_y = var_y + 2 * log(2) * h.hMinus1;                  % FFM (floor)
            var_y = var_y + (8*pi^2/6) * h.hMinus2 .* tau;           % RWFM

            adev_th = sqrt(max(var_y, 0));
        end

        % -------------------------------------------------------------- %
        function plotClockDiagnostics(obj)
            % plotClockDiagnostics  Quick diagnostic plot of clock history.

            if isempty(obj.history.time_s)
                warning('ClockModel:plotClockDiagnostics','No history to plot.');
                return
            end

            t = obj.history.time_s;
            figure('Name', ['ClockModel: ' obj.name]);

            subplot(3,1,1);
            plot(t, obj.history.bias_s * 1e9, 'b');
            xlabel('Time [s]'); ylabel('Bias [ns]');
            title([obj.name ' — Total Clock Bias']);
            grid on;

            subplot(3,1,2);
            plot(t, obj.history.fracFreq);
            xlabel('Time [s]'); ylabel('Frac Freq [-]');
            title([obj.name ' — Total Fractional Frequency']);
            grid on;

            dt   = mean(diff(t));
            maxT = floor(numel(t)/4) * dt;
            if maxT > dt
                tauV = logspace(log10(dt), log10(maxT), 30);
                [~, adev_emp] = obj.allanDeviation(tauV);
                [~, adev_th ] = obj.theoreticalAllanDeviation(tauV);

                subplot(3,1,3);
                loglog(tauV, adev_th, 'r--', 'LineWidth',1.5, 'DisplayName','Theoretical');
                hold on;
                if any(~isnan(adev_emp) & adev_emp > 0)
                    loglog(tauV, adev_emp, 'bo-', 'DisplayName','Empirical');
                else
                    text(tauV(ceil(numel(tauV)/2)), adev_th(ceil(numel(adev_th)/2)), ...
                        'Empirical ADEV is zero (deterministic clock)', ...
                        'FontSize', 8, 'Color', [0.5 0.5 0.5]);
                end
                xlabel('\tau [s]'); ylabel('\sigma_y(\tau)');
                title([obj.name ' — Allan Deviation \sigma_y(\tau)']);
                legend; grid on;
            end
        end

    end  % methods
end  % classdef

% ======================================================================
% File-scope private helper
% ======================================================================
function X_sym = makeHermitian_(X, N)
    % Enforce Hermitian symmetry so IFFT produces a real output.
    X_sym = X;
    X_sym(1) = abs(X(1));   % DC must be real
    if mod(N,2) == 0
        X_sym(N/2+1) = abs(X(N/2+1));  % Nyquist must be real
        X_sym(N/2+2:end) = conj(flipud(X_sym(2:N/2)));
    else
        X_sym((N+3)/2:end) = conj(flipud(X_sym(2:(N+1)/2)));
    end
end
