classdef SignalDefinition
    % SignalDefinition  Centralised GPS L-band signal frequency metadata.
    %
    % Standard GPS L-band frequencies (ITU-R M.1787):
    %   L1 = 1575.42 MHz
    %   L2 = 1227.60 MHz
    %   L5 = 1176.45 MHz
    %
    % Usage:
    %   sig   = revgnss.SignalDefinition.get('L1')
    %   sigs  = revgnss.SignalDefinition.list({'L1','L2'})
    %   lam   = revgnss.SignalDefinition.wavelength('L1')
    %   scale = revgnss.SignalDefinition.ionoScale('L2','L1')
    %
    % Fields returned by get():
    %   name                   string   signal label, e.g. 'L1'
    %   frequency_Hz           double   carrier frequency [Hz]
    %   wavelength_m           double   c / frequency [m]
    %   ionoScaleRelativeToL1  double   (f_L1/f)^2 — iono delay scale vs L1

    methods (Static)

        function sig = get(name)
            % get  Signal metadata struct for the named GPS signal.
            sig = revgnss.SignalDefinition.lookup_(upper(strtrim(name)));
        end

        function sigs = list(names)
            % list  Struct array for a cell array of signal names.
            if ischar(names); names = {names}; end
            sigs = cellfun(@(n) revgnss.SignalDefinition.get(n), names);
        end

        function lam = wavelength(name)
            % wavelength  Wavelength [m] for the named signal.
            lam = revgnss.SignalDefinition.get(name).wavelength_m;
        end

        function scale = ionoScale(name, primaryName)
            % ionoScale  Return (f_primary / f_signal)^2.
            %
            % First-order iono delay on frequency f relative to primary p:
            %   I_f = I_p * (f_p / f)^2
            %
            % For code (group delay):   scale is positive multiplier on I_primary.
            % For carrier (phase adv.): same scale, applied with opposite sign.
            sig  = revgnss.SignalDefinition.get(name);
            prim = revgnss.SignalDefinition.get(primaryName);
            scale = (prim.frequency_Hz / sig.frequency_Hz)^2;
        end

        % ---- Experiment-only carrier-frequency override -------------------
        % These let a study (e.g. the GEO uplink frequency battery) replace the
        % canonical L-band carriers with arbitrary frequencies. The override is a
        % PROCESS-LOCAL persistent value that DEFAULTS EMPTY, so with no call the
        % class returns exactly the canonical ITU-R M.1787 numbers and the frozen
        % goldens stay byte-identical. Because ConfigFactory.finalizeConfig and the
        % physics fall-backs all funnel through get()/lookup_, one override
        % propagates consistently to the iono scaling, carrier wavelength and IF
        % diagnostics. Callers MUST clear it in a finally.

        function setFrequencyOverride(overrideHz)
            % setFrequencyOverride  Override carrier frequencies [Hz].
            %   overrideHz: struct with any of fields L1/L2/L5 in Hz, e.g.
            %   struct('L1',5.0e9,'L2',2.1e9). Persists until clearFrequencyOverride.
            if ~isstruct(overrideHz)
                error('SignalDefinition:badOverride', ...
                    'overrideHz must be a struct of Hz values (fields L1/L2/L5).');
            end
            revgnss.SignalDefinition.frequencyOverrideHz_(overrideHz);
        end

        function setFrequencyOverrideGHz(l1GHz, l2GHz)
            % setFrequencyOverrideGHz  Convenience: set the L1/L2 pair in GHz.
            revgnss.SignalDefinition.setFrequencyOverride( ...
                struct('L1', l1GHz*1e9, 'L2', l2GHz*1e9));
        end

        function clearFrequencyOverride()
            % clearFrequencyOverride  Restore the canonical L-band frequencies.
            revgnss.SignalDefinition.frequencyOverrideHz_('clear');
        end

        function ov = getFrequencyOverride()
            % getFrequencyOverride  Current override struct ([] if none).
            ov = revgnss.SignalDefinition.frequencyOverrideHz_();
        end

    end

    methods (Static, Access = private)

        function ov = frequencyOverrideHz_(newVal)
            % frequencyOverrideHz_  Process-local persistent store for the override.
            %   Pass 'clear' to reset; pass a struct to set; no arg to read.
            persistent OV_;
            if nargin >= 1
                if (ischar(newVal) || isstring(newVal)) && strcmp(char(newVal),'clear')
                    OV_ = [];
                else
                    OV_ = newVal;
                end
            end
            ov = OV_;
        end

        function sig = lookup_(nm)
            c   = 299792458;      % speed of light [m/s]
            % Canonical L-band carriers (ITU-R M.1787). Frozen-golden defaults.
            fL1 = 1575.42e6;
            switch nm
                case 'L1'; f = fL1;
                case 'L2'; f = 1227.60e6;
                case 'L5'; f = 1176.45e6;
                otherwise
                    error('SignalDefinition:unknownSignal', ...
                        'Unknown signal ''%s''. Supported: L1, L2, L5.', nm);
            end
            % Optional experiment-only override (default empty -> byte-identical to
            % the canonical values above). Applied to BOTH the requested signal and
            % the L1 iono reference so ionoScaleRelativeToL1 stays self-consistent
            % (for L1 with no override this is exactly 1.0, as before).
            ov = revgnss.SignalDefinition.frequencyOverrideHz_();
            if ~isempty(ov)
                if isfield(ov,'L1'); fL1 = ov.L1; end
                if isfield(ov,nm);   f   = ov.(nm); end
            end
            sig = struct('name', nm, ...
                         'frequency_Hz', f, ...
                         'wavelength_m', c/f, ...
                         'ionoScaleRelativeToL1', (fL1/f)^2);
        end

    end
end
