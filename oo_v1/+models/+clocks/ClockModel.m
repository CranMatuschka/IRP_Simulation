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
    %   FFM:   sigma_y(tau) ~ tau^0       (floor)
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
        relativisticFracFreq (1,1) double = 0  % Constant relativistic fractional-frequency
                                               % offset [-] (gated, default 0). Added to the phase
                                               % (bias) increment each step so the clock bias
                                               % accumulates a LINEAR ramp, AND reported by
                                               % getFractionalFrequency()/getDriftMetersPerSecond()
                                               % so the rate and the ramp describe ONE clock.
                                               % CORRECTED 2026-08-09: it used to be excluded from
                                               % those accessors, which made the truth internally
                                               % inconsistent (range ramped at 0.1615 m/s while
                                               % Doppler reported zero) and cost 13 m of position
                                               % error. Use getOscillatorFractionalFrequency() where
                                               % proper time is modelled explicitly.

        % Noise configuration
        noiseCoeffs     (1,1) struct        % h2, h1, h0, hMinus1, hMinus2
        deterministic   (1,1) logical = false  % if true, no stochastic noise
        % Flicker FM (hMinus1) carried in Q as its Allan-equivalent random walk. Default TRUE:
        % with it off, Q22 is 50-921x below the truth's own frequency wander for
        % flicker-dominated templates (CESIUM1, RUBIDIUM), which makes the filter
        % inconsistent for every clock except the one the golden happens to use. Set false
        % only to reproduce pre-2026-08-09 numbers. SUPERSEDES the old driftFlickerInQ knob,
        % which added a term a factor 3 below this equivalence and defaulted off.
        flickerAsEquivalentRwfmInQ (1,1) logical = true
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
            if isfield(cfg,'flickerAsEquivalentRwfmInQ')
                obj.flickerAsEquivalentRwfmInQ = logical(cfg.flickerAsEquivalentRwfmInQ);
            end
            if isfield(cfg,'driftFlickerInQ')
                % Legacy knob, removed 2026-08-09. It is NOT silently mapped onto the new
                % one: it added 2*ln(2)*hMinus1*dt to Q22 only, a factor 3 below the Allan
                % equivalence and with no matching phase term, so honouring it here would
                % reproduce neither the old nor the new behaviour.
                warning('ClockModel:driftFlickerInQRemoved', ...
                    ['cfg.driftFlickerInQ was removed; flicker FM is now carried as its ' ...
                     'Allan-equivalent random walk via flickerAsEquivalentRwfmInQ ' ...
                     '(default true). The supplied value is ignored.']);
            end
            if isfield(cfg,'seed');                  obj.seed                 = cfg.seed;                 end
            if isfield(cfg,'bias_s');                obj.bias_s               = cfg.bias_s;               end
            if isfield(cfg,'fracFreq');              obj.fracFreq             = cfg.fracFreq;             end
            if isfield(cfg,'driftRate_fracPerSec'); obj.driftRate_fracPerSec = cfg.driftRate_fracPerSec; end
            if isfield(cfg,'relativisticFracFreq'); obj.relativisticFracFreq = cfg.relativisticFracFreq; end

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

            % Amplitude spectrum.
            % Scaling is tied to two conventions used below: MATLAB's ifft carries 1/N,
            % and each Hermitian-paired bin gets X_k = A_k*(g1+i*g2) with unit-variance
            % g, so Var(y_n) = (4/N^2)*sum_k A_k^2. Matching the one-sided PSD target
            % Var(y) = sum_k S_y(f_k)*(fs/N) bin-by-bin requires A_k = sqrt(N*fs*S_k)/2.
            A_frac     = sqrt(max(Sy_frac, 0) * fs * N) / 2;

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

            % EXACT two-state discretisation (was forward Euler until 2026-08-09).
            %
            % The pair (bias, fracFreq) is propagated with the SAME discrete covariance the
            % filter charges in getProcessNoiseQ:
            %     Qs = [q1*dt + q2*dt^3/3,  q2*dt^2/2 ]
            %          [q2*dt^2/2,          q2*dt     ]
            % drawn as Qs = L*L' (Cholesky) from two unit normals. The old code drew the WFM
            % phase jump and the RWFM frequency kick INDEPENDENTLY and applied the kick only
            % to the NEXT step, so the truth never produced the within-step q2*dt^3/3 phase
            % term nor the q2*dt^2/2 phase/frequency cross-covariance. That is invisible when
            % WFM dominates (CESIUM1, RUBIDIUM) and 100x wrong when RWFM dominates: MEASURED
            % sqrt(Q11)/empirical = 0.01 for jow OCXO and 0.17 for TCXO before this fix, i.e.
            % the filter charged a phase process noise its own truth never generated.
            %
            % Draw order (g1 then g2) and the leading coefficient L(1,1) = sqrt(q1*dt + ...)
            % are kept so a WFM-dominated clock moves only in the last digits: for jow
            % CESIUM1 q2*dt^3/3 is ~11 decades below q1*dt.
            q1 = h.h0 / 2;                      % WFM phase variance rate [s^2/s]
            q2 = 2 * pi^2 * h.hMinus2;          % RWFM frequency variance rate [1/s]

            if obj.deterministic
                n_bias_wfm   = 0;
                dn_freq_rwfm = 0;
            else
                g1 = randn(obj.rngStream);
                g2 = randn(obj.rngStream);
                v11 = q1*dt_s + q2*dt_s^3/3;
                v12 = q2*dt_s^2/2;
                v22 = q2*dt_s;
                L11 = sqrt(max(v11, 0));
                if L11 > 0
                    L21 = v12 / L11;
                else
                    L21 = 0;
                end
                L22 = sqrt(max(v22 - L21^2, 0));
                n_bias_wfm   = L11 * g1;                 % phase increment noise [s]
                dn_freq_rwfm = L21 * g1 + L22 * g2;      % frequency increment noise [-]
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
            % Add the (gated) constant relativistic fractional-frequency offset to the
            % phase increment so the clock bias accumulates a LINEAR relativistic ramp
            % (c*relativisticFracFreq [m/s]); default 0 -> unchanged / golden byte-identical.
            new_bias_s = obj.bias_s + dt_s * (obj.fracFreq + obj.relativisticFracFreq) + n_bias_wfm;

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
            % getFractionalFrequency  Total fractional frequency
            % (state + colored + relativistic offset).
            %
            % The relativistic term MUST be here. It is a genuine frequency offset: the
            % oscillator runs fast by y_rel, so it shows up in the clock's RATE exactly as
            % it shows up, integrated, in its phase. Excluding it (the behaviour before
            % 2026-08-09) made the truth internally inconsistent -- the truth pseudorange
            % ramped at c*y_rel = 0.1615 m/s while the truth Doppler, built from this
            % accessor in DopplerMeasurementBuilder, reported a rate of exactly zero.
            %
            % The EKF propagates b_rx' = bdot_rx, so it cannot satisfy both channels at
            % once: 40 Doppler rows per epoch pinned bdot_rx at ~0 while the code rows
            % dragged b_rx along the ramp. Whatever the clock-bias state's process noise
            % could not absorb was projected into position by the Kalman gain. MEASURED on
            % G5S1R4 / 3600 s with every error source off: 13.07 m of position error on an
            % OCXO Q against 0.20 m on a caesium Q, the error vector parallel to K*1
            % restricted to position (cos = 0.9997), reported sigma identical to 4 s.f. in
            % both -- so the covariance could not see it and err/sigma reached 34.
            % Switching the ramp off collapsed OCXO to 0.103 m, onto caesium's 0.107 m.
            %
            % GOLDEN SAFETY: relativisticFracFreq defaults to 0 and is only ever written
            % when physics.relativity.clock.truth.enable is true, so this is a no-op for
            % every run that does not enable the relativistic clock.
            y = obj.fracFreq + obj.coloredFracFreq_current + obj.relativisticFracFreq;
        end

        function bdot_mps = getDriftMetersPerSecond(obj)
            % getDriftMetersPerSecond  Total clock drift [m/s].
            bdot_mps = obj.getFractionalFrequency() * revgnss.Constants.SPEED_OF_LIGHT_MPS;
        end

        % ---- Oscillator-only accessors: EXCLUDING the relativistic offset ----- %
        %
        % WHICH ONE DO I WANT?
        %   getFractionalFrequency / getDriftMetersPerSecond
        %       The clock's TOTAL rate against a ground reference, relativistic offset
        %       INCLUDED. Use this wherever the model works in COORDINATE time and lets the
        %       clock carry the relativistic effect -- i.e. every ground-space channel
        %       (code, carrier, Doppler, TWSTFT). That is the rate such a link observes.
        %   getOscillatorFractionalFrequency / getOscillatorDriftMetersPerSecond
        %       The oscillator's OWN rate error, relativistic offset EXCLUDED. Use this
        %       wherever the surrounding model represents proper time EXPLICITLY -- the
        %       four-timestamp and two-way-ISL endpoints, which pass a separate
        %       properTimeRate = 1 - (GM/r + v^2/2)/c^2 into TwoWayCodeEndpointModel.
        %
        % WHY THE SPLIT IS EXACTLY RIGHT (algebraic identity, checked numerically in
        % tests/test_wpD_relativistic_clock T6):
        %       properTimeRate(r_sat,v_sat) - properTimeRate(Re,v_ground)
        %     = GM/c^2*(1/Re - 1/r_sat) - v_sat^2/(2c^2) + v_ground^2/(2c^2)
        %     = revgnss.Relativity.clockFracFreq(r_sat,v_sat)   == y_rel
        % An endpoint that already supplies properTimeRate is therefore ALREADY carrying
        % y_rel; adding it again through localClockRate counts the same physics twice.
        % Measured double-count if this is got wrong: c*y_rel = 0.1615 m/s on every
        % four-timestamp endpoint rate.

        function y = getOscillatorFractionalFrequency(obj)
            % getOscillatorFractionalFrequency  Oscillator rate error only [-]
            % (state + colored, NO relativistic offset).
            y = obj.fracFreq + obj.coloredFracFreq_current;
        end

        function bdot_mps = getOscillatorDriftMetersPerSecond(obj)
            % getOscillatorDriftMetersPerSecond  Oscillator rate error only [m/s].
            bdot_mps = obj.getOscillatorFractionalFrequency() * ...
                revgnss.Constants.SPEED_OF_LIGHT_MPS;
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
            % ROOT CAUSE: for the CESIUM1 receiver the drift wander (~1e-6 m/s per
            % step) is 3-4 decades below the Doppler resolution (sigma ~0.01 m/s), so
            % bdot_rx is measurement-limited and its +/-3sigma envelope reflects Q, not
            % information -- a FUNDAMENTAL observability limit, not a Q bug. The report
            % surfaces the empirical drift +/-3sigma coverage (Plotter Fig 06,
            % revgnss.Plotter.driftCoverage) so the limit is measured, not just asserted.
            %
            % WPM (h2) and FPM (h1) are excluded from Q: they affect
            % timescales << dt and are represented in the truth model only.
            %
            % representation: 'meters' (default) or 'seconds'

            if nargin < 3; representation = 'meters'; end
            h = obj.noiseCoeffs;

            q1 = h.h0 / 2;                        % WFM phase variance rate
            q2 = 2 * pi^2 * h.hMinus2;            % RWFM freq-drift variance rate

            % Flicker FM (hMinus1) as an ALLAN-EQUIVALENT random walk (2026-08-09).
            % Flicker is not Markovian, so it has no exact 2-state representation. Rather
            % than guess an inflation factor, equate the two models' Allan variances at the
            % averaging time that matters -- the filter's own propagation interval:
            %     RWFM     sigma_y^2(tau) = (2*pi^2/3) * hMinus2 * tau
            %     flicker  sigma_y^2(tau) = 2*ln(2)  * hMinus1
            %   =>  hMinus2_equivalent = 3*ln(2)*hMinus1 / (pi^2 * tau),  tau = dt
            %   =>  q2_ffm = 2*pi^2*hMinus2_eq = 6*ln(2)*hMinus1 / dt
            % This is validated, not asserted: it predicts the measured shortfall of the
            % PRE-FIX Q22 against the truth's own frequency increments to ~10% across four
            % templates spanning six decades -- CESIUM1 predicted 1027x vs measured 921x,
            % RUBIDIUM 56x vs 50x, OCXO 1.000x vs 1.01x, TCXO 1.02x vs 1.03x.
            %
            % It replaces two ad-hoc terms: a bare q_ffm*dt added to the PHASE entry Q11
            % (dimensionally a phase-variance rate, never sourced) and an opt-in
            % driftFlickerInQ adding q_ffm*dt to Q22, which was a factor 3 below this
            % equivalence and was left off because it "did not restore drift 3-sigma
            % coverage". It does not restore that -- correctly, since drift is
            % measurement-limited at GEO (see below) -- but its absence made Q22 50-921x too
            % small for flicker-dominated clocks, which is what broke every non-caesium rung
            % of the config/ladder/clock axis. Feeding it through q2_eff also gives the phase
            % entry the right flicker term, q2_ffm*dt^3/3 = 2*ln(2)*hMinus1*dt^2, matching
            % the phase drift sigma_y*dt accumulated over one step.
            if obj.flickerAsEquivalentRwfmInQ && dt_s > 0
                q2_ffm = 6 * log(2) * h.hMinus1 / dt_s;
            else
                q2_ffm = 0;
            end
            q2_eff = q2 + q2_ffm;

            % PRE-EXISTING, UNCHANGED: the drift +/-3sigma envelope is NOT restored by any Q
            % magnitude. For the CESIUM1 receiver the drift wander (~1e-6 m/s per step) is
            % 3-4 decades below the Doppler resolution (sigma ~0.01 m/s), so bdot_rx is
            % measurement-limited -- a FUNDAMENTAL observability limit, not a Q bug. The
            % report surfaces the empirical coverage (revgnss.Plotter.driftCoverage).
            %
            % WPM (h2) and FPM (h1) remain excluded: they act on timescales << dt and are
            % identically zero in every shipped template (legacy and jowTable2p1).

            % Discrete-time integral: Q over interval dt (exact for the 2-state model, and
            % the SAME matrix ClockModel.step now draws its truth increments from, modulo
            % the flicker equivalence above).
            Q_s = [q1*dt_s + q2_eff*dt_s^3/3,  q2_eff*dt_s^2/2; ...
                   q2_eff*dt_s^2/2,            q2_eff*dt_s];

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

            % NOTE: WPM/FPM terms omit the high-cutoff-frequency (f_h) factors
            % (WPM propto 3*f_h; FPM propto [1.038 + 3 ln(2 pi f_h tau)]); this
            % overlay is a magnitude approximation for those two branches.
            var_y = var_y + 3 * h.h2 ./ (4*pi^2 * tau.^2);          % WPM
            var_y = var_y + 1.038 * h.h1 ./ (4*pi^2 * tau.^2);      % FPM
            var_y = var_y + h.h0 ./ (2 * tau);                       % WFM
            var_y = var_y + 2 * log(2) * h.hMinus1;                  % FFM (floor)
            % RWFM: IEEE-1139 Allan VARIANCE is (2*pi^2/3) h_-2 tau. This matches the
            % code's own process noise (q2 = 2*pi^2 h_-2) and RWFM truth synthesis
            % (sigma = sqrt(2*pi^2 h_-2 dt)); the previous 8*pi^2/6 = 4*pi^2/3 was 2x
            % too large in variance (sqrt(2) in deviation).
            var_y = var_y + (2*pi^2/3) * h.hMinus2 .* tau;           % RWFM

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
