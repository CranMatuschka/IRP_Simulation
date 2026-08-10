classdef SignalUtils
    % SignalUtils  Signal / frequency configuration helpers.
    %
    % THE resolver for "what frequency is this run actually using". Every method reads
    % config/masterConfig.m's cfg.signals (as overridden by the scenario JSON) and
    % nothing else. None of them falls back to a canonical L-band constant: a signal the
    % config does not define raises SignalUtils:signalUndefined.
    %
    % Methods:
    %   frequency(cfg,name)          Carrier frequency [Hz] of a named signal
    %   wavelength(cfg,name)         Carrier wavelength [m], c / f
    %   ionoScale(cfg,name,primary)  (f_primary / f_name)^2 dispersive scale
    %   primaryName(cfg)             cfg.signals.primary, defaulting to 'L1'
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
                    error('SignalUtils:signalUndefined', ...
                        ['Signal ''%s'' has no frequency in this config: neither ' ...
                         'cfg.signals.frequencyHz(%d) nor cfg.signals.%s.frequency_Hz ' ...
                         'is set. Define it in config/masterConfig.m -- the only owner ' ...
                         'of a carrier frequency -- or override it from the scenario ' ...
                         'JSON. There is deliberately no canonical-catalogue fallback: ' ...
                         'that fallback is how every rung of config/ladder/freq came to ' ...
                         'report a band it never simulated.'], nm, k, nm);
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
            if isempty(i1) || isempty(i2)
                error('SignalUtils:ionoFreeNeedsTwoSignals', ...
                    ['The ionosphere-free combination needs both L1 and L2 in the ' ...
                     'resolved signal table; found {%s}. A catalogue fallback used to ' ...
                     'fill the missing member with a canonical L-band constant, which ' ...
                     'silently produced GPS alpha/beta for a retuned pair.'], ...
                    strjoin(nmAll, ', '));
            end
            f1 = sigs(i1).frequency_Hz;
            f2 = sigs(i2).frequency_Hz;
            if f1 == f2
                error('SignalUtils:ionoFreeDegeneratePair', ...
                    ['L1 and L2 are both %.6g Hz: the ionosphere-free combination is ' ...
                     'singular for a degenerate pair.'], f1);
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
            % Frequency and wavelength come from the RESOLVED config ONLY. The canonical
            % L-band structs that used to backfill them are gone: config/masterConfig.m is
            % the one owner of a carrier frequency, so a name it does not define is a
            % configuration error rather than something to silently default. An unknown
            % name used to warn and then be handed L1's frequency, which is how a retuned
            % scenario could still be measured at 1575.42 MHz.

            if ~isfield(cfg, 'signals') || ~isfield(cfg.signals, 'enabled')
                enabledNames = {'L1'};
            else
                enabledNames = cfg.signals.enabled;
                if ischar(enabledNames)
                    enabledNames = {enabledNames};
                end
            end

            nSig = numel(enabledNames);
            signals = repmat(struct('name','', 'frequency_Hz',NaN, ...
                                    'lambda_m',NaN, 'codeSigma0_m',NaN), nSig, 1);
            % Code noise floor per signal is NOT frequency-derived -- ranging noise follows
            % chip rate and bandwidth, not carrier frequency -- so these stay literal.
            sigma0Default = struct('L1', 0.30, 'L2', 0.45, 'L5', 0.45);

            for k = 1:nSig
                nm  = enabledNames{k};
                sig = revgnss.SignalUtils.lookupResolved_(cfg, nm);
                key = upper(strtrim(char(nm)));
                s0  = 0.45;
                if isfield(sigma0Default, key); s0 = sigma0Default.(key); end
                if isfield(cfg,'signals') && isfield(cfg.signals, key) && ...
                        isstruct(cfg.signals.(key))
                    s0 = getfld_(cfg.signals.(key), 'codeSigma0_m', s0);
                end
                signals(k) = struct('name',         nm, ...
                                    'frequency_Hz', sig.frequency_Hz, ...
                                    'lambda_m',     sig.wavelength_m, ...
                                    'codeSigma0_m', s0);
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
            %   cfg      struct   simulation config -- the ONLY source of f_L1

            f_L1  = revgnss.SignalUtils.frequency(cfg, 'L1');
            scale = (f_L1 / signal.frequency_Hz)^2;
        end

        % ---- Resolved-band accessors ------------------------------------------------
        % The ONLY sanctioned way to ask "what frequency is signal X in this run".
        % Every one reads the resolved config and nothing else; none has a canonical
        % fallback. revgnss.SignalDefinition used to answer these questions from a
        % second, NAME-keyed copy of the L-band constants, so ~30 call sites measured
        % 1575.42 MHz however the scenario had retuned the band.

        function f = frequency(cfg, name)
            % frequency  Carrier frequency [Hz] of a named signal, from the config.
            f = revgnss.SignalUtils.lookupResolved_(cfg, name).frequency_Hz;
        end

        function lam = wavelength(cfg, name)
            % wavelength  Carrier wavelength [m] of a named signal, c / f.
            lam = revgnss.SignalUtils.lookupResolved_(cfg, name).wavelength_m;
        end

        function nm = primaryName(cfg)
            % primaryName  cfg.signals.primary, defaulting to 'L1'.
            nm = 'L1';
            if isstruct(cfg) && isfield(cfg,'signals') && isfield(cfg.signals,'primary') ...
                    && ischar(cfg.signals.primary) && ~isempty(cfg.signals.primary)
                nm = cfg.signals.primary;
            end
        end

        function scale = ionoScale(cfg, name, primaryName)
            % ionoScale  (f_primary / f_name)^2 -- first-order dispersive scale.
            %   The primary defaults to cfg.signals.primary. For the primary itself this
            %   is exactly 1.0.
            if nargin < 3 || isempty(primaryName)
                primaryName = revgnss.SignalUtils.primaryName(cfg);
            end
            fSig  = revgnss.SignalUtils.frequency(cfg, name);
            fPrim = revgnss.SignalUtils.frequency(cfg, primaryName);
            scale = (fPrim / fSig)^2;
        end

    end

    methods (Static, Access = private)

        function sig = lookupResolved_(cfg, name)
            % lookupResolved_  Resolved (name, frequency, wavelength) or an error.
            nm = upper(strtrim(char(name)));
            if isstruct(cfg) && isfield(cfg,'signals')
                sigs = revgnss.SignalUtils.resolvedSignalTable(cfg);
                idx  = find(strcmpi({sigs.name}, nm), 1);
                if ~isempty(idx)
                    sig = sigs(idx);
                    return
                end
                % Defined in masterConfig but not among the names this scenario resolved
                % (e.g. L2 asked for while running L1-only). Still the config, not a
                % catalogue.
                if isfield(cfg.signals, nm) && isstruct(cfg.signals.(nm)) && ...
                        isfield(cfg.signals.(nm), 'frequency_Hz')
                    f = cfg.signals.(nm).frequency_Hz;
                    if isnumeric(f) && isscalar(f) && isfinite(f) && f > 0
                        sig = struct('name', nm, 'frequency_Hz', f, ...
                            'wavelength_m', revgnss.Constants.SPEED_OF_LIGHT_MPS / f, ...
                            'enabled', false);
                        return
                    end
                end
            end
            error('SignalUtils:signalUndefined', ...
                ['Signal ''%s'' has no frequency in this config. Define ' ...
                 'cfg.signals.%s.frequency_Hz in config/masterConfig.m -- the only ' ...
                 'owner of a carrier frequency -- or override it from the scenario ' ...
                 'JSON. There is deliberately no canonical-catalogue fallback.'], nm, nm);
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
