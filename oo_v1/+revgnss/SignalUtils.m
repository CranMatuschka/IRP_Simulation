classdef SignalUtils
    % SignalUtils  Signal / frequency configuration helpers.
    %
    % Methods:
    %   getEnabledSignals            Return struct array of enabled signals from cfg
    %   getFrequencyScaleToL1        Return (f_L1 / f_sig)^2 scale factor
    %   resolvedSignalTable          Full catalogue carrying the RESOLVED band
    %   ionosphereFreeCoefficients   IF alpha/beta for the resolved L1/L2 pair

    methods (Static)

        function sigs = resolvedSignalTable(cfg)
            % resolvedSignalTable  Full signal catalogue carrying the RESOLVED band.
            %
            % Returns a 1xN struct array with fields:
            %   name          char     catalogue label, e.g. 'L1'
            %   frequency_Hz  double   carrier frequency the run actually used [Hz]
            %   wavelength_m  double   c / frequency_Hz [m]
            %   enabled       logical  cfg.signals.enabledMask entry
            %
            % SignalDefinition is keyed by NAME, so get('L1') returns the canonical
            % 1575.42 MHz however the scenario retuned the band. The report layer read
            % it directly and therefore printed L-band physics for every rung of the
            % licence-exempt frequency ladder -- freq013 runs at 61.25/24.125 GHz and
            % still reported the GPS IF coefficients.
            %
            % ConfigFactory.finalizeConfig's cfg.signals.frequencyHz / .wavelength_m ARE
            % the resolved arrays: they fold in both the JSON-owned
            % signals.<name>.frequency_Hz and SignalDefinition's process-local override.
            % Prefer them, fall back to the per-signal alias, and only then to the
            % catalogue -- the last case covers a cfg that never went through
            % finalizeConfig (the LatexReportBuilder unit tests build such structs).
            %
            % GOLDEN-SAFE: with no scenario retune the resolved arrays hold exactly the
            % canonical doubles, and wavelength_m is c/f in both paths, so every field
            % comes out bit-identical to reading SignalDefinition directly.
            if nargin < 1 || isempty(cfg) || ~isstruct(cfg); cfg = struct(); end
            hasSignals = isfield(cfg,'signals') && isstruct(cfg.signals);

            names = {'L1'};
            if hasSignals && isfield(cfg.signals,'names') && ~isempty(cfg.signals.names)
                names = cfg.signals.names;
                if ischar(names); names = {names}; end
            end
            nSig = numel(names);

            freqs = [];
            if hasSignals && isfield(cfg.signals,'frequencyHz') && isnumeric(cfg.signals.frequencyHz)
                freqs = cfg.signals.frequencyHz(:).';
            end
            waves = [];
            if hasSignals && isfield(cfg.signals,'wavelength_m') && isnumeric(cfg.signals.wavelength_m)
                waves = cfg.signals.wavelength_m(:).';
            end
            mask = true(1,nSig);
            if hasSignals && isfield(cfg.signals,'enabledMask') ...
                    && numel(cfg.signals.enabledMask) == nSig
                mask = logical(cfg.signals.enabledMask(:).');
            end

            sigs = repmat(struct('name','', 'frequency_Hz',NaN, ...
                                 'wavelength_m',NaN, 'enabled',false), 1, nSig);
            for k = 1:nSig
                nm = names{k};
                f  = [];
                if numel(freqs) >= k && isfinite(freqs(k)) && freqs(k) > 0
                    f = freqs(k);
                elseif hasSignals && isfield(cfg.signals, nm) && isstruct(cfg.signals.(nm)) ...
                        && isfield(cfg.signals.(nm), 'frequency_Hz')
                    fAlias = cfg.signals.(nm).frequency_Hz;
                    if isnumeric(fAlias) && isscalar(fAlias) && isfinite(fAlias) && fAlias > 0
                        f = fAlias;
                    end
                end
                if isempty(f)
                    f = revgnss.SignalDefinition.get(nm).frequency_Hz;
                end
                lam = [];
                if numel(waves) >= k && isfinite(waves(k)) && waves(k) > 0
                    lam = waves(k);
                end
                if isempty(lam)
                    lam = 299792458 / f;      % c [m/s], as SignalDefinition
                end
                sigs(k) = struct('name', nm, 'frequency_Hz', f, ...
                                 'wavelength_m', lam, 'enabled', mask(k));
            end
        end

        function [alpha, beta, f1, f2] = ionosphereFreeCoefficients(cfg)
            % ionosphereFreeCoefficients  IF code coefficients for the RESOLVED L1/L2 pair.
            %
            %   P_IF = alpha*P_L1 + beta*P_L2
            %   alpha = f1^2 / (f1^2 - f2^2),   beta = -f2^2 / (f1^2 - f2^2)
            %
            % f1/f2 are the frequencies the run actually used, not the canonical L-band
            % constants: a report built straight off SignalDefinition printed
            % alpha = 2.5457 for EVERY rung of config/ladder/freq, including freq013's
            % 61.25/24.125 GHz pair whose true alpha is 1.1836.
            %
            % A catalogue without an L1 or L2 entry falls back to the canonical value for
            % the missing member, which is what the direct SignalDefinition reads did.
            if nargin < 1; cfg = struct(); end
            sigs = revgnss.SignalUtils.resolvedSignalTable(cfg);
            nmAll = {sigs.name};
            i1 = find(strcmpi(nmAll, 'L1'), 1);
            i2 = find(strcmpi(nmAll, 'L2'), 1);
            if isempty(i1)
                f1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
            else
                f1 = sigs(i1).frequency_Hz;
            end
            if isempty(i2)
                f2 = revgnss.SignalDefinition.get('L2').frequency_Hz;
            else
                f2 = sigs(i2).frequency_Hz;
            end
            alpha =  f1^2 / (f1^2 - f2^2);
            beta  = -f2^2 / (f1^2 - f2^2);
        end

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
            % buildClockOnlyH  Clock-only design matrix for gauge-mode test.
            %
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
