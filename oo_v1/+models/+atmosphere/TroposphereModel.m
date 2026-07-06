classdef TroposphereModel
    % TroposphereModel  Centralized troposphere/ZWD architecture metadata.
    %
    % Responsibilities:
    %   - Classify troposphere mode from config
    %   - Expose dry/wet truth/model enable status
    %   - Report ZWD EKF state status
    %   - Provide elevation-to-mapping wrapper
    %   - Produce identifiability note for weak-elevation scenarios
    %
    % Does NOT implement PPP-grade models (VMF3, GPT3, ERA5, IONEX).
    % Uses the simple or continued-fraction mapping already in MappingFunctions.

    methods (Static)

        function s = describe(cfg, stateMap)
            % describe  Return struct summarising troposphere/ZWD architecture.
            %
            % Fields:
            %   truthEnabled   — cfg.errors.troposphere.truth.enable
            %   modelEnabled   — cfg.errors.troposphere.model.enable
            %   zwdEstimated   — true when perTowerZwd state is active
            %   nZwdStates     — number of ZWD states (0 if disabled)
            %   mappingKind    — 'simple' | 'continuedFraction'
            %   mode           — 'disabled' | 'truthOnly' | 'modelOnly' |
            %                    'matched' | 'zwdEkf'
            %   note           — human-readable summary string

            if nargin < 2; stateMap = struct(); end

            s.truthEnabled = models.atmosphere.TroposphereModel.getLogical_( ...
                cfg, {'errors','troposphere','truth','enable'}, false);
            s.modelEnabled = models.atmosphere.TroposphereModel.getLogical_( ...
                cfg, {'errors','troposphere','model','enable'}, false);
            s.zwdEstimated = models.atmosphere.TroposphereModel.isZwdEstimated(cfg, stateMap);
            s.nZwdStates   = models.atmosphere.TroposphereModel.nZwdStates_(cfg, stateMap);
            s.mappingKind  = revgnss.MeasurementModelUtils.zwdMappingKind(cfg);

            if s.zwdEstimated
                s.mode = 'zwdEkf';
            elseif s.truthEnabled && s.modelEnabled
                s.mode = 'matched';
            elseif s.truthEnabled && ~s.modelEnabled
                s.mode = 'truthOnly';
            elseif ~s.truthEnabled && s.modelEnabled
                s.mode = 'modelOnly';
            else
                s.mode = 'disabled';
            end

            s.note = models.atmosphere.TroposphereModel.modeNote_(s);
        end

        function mf = mapping(elevation_rad, cfg)
            % mapping  Troposphere mapping factor at given elevation.
            %
            % Wrapper around MappingFunctions.troposphere using the configured kind.
            % elevation_rad: scalar or array of elevation angles [rad]
            % Returns mapping factor (dimensionless, >= 1 for el in (0, pi/2]).
            if nargin < 2; cfg = struct(); end
            kind = revgnss.MeasurementModelUtils.zwdMappingKind(cfg);
            mf   = revgnss.MappingFunctions.troposphere(elevation_rad, kind);
        end

        function flag = isZwdEstimated(cfg, stateMap)
            % isZwdEstimated  True when perTowerZwd EKF state is active.
            if nargin < 2; stateMap = struct(); end
            byMode = isfield(cfg,'estimation') && ...
                     isfield(cfg.estimation,'troposphereMode') && ...
                     strcmp(cfg.estimation.troposphereMode,'perTowerZwd');
            bySM   = isfield(stateMap,'zwdIdx') && any(stateMap.zwdIdx > 0);
            flag   = byMode || bySM;
        end

        function [pSig, tauS, initSig] = zwdProcessParams(cfg)
            % zwdProcessParams  Return ZWD Gauss-Markov process parameters.
            %
            % Returns:
            %   pSig    — steady-state sigma [m]
            %   tauS    — correlation time [s]
            %   initSig — initial 1-sigma [m]
            pSig    = 0.05;
            tauS    = 3600;
            initSig = 0.10;
            if isfield(cfg,'estimation') && isfield(cfg.estimation,'tropoZwd')
                tz = cfg.estimation.tropoZwd;
                if isfield(tz,'sigma_ss_m');     pSig    = tz.sigma_ss_m;     end
                if isfield(tz,'tau_s');           tauS    = tz.tau_s;          end
                if isfield(tz,'initialSigma_m'); initSig = tz.initialSigma_m; end
            end
        end

        function note = weakObservabilityNote(elevations_rad)
            % weakObservabilityNote  Return warning string if elevation diversity is low.
            %
            % ZWD is correlated with receiver clock, tower clock, and range bias
            % when all towers are at similar (high or low) elevations.
            % Returns empty string if diversity is adequate.
            note = '';
            if isempty(elevations_rad); return; end
            el = elevations_rad(~isnan(elevations_rad) & isfinite(elevations_rad));
            if numel(el) < 2; return; end
            el_deg = rad2deg(el);
            if range(el_deg) < 15
                note = ['ZWD is weakly observable: elevation range = ' ...
                    sprintf('%.0f', range(el_deg)) ...
                    ' deg < 15 deg. ZWD may be absorbed by clock/range bias.'];
            end
        end

    end

    % ------------------------------------------------------------------
    % Private helpers
    % ------------------------------------------------------------------
    methods (Static, Access = private)

        function v = getLogical_(cfg, fields, dflt)
            v = dflt;
            s = cfg;
            for k = 1:numel(fields)
                if ~isstruct(s) || ~isfield(s, fields{k}); return; end
                s = s.(fields{k});
            end
            v = logical(s);
        end

        function n = nZwdStates_(cfg, stateMap)
            if isfield(stateMap,'zwdIdx')
                n = sum(stateMap.zwdIdx > 0);
            elseif isfield(cfg,'estimation') && ...
                    isfield(cfg.estimation,'troposphereMode') && ...
                    strcmp(cfg.estimation.troposphereMode,'perTowerZwd') && ...
                    isfield(cfg,'nTowers')
                n = cfg.nTowers;
            else
                n = 0;
            end
        end

        function note = modeNote_(s)
            switch s.mode
                case 'disabled'
                    note = 'Troposphere disabled. No truth delay, no model correction, no ZWD state.';
                case 'truthOnly'
                    note = 'Troposphere truth applied but not modelled. Truth-model mismatch drives residual range error.';
                case 'modelOnly'
                    note = 'Troposphere correction applied without matching truth error. May over-correct.';
                case 'matched'
                    note = 'Troposphere truth and model matched. Net troposphere contribution to innovation is near zero.';
                case 'zwdEkf'
                    note = ['ZWD EKF state active (' ...
                        num2str(s.nZwdStates) ' state(s)). ' ...
                        'Residual wet delay estimated at zenith and mapped by ' ...
                        s.mappingKind ' function. Correlated with clock and range bias.'];
                otherwise
                    note = '';
            end
        end

    end
end
