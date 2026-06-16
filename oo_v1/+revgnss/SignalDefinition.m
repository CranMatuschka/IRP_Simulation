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

    end

    methods (Static, Access = private)

        function sig = lookup_(nm)
            c   = 299792458;      % speed of light [m/s]
            fL1 = 1575.42e6;
            switch nm
                case 'L1'
                    f   = fL1;
                    sig = struct('name','L1', ...
                                 'frequency_Hz', f, ...
                                 'wavelength_m', c/f, ...
                                 'ionoScaleRelativeToL1', 1.0);
                case 'L2'
                    f   = 1227.60e6;
                    sig = struct('name','L2', ...
                                 'frequency_Hz', f, ...
                                 'wavelength_m', c/f, ...
                                 'ionoScaleRelativeToL1', (fL1/f)^2);
                case 'L5'
                    f   = 1176.45e6;
                    sig = struct('name','L5', ...
                                 'frequency_Hz', f, ...
                                 'wavelength_m', c/f, ...
                                 'ionoScaleRelativeToL1', (fL1/f)^2);
                otherwise
                    error('SignalDefinition:unknownSignal', ...
                        'Unknown signal ''%s''. Supported: L1, L2, L5.', nm);
            end
        end

    end
end
