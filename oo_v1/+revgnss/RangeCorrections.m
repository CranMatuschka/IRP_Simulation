classdef RangeCorrections
    % RangeCorrections  Deterministic pseudorange correction terms.
    %
    % Each method takes rx_ecef [3x1] and tx_ecef [3x1] in metres.
    % cfg must contain cfg.physics (from ConfigFactory.defaultConfig).
    %
    % Sign convention (all corrections ADD to geometric range):
    %   Sagnac:  Earth-rotation path lengthening, positive for forward-rotating signal.
    %   Shapiro: Gravitational path delay, always positive near Earth.
    %
    % Truth corrections affect z (measured pseudorange).
    % Model corrections affect h (predicted pseudorange).
    % If truth=true and model=false, the correction appears as innovation bias.

    methods (Static)

        % ----------------------------------------------------------------
        function rho = geometricRange(rx_ecef, tx_ecef)
            % geometricRange  Euclidean distance between receiver and transmitter.
            rho = norm(rx_ecef(:) - tx_ecef(:));
        end

        % ----------------------------------------------------------------
        function dR = sagnacCorrectionMeters(rx_ecef, tx_ecef, cfg)
            % sagnacCorrectionMeters  First-order Earth-rotation (Sagnac) correction.
            %
            % Signal travel from transmitter (tx, ground tower) to receiver (rx, spacecraft).
            % Standard GNSS Sagnac correction:
            %   dR = (omega / c) * (tx_x * rx_y - tx_y * rx_x)
            %
            % Positive when tx is east of rx in the equatorial plane.
            % This accounts for Earth rotating while the signal is in transit.
            % Do NOT also rotate the tower position if using this correction.
            omega = cfg.physics.omegaEarth_radps;
            c     = cfg.physics.c_mps;
            dR    = (omega / c) * (tx_ecef(1) * rx_ecef(2) - tx_ecef(2) * rx_ecef(1));
        end

        % ----------------------------------------------------------------
        function dR = shapiroDelayMeters(rx_ecef, tx_ecef, cfg)
            % shapiroDelayMeters  General-relativistic Shapiro path delay.
            %
            %   dR = (2 * mu / c^2) * log((rr + rt + R) / (rr + rt - R))
            %
            % rr = |rx|, rt = |tx|, R = geometric range.
            % Denominator is guarded; returns 0 if geometry is degenerate.
            % This is the path-delay relativistic correction only (not clock terms).
            mu = cfg.physics.muEarth_m3ps2;
            c  = cfg.physics.c_mps;
            R  = norm(rx_ecef(:) - tx_ecef(:));
            rr = norm(rx_ecef(:));
            rt = norm(tx_ecef(:));
            denom = rr + rt - R;
            if denom < 1.0  % guard: degenerate geometry (coincident points)
                dR = 0;
                return
            end
            dR = (2 * mu / c^2) * log((rr + rt + R) / denom);
        end

        % ----------------------------------------------------------------
        function [rho, contrib] = correctedPseudorange(rx_ecef, tx_ecef, cfg, side, el_rad)
            % correctedPseudorange  Geometric range plus enabled deterministic corrections.
            %
            % side:   'truth' → cfg.physics.*.truth.enable, cfg.effects.*.truth.enable
            %         'model' → cfg.physics.*.model.enable, cfg.effects.*.model.enable
            % el_rad: elevation angle [rad] for PCV (if omitted, PCV skipped).
            %
            % Light-time: when cfg.effects.lightTime.model='iterative', the effective
            % tower position (tx_ecef_eff) accounts for Earth rotation over tau.
            % Sagnac is NOT also applied in iterative mode to avoid double-correction.

            contrib.sagnac  = 0;
            contrib.shapiro = 0;
            contrib.pcv     = 0;

            % Determine light-time model
            ltModel = 'sagnacFirstOrder';
            if isfield(cfg,'effects') && isfield(cfg.effects,'lightTime') && ...
                    isfield(cfg.effects.lightTime,'model')
                ltModel = cfg.effects.lightTime.model;
            end

            % Apply light-time iteration when requested (model side only; truth uses same)
            tx_ecef_eff = tx_ecef;
            if strcmp(ltModel,'iterative')
                [tx_ecef_eff, ~] = revgnss.LightTimeSolver.solve(rx_ecef, tx_ecef, cfg);
            end

            rho = revgnss.RangeCorrections.geometricRange(rx_ecef, tx_ecef_eff);

            if isfield(cfg, 'physics')
                ph = cfg.physics;

                % Sagnac (skip when iterative mode handles it via rotation)
                if ~strcmp(ltModel,'iterative') && ...
                        isfield(ph, 'sagnac') && isfield(ph.sagnac, side) && ...
                        ph.sagnac.(side).enable
                    dS = revgnss.RangeCorrections.sagnacCorrectionMeters(rx_ecef, tx_ecef_eff, cfg);
                    contrib.sagnac = dS;
                    rho = rho + dS;
                end

                % Shapiro
                if isfield(ph, 'relativity') && isfield(ph.relativity, 'shapiro') && ...
                        isfield(ph.relativity.shapiro, side) && ...
                        ph.relativity.shapiro.(side).enable
                    dSh = revgnss.RangeCorrections.shapiroDelayMeters(rx_ecef, tx_ecef_eff, cfg);
                    contrib.shapiro = dSh;
                    rho = rho + dSh;
                end
            end

            % PCV correction: 'toy', 'table', or 'none'
            % Legacy cfg.effects.antennaPCV.(side).enable preserved.
            if nargin >= 5 && ~isempty(el_rad)
                dPCV = revgnss.RangeCorrections.pcvCorrection_(el_rad, cfg, side);
                contrib.pcv = dPCV;
                rho = rho + dPCV;
            end
        end

    end

    methods (Static, Access = private)

        % ----------------------------------------------------------------
        function dPCV = pcvCorrection_(el_rad, cfg, side)
            % pcvCorrection_  PCV range correction in metres.
            %
            % Selects model via cfg.effects.antenna.pcvModel:
            %   'none'  → 0
            %   'toy'   → amplitude * cos(el)^2  (legacy toyAzEl)
            %   'table' → 1D table interpolation on elevation

            dPCV = 0;

            % Determine pcvModel: new style takes priority
            pcvModel = 'toy';   % default: preserve legacy behavior
            if isfield(cfg,'effects') && isfield(cfg.effects,'antenna') && ...
                    isfield(cfg.effects.antenna,'pcvModel')
                pcvModel = cfg.effects.antenna.pcvModel;
            end

            % Legacy on/off gate still respected
            pcvEnabled = false;
            if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCV') && ...
                    isfield(cfg.effects.antennaPCV, side)
                pcvEnabled = cfg.effects.antennaPCV.(side).enable;
            end
            if ~pcvEnabled; return; end

            switch pcvModel
                case 'none'
                    dPCV = 0;

                case 'toy'
                    amp  = 0.005;
                    if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCV') && ...
                            isfield(cfg.effects.antennaPCV,'amplitude_m')
                        amp = cfg.effects.antennaPCV.amplitude_m;
                    end
                    dPCV = amp * cos(el_rad)^2;

                case 'table'
                    if ~isfield(cfg,'effects') || ~isfield(cfg.effects,'antenna') || ...
                            ~isfield(cfg.effects.antenna,'receiverPcvTable')
                        dPCV = 0; return;
                    end
                    tbl = cfg.effects.antenna.receiverPcvTable;
                    if ~isfield(tbl,'elDeg') || ~isfield(tbl,'pcv_m')
                        dPCV = 0; return;
                    end
                    elDeg = rad2deg(el_rad);
                    elDeg = max(tbl.elDeg(1), min(tbl.elDeg(end), elDeg));
                    dPCV  = interp1(tbl.elDeg, tbl.pcv_m, elDeg, 'linear', 'extrap');

                otherwise
                    dPCV = 0;
            end
        end

    end
end
