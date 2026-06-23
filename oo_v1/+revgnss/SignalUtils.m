classdef SignalUtils
    % SignalUtils  Signal / frequency configuration helpers.
    %
    % Methods:
    %   getEnabledSignals        Return struct array of enabled signals from cfg
    %   getFrequencyScaleToL1    Return (f_L1 / f_sig)^2 scale factor

    methods (Static)

        function signals = getEnabledSignals(cfg)
            % getEnabledSignals  Return struct array for all enabled signals.
            %
            % Each element has fields:
            %   name           string   e.g. 'L1'
            %   frequency_Hz   double   carrier frequency [Hz]
            %   lambda_m       double   wavelength [m]
            %   codeSigma0_m   double   baseline code noise sigma [m]
            %
            % Falls back to L1-only if cfg.signals is missing or empty.

            sigL1Default   = revgnss.SignalDefinition.get('L1');
            sigL2Default   = revgnss.SignalDefinition.get('L2');

            defaultL1 = struct('name','L1', ...
                               'frequency_Hz',  sigL1Default.frequency_Hz, ...
                               'lambda_m',      sigL1Default.wavelength_m, ...
                               'codeSigma0_m',  0.30);
            defaultL2 = struct('name','L2', ...
                               'frequency_Hz',  sigL2Default.frequency_Hz, ...
                               'lambda_m',      sigL2Default.wavelength_m, ...
                               'codeSigma0_m',  0.45);

            % Determine enabled signal names
            if ~isfield(cfg, 'signals') || ~isfield(cfg.signals, 'enabled')
                enabledNames = {'L1'};
            else
                enabledNames = cfg.signals.enabled;
                if ischar(enabledNames)
                    enabledNames = {enabledNames};
                end
            end

            nSig = numel(enabledNames);
            signals = repmat(defaultL1, nSig, 1);  % pre-allocate with L1 template

            for k = 1:nSig
                nm = enabledNames{k};
                switch upper(nm)
                    case 'L1'
                        if isfield(cfg,'signals') && isfield(cfg.signals,'L1')
                            s = cfg.signals.L1;
                            signals(k) = struct( ...
                                'name',          nm, ...
                                'frequency_Hz',  getfld_(s, 'frequency_Hz', sigL1Default.frequency_Hz), ...
                                'lambda_m',      getfld_(s, 'lambda_m',     sigL1Default.wavelength_m), ...
                                'codeSigma0_m',  getfld_(s, 'codeSigma0_m', 0.30));
                        else
                            signals(k) = defaultL1;
                            signals(k).name = nm;
                        end
                    case 'L2'
                        if isfield(cfg,'signals') && isfield(cfg.signals,'L2')
                            s = cfg.signals.L2;
                            signals(k) = struct( ...
                                'name',          nm, ...
                                'frequency_Hz',  getfld_(s, 'frequency_Hz', sigL2Default.frequency_Hz), ...
                                'lambda_m',      getfld_(s, 'lambda_m',     sigL2Default.wavelength_m), ...
                                'codeSigma0_m',  getfld_(s, 'codeSigma0_m', 0.45));
                        else
                            signals(k) = defaultL2;
                            signals(k).name = nm;
                        end
                    otherwise
                        % Unknown signal name: use defaults with f_L1
                        warning('SignalUtils:unknownSignal', ...
                            'Unknown signal name ''%s''; using L1 defaults.', nm);
                        signals(k) = defaultL1;
                        signals(k).name = nm;
                end
            end
        end

        function H_clk = buildClockOnlyH(nMeas, nTowers, towerIdx_perMeas)
            % buildClockOnlyH  Clock-only design matrix for gauge-mode test (Issue 17).
            %
            % CHANGED: v3→v4 — Issue 17
            % State ordering: [b_rx, b_tower_1, ..., b_tower_N]
            % Each pseudorange row: b_rx = +1, b_tower_i = -1.
            % H_clk has rows of the form [1, 0, ..., -1_ti, ..., 0].
            %
            % For gaugeMode='none': rank(H_clk) = nTowers  (one null direction:
            %   all clocks shift together → [1,1,...,1] in null space).
            % For fixedReference: the reference tower is set to zero in H_clk;
            %   call buildClockOnlyH_fixedRef instead.
            %
            % Inputs:
            %   nMeas             scalar   number of measurements (pseudorange rows)
            %   nTowers           scalar   number of tower clock states estimated
            %   towerIdx_perMeas  [nMeas x 1]  tower index (1-based) per measurement
            %
            % Output:
            %   H_clk   [nMeas x (1 + nTowers)]  clock-only submatrix
            H_clk = zeros(nMeas, 1 + nTowers);
            H_clk(:, 1) = 1;   % b_rx column
            for mi = 1:nMeas
                ti = towerIdx_perMeas(mi);
                if ti >= 1 && ti <= nTowers
                    H_clk(mi, 1 + ti) = -1;   % b_tower_ti column
                end
            end
        end

        function H_clk = buildClockOnlyH_fixedRef(nMeas, nTowers, towerIdx_perMeas, refTowerIdx)
            % buildClockOnlyH_fixedRef  Clock-only H with fixed reference tower.
            %
            % CHANGED: v3→v4 — Issue 17
            % The reference tower row is omitted (its clock is known = gauge fixed).
            % State ordering: [b_rx, b_tower_1, ..., b_tower_N] excluding refTowerIdx.
            % With fixedReference: rank(H_clk_fixed) = nTowers + 1 (full rank).
            %
            % Inputs:
            %   refTowerIdx  scalar   1-based index of the reference (fixed) tower
            H_clk = revgnss.SignalUtils.buildClockOnlyH(nMeas, nTowers, towerIdx_perMeas);
            % Zero out the reference tower column (it is fixed, not estimated)
            if refTowerIdx >= 1 && refTowerIdx <= nTowers
                H_clk(:, 1 + refTowerIdx) = 0;
            end
        end

        function scale = getFrequencyScaleToL1(signal, cfg)
            % getFrequencyScaleToL1  Return (f_L1 / f_signal)^2.
            %
            % Used for ionospheric dispersive scaling between frequencies.
            % For L1: scale = 1.0 exactly.
            %
            % Inputs:
            %   signal   struct   element from getEnabledSignals()
            %   cfg      struct   simulation config (for f_L1 override)

            f_L1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
            if isfield(cfg,'signals') && isfield(cfg.signals,'L1') && ...
                    isfield(cfg.signals.L1,'frequency_Hz')
                f_L1 = cfg.signals.L1.frequency_Hz;
            end
            scale = (f_L1 / signal.frequency_Hz)^2;
        end

    end
end

% ============================================================
%  File-scope helper (not accessible from outside)
% ============================================================
function v = getfld_(s, fname, default)
    if isfield(s, fname)
        v = s.(fname);
    else
        v = default;
    end
end
