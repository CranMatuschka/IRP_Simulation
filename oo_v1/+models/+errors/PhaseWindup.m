classdef PhaseWindup
    % PhaseWindup  Wu et al. (1993) carrier phase wind-up, in cycles.
    %
    % Wu J.T., Wu S.C., Hajj G.A., Bertiger W.I., Lichten S.M. (1993),
    % "Effects of antenna orientation on GPS carrier phase", Manuscripta
    % Geodaetica 18(2), 91-98.
    %
    % THE PHYSICS. A circularly polarised wave carries a phase that depends on the
    % relative rotation of the transmit and receive antennas ABOUT THE LINE OF SIGHT.
    % One full relative revolution shifts the carrier by exactly one cycle. It is a
    % pure geometry term: no randomness, no frequency dependence. The shift is the
    % same NUMBER OF CYCLES on every signal, which is why it must be carried in cycles
    % and converted to metres with each signal's own wavelength at the point of use.
    % Code is unaffected -- wind-up is a phase rotation, not a delay.
    %
    % ROLES ARE INVERTED HERE. This is a REVERSE-GNSS simulation: the GROUND TOWER
    % TRANSMITS and the SPACECRAFT RECEIVES. So the transmit dipole is fixed in ECEF
    % and the receive dipole is carried by the spacecraft attitude. Wind-up is
    % therefore driven by the SPACECRAFT ATTITUDE, the opposite of the classical GNSS
    % case where it is driven by the satellite's yaw-steering law.
    %
    % =====================  AXIS CONVENTION -- THE SIGN DEPENDS ON IT  =============
    % TRANSMIT (ground tower), from towerAxesEcef():
    %     x_t = local EAST   (ENU column 1)
    %     y_t = local NORTH  (ENU column 2)
    %   Nothing in this repo declares a physical tower antenna orientation, so this is
    %   a STATED CHOICE, not a measured one. It is the simplest defensible convention
    %   and it is fixed in ECEF, which is what matters: any other choice of the
    %   tower's dipole reference rotates every epoch's wind-up on that link by the
    %   SAME constant, and a constant per link is absorbed by the carrier ambiguity.
    %   The convention therefore fixes the SIGN and the OFFSET, never the VARIATION,
    %   and the variation is the only part that can reach the estimate.
    %
    % RECEIVE (spacecraft), from spacecraftAxesEcef():
    %     x_r = body +X in ECEF (C(:,1)) -- along-track for the nadir-pointing default
    %     y_r = body +Y in ECEF (C(:,2)) -- minus orbit normal for that default
    %   Body +Z is the antenna boresight and points at nadir
    %   (cfg.asset.boresight_body = [0;0;1], revgnss.AttitudeKinematics.nadirEulerFromEcef),
    %   so the dipole pair is the body X-Y plane, i.e. the antenna face.
    %   All receive antennas on one spacecraft share ONE attitude -- SpaceAsset.
    %   getAntennaPositionsECEF varies the LEVER ARM per antenna and nothing else --
    %   so x_r/y_r are identical for every phase centre. See the cancellation note below.
    % ==============================================================================
    %
    % WHAT THIS TERM CAN AND CANNOT REACH, stated before it is measured. The att
    % ladder's observable is an INTER-ANTENNA SINGLE DIFFERENCE at one tower
    % (revgnss.DiffAttitudeBuilder: z_row = phi_i - phi_ref, both rows the same tower).
    % Wind-up depends on the tower dipole (common to both rows), the spacecraft dipole
    % (common -- one attitude for all antennas) and the unit line of sight k, which is
    % the ONLY per-antenna quantity. At GEO a ~1 m lever arm over a ~36 000 km range
    % turns k by ~3e-8 rad, so the inter-antenna difference of the wind-up is of order
    % 1e-9 cycles. Wind-up therefore CANCELS in the attitude observable, and it cancels
    % at the FIRST difference -- before the between-tower double difference ever runs.
    % It survives only on the UNDIFFERENCED carrier rows, which serve position and clock.
    %
    % It does NOT cancel in the ionosphere-free combination. IF is a metres-weighted
    % sum (alpha*L1 + beta*L2 with alpha+beta = 1), and a wind-up of W cycles is
    % W*lambda1 metres on L1 and W*lambda2 on L2, so the combination retains
    % W*(alpha*lambda1 + beta*lambda2) = W*c/(f1+f2), the NARROW-LANE wavelength
    % (106.95 mm at L1/L2, i.e. 56 % of raw L1). It DOES cancel exactly in the
    % wide-lane N1 - N2, where the identical cycle count on both signals subtracts away.
    %
    % ACCUMULATION. fractionalCycles() returns a value in [-0.5, 0.5] -- a raw arccos
    % and nothing more. Never integrate that directly: use accumulate() to carry cycle
    % continuity across epochs, exactly as a real receiver's phase tracking loop does.
    % This class holds NO state; the per-link accumulator lives in
    % models.errors.ErrorChain so that it is rebuilt with the run and cannot leak
    % between scenarios in one MATLAB session.

    methods (Static)

        function [x_t, y_t] = towerAxesEcef(lat_rad, lon_rad)
            % towerAxesEcef  Transmit dipole axes in ECEF: local East, local North.
            %
            % See the AXIS CONVENTION block in the class docstring -- this is a stated
            % choice, and the sign of the wind-up follows from it.
            R   = models.frames.GeometryUtils.enu2ecef(lat_rad, lon_rad);
            x_t = R(:, 1);   % East
            y_t = R(:, 2);   % North
        end

        function [x_r, y_r] = spacecraftAxesEcef(C_ecef_body)
            % spacecraftAxesEcef  Receive dipole axes in ECEF from the body-to-ECEF DCM.
            %
            % C_ecef_body columns are the body axes expressed in ECEF
            % (revgnss.AttitudeKinematics.bodyToEcefRotation). Body +Z is the boresight,
            % so the dipole pair is body +X / +Y.
            x_r = C_ecef_body(:, 1);
            y_r = C_ecef_body(:, 2);
        end

        function w_cycles = fractionalCycles(r_tx_ecef, r_rx_ecef, x_t, y_t, x_r, y_r)
            % fractionalCycles  Wu-1993 wind-up angle for one link, in cycles.
            %
            %   r_tx_ecef  [3x1] TRANSMITTER position (ground tower antenna) [m]
            %   r_rx_ecef  [3x1] RECEIVER position (spacecraft phase centre) [m]
            %   x_t, y_t   [3x1] transmit dipole axes in ECEF
            %   x_r, y_r   [3x1] receive dipole axes in ECEF
            %
            % Returns a scalar double in [-0.5, 0.5] cycles. This is the RAW arccos:
            % it is discontinuous across a half-cycle boundary by construction. Feed it
            % to accumulate() before using it as a phase.
            %
            %   k   = unit(r_rx - r_tx)                 transmitter -> receiver
            %   D_t = x_t - k (k . x_t) - k x y_t       effective transmit dipole
            %   D_r = x_r - k (k . x_r) + k x y_r       effective receive dipole
            %   dphi = sign(k . (D_t x D_r)) * acos( (D_t . D_r) / (|D_t| |D_r|) )
            w_cycles = 0;
            k = r_rx_ecef(:) - r_tx_ecef(:);
            nk = norm(k);
            if ~isfinite(nk) || nk <= 0; return; end
            k = k / nk;

            D_t = x_t(:) - k * (k' * x_t(:)) - cross(k, y_t(:));
            D_r = x_r(:) - k * (k' * x_r(:)) + cross(k, y_r(:));

            nt = norm(D_t); nr = norm(D_r);
            % Degenerate only if the line of sight is parallel to the dipole plane's
            % normal in a way that collapses the effective dipole. It cannot happen for
            % a ground tower looking at GEO, but a zero-length D would make the arccos
            % argument NaN and a single NaN in z_phi silently deletes dozens of metrics
            % from the regression gate. Refuse to emit one.
            if ~isfinite(nt) || ~isfinite(nr) || nt < 1e-12 || nr < 1e-12; return; end

            c = (D_t' * D_r) / (nt * nr);
            c = max(-1, min(1, c));                  % arccos domain guard
            dphi = acos(c);
            s = k' * cross(D_t, D_r);
            if s < 0; dphi = -dphi; end

            w_cycles = dphi / (2*pi);
            if ~isfinite(w_cycles); w_cycles = 0; end
        end

        function dW = attitudeJacobianCycles(r_tx_ecef, r_rx_ecef, x_t, y_t, ...
                C_ecef_body, euler_rad, step_rad, useQuaternionErrorState)
            % attitudeJacobianCycles  d(wind-up)/d(attitude), 1x3, in cycles per radian.
            %
            % WHY THIS EXISTS. Once the estimator-side correction is on, h depends on the
            % estimated attitude through wind-up. An h carrying a dependence its H omits
            % is the inconsistent-triple defect this repo has on record elsewhere: the
            % residual responds to the state, the filter is told it does not, and moving
            % the state cannot shrink the residual. This closes it.
            %
            % It is also the ONLY route by which wind-up could add attitude information.
            % The sensitivity is a rotation ABOUT THE LINE OF SIGHT -- exactly the third
            % axis the differenced-carrier geometry is weak on by ~1/sin(10 deg) -- at a
            % flat 1 cycle per relative revolution, i.e. 1/(2*pi) cycles/rad on that axis
            % and ~0 on the two transverse ones. Whether that is enough to matter against
            % the geometric partial is a measurement, not an assumption.
            %
            % Perturbation matches revgnss.LinkGeometry.finiteDiffAttitudeJacobian exactly
            % so the two columns of H are differentiated with respect to the SAME
            % parameter: body-frame Exp([dtheta]_x) under quaternionErrorState, Euler
            % angles otherwise.
            %
            % STATELESS BY CONSTRUCTION. It differences fractionalCycles, never the
            % accumulator: stepping the accumulator at a fictitious perturbed attitude
            % would corrupt the continuation for every later epoch. The accumulated value
            % and the fractional one differ locally by an integer, so their derivatives
            % agree; the round() below is what keeps that true if a perturbation straddles
            % a half-cycle boundary.
            %
            % r_rx_ecef is held FIXED across the perturbation. The receive position does
            % move with attitude through the lever arm, but at GEO a metre-class lever
            % turns the line of sight by ~3e-8 rad against a dipole rotation of `step_rad`
            % itself, so that path is ~7 orders below the one modelled here.
            dW = zeros(1, 3);
            if nargin < 7 || isempty(step_rad); step_rad = 1e-6; end
            if nargin < 8 || isempty(useQuaternionErrorState); useQuaternionErrorState = true; end
            for ke = 1:3
                dp = zeros(3,1); dp(ke) =  step_rad;
                dm = zeros(3,1); dm(ke) = -step_rad;
                if useQuaternionErrorState
                    Cp = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(C_ecef_body, dp);
                    Cm = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(C_ecef_body, dm);
                else
                    ep = euler_rad(:) + dp;
                    em = euler_rad(:) + dm;
                    Cp = revgnss.AttitudeKinematics.bodyToEcefRotation(ep);
                    Cm = revgnss.AttitudeKinematics.bodyToEcefRotation(em);
                end
                wp = models.errors.PhaseWindup.fractionalCycles(r_tx_ecef, r_rx_ecef, ...
                    x_t, y_t, Cp(:,1), Cp(:,2));
                wm = models.errors.PhaseWindup.fractionalCycles(r_tx_ecef, r_rx_ecef, ...
                    x_t, y_t, Cm(:,1), Cm(:,2));
                d = wp - wm;
                d = d - round(d);                 % nearest continuation, not a raw jump
                dW(ke) = d / (2 * step_rad);
            end
            dW(~isfinite(dW)) = 0;
        end

        function w_cycles = accumulate(wPrev_cycles, wFrac_cycles, hasPrev)
            % accumulate  Carry cycle continuity across epochs.
            %
            %   w_n = w_(n-1) + wrapToHalfCycle( frac_n - w_(n-1) )
            %
            % wrapToHalfCycle(d) = d - round(d) maps to [-0.5, 0.5], which is the
            % cycles form of the wrapToPi step in the standard formulation. Tracking the
            % nearest continuation of the previous value is what a receiver's phase loop
            % does; taking the raw arccos each epoch would inject a full cycle of
            % spurious jump every time the geometry crosses a half-cycle boundary.
            %
            % hasPrev=false seeds the arc at the raw fractional value, so an arc starts
            % at its true wind-up and not at zero.
            if nargin < 3 || isempty(hasPrev); hasPrev = true; end
            if ~hasPrev
                w_cycles = wFrac_cycles;
                return
            end
            d = wFrac_cycles - wPrev_cycles;
            w_cycles = wPrev_cycles + (d - round(d));
        end

    end  % Static methods
end
