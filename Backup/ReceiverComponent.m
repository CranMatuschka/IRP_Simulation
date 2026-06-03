classdef ReceiverComponent < handle
    %RECEIVERCOMPONENT Geometric spacecraft receiver phase-center only.
    %
    % This class intentionally contains no clock, no RF delay, no hardware
    % state, no receiver bias, and no process model.
    %
    % The only physical input is offsetBody_m.

    properties
        id = 1
        name = "RX-1"
        enabled = true

        % Receiver phase-center offset relative to spacecraft center of mass.
        % Expressed in spacecraft body frame, meters.
        offsetBody_m = zeros(3, 1)

        % Optional code/pseudorange standard deviation for this receiver phase
        % center. Used by MeasurementModel when building R.
        pseudorangeSigma_m = 0.0
    end

    methods
        function obj = ReceiverComponent(varargin)
            if nargin == 0
                return;
            end

            if nargin == 1 && isstruct(varargin{1})
                cfg = varargin{1};

                if isfield(cfg, "id")
                    obj.id = cfg.id;
                end
                if isfield(cfg, "name")
                    obj.name = string(cfg.name);
                end
                if isfield(cfg, "enabled")
                    obj.enabled = logical(cfg.enabled);
                end
                if isfield(cfg, "offsetBody_m")
                    obj.offsetBody_m = cfg.offsetBody_m(:);
                elseif isfield(cfg, "antennaOffsetBody_m")
                    obj.offsetBody_m = cfg.antennaOffsetBody_m(:);
                end
                if isfield(cfg, "pseudorangeSigma_m")
                    obj.pseudorangeSigma_m = cfg.pseudorangeSigma_m;
                elseif isfield(cfg, "measurementSigma_m")
                    obj.pseudorangeSigma_m = cfg.measurementSigma_m;
                end

                obj.validate();
                return;
            end

            if nargin >= 1
                obj.offsetBody_m = varargin{1}(:);
            end
            if nargin >= 2
                obj.name = string(varargin{2});
            end
            if nargin >= 3
                obj.id = varargin{3};
            end

            obj.validate();
        end
%%
        function offset = getOffsetBody_m(obj)
            offset = obj.offsetBody_m(:);
        end
%%
        function validate(obj)
            if ~isnumeric(obj.offsetBody_m) || numel(obj.offsetBody_m) ~= 3 || any(~isfinite(obj.offsetBody_m(:)))
                error('ReceiverComponent:InvalidOffset', ...
                    'offsetBody_m must be a finite 3-element numeric vector.');
            end

            obj.offsetBody_m = obj.offsetBody_m(:);
            obj.name = string(obj.name);
            obj.enabled = logical(obj.enabled);
            if ~isnumeric(obj.pseudorangeSigma_m) || ~isscalar(obj.pseudorangeSigma_m) || ~isfinite(obj.pseudorangeSigma_m) || obj.pseudorangeSigma_m < 0
                error('ReceiverComponent:InvalidSigma', 'pseudorangeSigma_m must be a finite non-negative scalar.');
            end
        end
    end
end