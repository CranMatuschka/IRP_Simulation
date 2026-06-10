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
        function [rho, contrib] = correctedPseudorange(rx_ecef, tx_ecef, cfg, side)
            % correctedPseudorange  Geometric range plus enabled deterministic corrections.
            %
            % side: 'truth' → use cfg.physics.*.truth.enable flags
            %       'model' → use cfg.physics.*.model.enable flags
            %
            % Returns:
            %   rho     scalar, corrected range [m]
            %   contrib struct with per-correction contributions [m]

            contrib.sagnac  = 0;
            contrib.shapiro = 0;

            rho = revgnss.RangeCorrections.geometricRange(rx_ecef, tx_ecef);

            if isfield(cfg, 'physics')
                ph = cfg.physics;

                % Sagnac
                if isfield(ph, 'sagnac') && isfield(ph.sagnac, side) && ...
                        ph.sagnac.(side).enable
                    dS = revgnss.RangeCorrections.sagnacCorrectionMeters(rx_ecef, tx_ecef, cfg);
                    contrib.sagnac = dS;
                    rho = rho + dS;
                end

                % Shapiro
                if isfield(ph, 'relativity') && isfield(ph.relativity, 'shapiro') && ...
                        isfield(ph.relativity.shapiro, side) && ...
                        ph.relativity.shapiro.(side).enable
                    dSh = revgnss.RangeCorrections.shapiroDelayMeters(rx_ecef, tx_ecef, cfg);
                    contrib.shapiro = dSh;
                    rho = rho + dSh;
                end
            end
        end

    end
end
