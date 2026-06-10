classdef ClockModel < handle
    % ClockModel  Oscillator clock model for reverse-GNSS simulation.
    %
    % Models a physical oscillator with five power-law noise types based on
    % the one-sided PSD of fractional frequency fluctuations:
    %
    %   S_y(f) = h2*f^2 + h1*f + h0 + hMinus1/f + hMinus2/f^2
    %
    %   h2       white phase modulation (WPM)          [1/Hz^2 ... actually h2*f^2 => Hz^2*1/Hz = Hz => dimensionless/Hz]
    %   h1       flicker phase modulation (FPM)
    %   h0       white frequency modulation (WFM)
    %   hMinus1  flicker frequency modulation (FFMS)
    %   hMinus2  random-walk frequency modulation (RWFM)
    %
    % Note on Allan deviation relationship to h coefficients:
    %   ADEV(tau) for each noise type follows a characteristic power law:
    %     WPM:   sigma_y(tau) ~ tau^(-1)
    %     FPM:   sigma_y(tau) ~ tau^(-1)   (same slope as WPM, different coeff)
    %     WFM:   sigma_y(tau) ~ tau^(-1/2)
    %     FFEM:  sigma_y(tau) ~ tau^0       (constant floor)
    %     RWFM:  sigma_y(tau) ~ tau^(+1/2)
    %
    % Time-domain propagation:
    %   White FM (h0) and random-walk FM (hMinus2) are propagated exactly as
    %   a discrete-time clock model with white process noise.
    %
    %   White PM (h2), flicker PM (h1), and flicker FM (hMinus1) are
    %   synthesised by precomputing a colored-noise sequence over the full
    %   simulation time span using spectral (FFT) synthesis.  The spectral
    %   method generates noise with the exact one-sided PSD shape; see
    %   precomputeNoise() for details.
    %
    % State definitions (two equivalent representations):
    %   Time-domain:   [x_clock_s,  y_clock_frac]
    %   Range-domain:  [b_clock_m,  bdot_clock_mps]
    %     where  b_m = c * x_s  and  bdot_mps = c * y_frac
    %
    % Usage:
    %   cfg.name = 'OCXO_1';
    %   cfg.clockType = 'OCXO';
    %   cfg.noiseCoeffs.h0 = 2e-20;      % WFM
    %   cfg.noiseCoeffs.hMinus2 = 2e-20; % RWFM
    %   ... (set unused h terms to 0)
    %   clk = revgnss.ClockModel(cfg);
    %   clk.precomputeNoise(0:0.1:1000);
    %   clk.step(0.1);
    %   b_m = clk.getBiasMeters();

    properties
        name            (1,:) char    = 'unnamed'
        clockType       (1,:) char    = 'generic'

        % Internal time-domain state
        bias_s          (1,1) double  = 0   % clock time bias [s]
        fracFreq        (1,1) double  = 0   % fractional frequency error [-]
        driftRate_fracPerSec (1,1) double = 0 % deterministic frequency drift rate [1/s^2]

        % Noise configuration
        noiseCoeffs     (1,1) struct        % h2,h1,h0,hMinus1,hMinus2
        deterministic   (1,1) logical = false % if true, no stochastic noise

        % Reproducibility
        seed            (1,1) double  = 42

        % Current simulation time
        lastTime_s      (1,1) double  = 0

        % History log
        history         (1,1) struct

        % Pre-computed colored-noise sequences (indexed by sample number)
        noiseBias_s_vec     (:,1) double = []  % pre-synthesised bias noise [s]
        noiseFracFreq_vec   (:,1) double = []  % pre-synthesised freq noise [-]
        noiseTimeVec_s      (:,1) double = []  % time vector used for synthesis
        sampleIndex         (1,1) double = 1   % pointer into pre-computed array
    end

    properties (Constant, Access = private)
        C = revgnss.Constants.SPEED_OF_LIGHT_MPS;
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = ClockModel(cfg)
            % ClockModel  Constructor.
            %   cfg fields:
            %     name           string
            %     clockType      string
            %     noiseCoeffs    struct with fields h2,h1,h0,hMinus1,hMinus2
            %     deterministic  logical (optional, default false)
            %     seed           double  (optional, default 42)
            %     bias_s         initial bias in seconds (optional)
            %     fracFreq       initial fractional frequency (optional)
            %     driftRate_fracPerSec  deterministic drift (optional)

            if nargin == 0; return; end

            obj.name      = cfg.name;
            obj.clockType = cfg.clockType;

            % Default all h coefficients to zero then overwrite
            obj.noiseCoeffs = struct('h2',0,'h1',0,'h0',0,'hMinus1',0,'hMinus2',0);
            fn = fieldnames(cfg.noiseCoeffs);
            for k = 1:numel(fn)
                obj.noiseCoeffs.(fn{k}) = cfg.noiseCoeffs.(fn{k});
            end

            if isfield(cfg,'deterministic');  obj.deterministic = cfg.deterministic; end
            if isfield(cfg,'seed');           obj.seed          = cfg.seed;          end
            if isfield(cfg,'bias_s');         obj.bias_s        = cfg.bias_s;        end
            if isfield(cfg,'fracFreq');       obj.fracFreq      = cfg.fracFreq;      end
            if isfield(cfg,'driftRate_fracPerSec')
                obj.driftRate_fracPerSec = cfg.driftRate_fracPerSec;
            end

            obj.history.time_s  = [];
            obj.history.bias_s  = [];
            obj.history.fracFreq = [];
        end

        % -------------------------------------------------------------- %
        function reset(obj, seed)
            % reset  Reset state and optionally reseed the random stream.
            if nargin > 1; obj.seed = seed; end
            obj.bias_s      = 0;
            obj.fracFreq    = 0;
            obj.lastTime_s  = 0;
            obj.sampleIndex = 1;
            obj.history.time_s   = [];
            obj.history.bias_s   = [];
            obj.history.fracFreq = [];
            obj.noiseBias_s_vec  = [];
            obj.noiseFracFreq_vec = [];
        end

        % -------------------------------------------------------------- %
        function precomputeNoise(obj, tVec_s)
            % precomputeNoise  Synthesise colored-noise sequences over tVec_s.
            %
            % White FM (h0) and RWFM (hMinus2) are propagated step-by-step
            % in step(), so only the PM/FM colored terms are pre-computed here.
            %
            % Spectral synthesis method:
            %   1. Generate white Gaussian noise in frequency domain
            %   2. Shape by sqrt(S_y(f)) for each power-law type
            %   3. IFFT to obtain time-domain sequence
            %   4. Phase noise is integrated to get time/bias noise.
            %
            % Units: bias [s], fracFreq [-]

            obj.noiseTimeVec_s = tVec_s(:);
            N = numel(tVec_s);
            dt = mean(diff(tVec_s));
            if dt <= 0; error('ClockModel:precomputeNoise','tVec_s must be increasing'); end
            obj.sampleIndex = 1;

            if obj.deterministic
                obj.noiseBias_s_vec   = zeros(N,1);
                obj.noiseFracFreq_vec = zeros(N,1);
                return
            end

            rng(obj.seed);

            % Frequency axis (one-sided positives, DC excluded)
            fs = 1/dt;
            f_all = (0:N-1)'* (fs/N);   % [Hz], length N
            f_pos = f_all;
            f_pos(1) = f_pos(2);         % avoid division by zero at DC

            h = obj.noiseCoeffs;

            % --- Build two-sided PSD shape for fractional frequency -----
            % WFM and RWFM are handled in step(); here we handle:
            %   WPM (h2): S_y(f) = h2*f^2
            %   FPM (h1): S_y(f) = h1*f
            %   FFM (hMinus1): S_y(f) = hMinus1/f
            Sy_frac = h.h2 * f_pos.^2 + ...
                      h.h1 * f_pos     + ...
                      h.hMinus1 ./ f_pos;

            % Amplitude spectrum from PSD: A(f) = sqrt(Sy * fs/N)
            A_frac = sqrt(max(Sy_frac, 0) * fs / N);

            % Random complex spectrum (Hermitian symmetry)
            WN_frac = randn(N,1) + 1i*randn(N,1);
            X_frac  = A_frac .* WN_frac;

            % Enforce Hermitian symmetry for real output
            X_frac_sym = makeHermitian(X_frac, N);
            y_frac_colored = real(ifft(X_frac_sym));

            % Convert fractional frequency colored noise -> phase/bias noise
            % x(t) = integral_0^t y(tau) dtau  =>  cumulative trapezoidal
            x_bias_colored = cumtrapz(tVec_s, y_frac_colored);

            obj.noiseBias_s_vec   = x_bias_colored;
            obj.noiseFracFreq_vec = y_frac_colored;
        end

        % -------------------------------------------------------------- %
        function step(obj, dt_s)
            % step  Propagate clock state by dt_s seconds.
            %
            % White FM and RWFM are simulated with direct discrete-time noise.
            % Colored noise (WPM, FPM, FFM) comes from pre-computed sequence.

            if nargin < 2 || dt_s <= 0
                error('ClockModel:step','dt_s must be positive');
            end

            h = obj.noiseCoeffs;
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;

            % --- White FM process noise (h0) ----------------------------
            %   sigma_y^2 = h0 * fs / 2   over one sample interval
            %   Equivalent discrete-time variance of fractional freq increment
            sigma_wfm_frac = sqrt(h.h0 / (2 * dt_s));

            % --- RWFM process noise (hMinus2) ---------------------------
            %   sigma_ydot^2 = 2*pi^2 * hMinus2 * fs
            sigma_rwfm_frac = sqrt(2 * pi^2 * h.hMinus2 / dt_s);

            if obj.deterministic
                n_frac  = 0;
                dn_drift = 0;
            else
                n_frac   = randn * sigma_wfm_frac;
                dn_drift = randn * sigma_rwfm_frac;
            end

            % Deterministic drift
            det_drift = obj.driftRate_fracPerSec * dt_s;

            % Propagate fractional frequency (WFM + RWFM)
            new_frac = obj.fracFreq + det_drift + n_frac + dn_drift * dt_s;

            % Colored-noise contribution from pre-computed sequence
            if ~isempty(obj.noiseBias_s_vec) && obj.sampleIndex <= numel(obj.noiseBias_s_vec)
                idx = obj.sampleIndex;
                colored_bias_s  = obj.noiseBias_s_vec(idx);
                colored_frac    = obj.noiseFracFreq_vec(idx);
                obj.sampleIndex = obj.sampleIndex + 1;
            else
                colored_bias_s = 0;
                colored_frac   = 0;
            end

            % Propagate bias: x(k+1) = x(k) + dt*y(k)
            new_bias_s = obj.bias_s + dt_s * obj.fracFreq + colored_bias_s;
            new_frac   = new_frac + colored_frac;

            obj.lastTime_s = obj.lastTime_s + dt_s;
            obj.bias_s     = new_bias_s;
            obj.fracFreq   = new_frac;

            obj.history.time_s   = [obj.history.time_s;  obj.lastTime_s];
            obj.history.bias_s   = [obj.history.bias_s;  obj.bias_s];
            obj.history.fracFreq = [obj.history.fracFreq; obj.fracFreq];
        end

        % -------------------------------------------------------------- %
        function b_s = getBiasSeconds(obj)
            b_s = obj.bias_s;
        end

        function b_m = getBiasMeters(obj)
            b_m = obj.bias_s * revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end

        function y = getFractionalFrequency(obj)
            y = obj.fracFreq;
        end

        function bdot_mps = getDriftMetersPerSecond(obj)
            bdot_mps = obj.fracFreq * revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end

        function x = getStateVectorMeters(obj)
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            x = [obj.bias_s * c; obj.fracFreq * c];
        end

        function setStateFromMeters(obj, b_m, bdot_mps)
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            obj.bias_s  = b_m / c;
            obj.fracFreq = bdot_mps / c;
        end

        % -------------------------------------------------------------- %
        function Q = getProcessNoiseQ(obj, dt_s, representation)
            % getProcessNoiseQ  Return 2x2 discrete-time process noise matrix.
            %
            % representation: 'meters' => [b_m; bdot_mps]
            %                 'seconds' => [x_s; y_frac]
            %
            % Based on standard clock process noise model:
            %   Q_ss = [q1*dt + q2*dt^3/3,  q2*dt^2/2]
            %          [q2*dt^2/2,           q2*dt   ]
            % where q1 = h0/2  (WFM contribution to phase)
            %       q2 = 2*pi^2*hMinus2  (RWFM contribution to freq drift)

            if nargin < 3; representation = 'meters'; end
            h = obj.noiseCoeffs;

            q1 = h.h0 / 2;                     % WFM -> phase variance rate
            q2 = 2 * pi^2 * h.hMinus2;         % RWFM -> freq-rate variance

            % Continuous-time process noise integral discretized over dt
            Q_s = [q1*dt_s + q2*dt_s^3/3,  q2*dt_s^2/2; ...
                   q2*dt_s^2/2,             q2*dt_s];

            if strcmp(representation, 'meters')
                c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                T = [c, 0; 0, c];
                Q = T * Q_s * T';
            else
                Q = Q_s;
            end
        end

        % -------------------------------------------------------------- %
        function [tau, adev] = allanDeviation(obj, tauVec_s)
            % allanDeviation  Compute empirical ADEV from stored history.
            %
            % Returns ADEV at each tau value in tauVec_s.

            if isempty(obj.history.bias_s)
                error('ClockModel:allanDeviation','No history available. Run simulation first.');
            end

            t    = obj.history.time_s;
            x_s  = obj.history.bias_s;
            tau  = tauVec_s(:);
            adev = nan(size(tau));

            if numel(t) < 4; return; end
            dt = mean(diff(t));

            for k = 1:numel(tau)
                m = round(tau(k) / dt);  % samples per averaging interval
                if m < 1 || m > floor(numel(x_s)/2); continue; end
                n = floor(numel(x_s) / m);
                if n < 3; continue; end
                % Allan deviation from phase data
                sum_sq = 0;
                for j = 1:(n-2)
                    x1 = mean(x_s((j-1)*m+1 : j*m));
                    x2 = mean(x_s(j*m+1     : (j+1)*m));
                    x3 = mean(x_s((j+1)*m+1 : (j+2)*m));
                    sum_sq = sum_sq + (x3 - 2*x2 + x1)^2;
                end
                adev(k) = sqrt(sum_sq / (2*(n-2)*tau(k)^2));
            end
        end

        % -------------------------------------------------------------- %
        function [tau, adev_th] = theoreticalAllanDeviation(obj, tauVec_s)
            % theoreticalAllanDeviation  Compute theoretical ADEV from h coefficients.
            %
            % Uses standard power-law ADEV formulas (IEEE Std 1139-2008):
            %   WPM:   sigma_y^2(tau) = 3*f_h*h2 / (4*pi^2*tau^2)       approx h2/(2*tau^2)
            %   FPM:   sigma_y^2(tau) ~ 1.038*h1 / (4*pi^2*tau^2)       approx
            %   WFM:   sigma_y^2(tau) = h0 / (2*tau)
            %   FFM:   sigma_y^2(tau) = 2*ln(2)*hMinus1
            %   RWFM:  sigma_y^2(tau) = 8*pi^2*hMinus2*tau / 6

            h = obj.noiseCoeffs;
            tau = tauVec_s(:);
            var_y = zeros(size(tau));

            % White PM: approximation ignoring h bandwidth
            var_y = var_y + 3*h.h2 ./ tau.^2 / (4*pi^2);
            % Flicker PM: approximation
            var_y = var_y + 1.038 * h.h1 ./ tau.^2 / (4*pi^2);
            % White FM
            var_y = var_y + h.h0 ./ (2*tau);
            % Flicker FM
            var_y = var_y + 2*log(2)*h.hMinus1;
            % Random-walk FM
            var_y = var_y + (8*pi^2/6) * h.hMinus2 .* tau;

            adev_th = sqrt(max(var_y, 0));
        end

        % -------------------------------------------------------------- %
        function plotClockDiagnostics(obj)
            % plotClockDiagnostics  Generate standard clock diagnostic plots.

            if isempty(obj.history.time_s)
                warning('ClockModel:plotClockDiagnostics','No history to plot.');
                return
            end

            t   = obj.history.time_s;
            b_m = obj.history.bias_s * revgnss.Constants.SPEED_OF_LIGHT_MPS;
            y   = obj.history.fracFreq;

            figure('Name', ['ClockModel: ' obj.name]);

            subplot(3,1,1);
            plot(t, obj.history.bias_s * 1e9, 'b');
            xlabel('Time [s]'); ylabel('Bias [ns]');
            title([obj.name ' — Clock Bias']);
            grid on;

            subplot(3,1,2);
            plot(t, y);
            xlabel('Time [s]'); ylabel('Fractional Freq [-]');
            title([obj.name ' — Fractional Frequency Error']);
            grid on;

            % Allan deviation comparison
            dt = mean(diff(t));
            maxTau = floor(numel(t)/4) * dt;
            if maxTau > dt
                tauV = logspace(log10(dt), log10(maxTau), 30);
                [~, adev_emp] = obj.allanDeviation(tauV);
                [~, adev_th]  = obj.theoreticalAllanDeviation(tauV);

                subplot(3,1,3);
                loglog(tauV, adev_emp, 'bo-', tauV, adev_th, 'r--');
                xlabel('\tau [s]'); ylabel('\sigma_y(\tau)');
                title([obj.name ' — Allan Deviation']);
                legend('Empirical','Theoretical');
                grid on;
            end
        end
    end  % methods
end  % classdef

% ======================================================================
% Local helper (file-scope private function)
% ======================================================================
function X_sym = makeHermitian(X, N)
    % Enforce Hermitian symmetry so IFFT produces a real output.
    X_sym = X;
    X_sym(1) = abs(X(1));  % DC must be real
    if mod(N,2) == 0
        X_sym(N/2+1) = abs(X(N/2+1));  % Nyquist must be real
        % Mirror
        X_sym(N/2+2:end) = conj(flipud(X_sym(2:N/2)));
    else
        X_sym((N+3)/2:end) = conj(flipud(X_sym(2:(N+1)/2)));
    end
end
