classdef RelativisticClockCorrection
    % RelativisticClockCorrection  ESTIMATOR-side relativistic receiver-clock correction.
    %
    % A GEO spacecraft oscillator runs fast relative to a ground clock by a constant
    % fractional frequency y ~ +5.39e-10 (gravitational blueshift + special-relativistic
    % redshift + the ground clock's Earth-rotation term). In range units that is
    % c*y ~ 0.1615 m/s of clock drift and c*y*t of clock bias -- 581 m over a 3600 s arc.
    %
    % y is a PUBLISHED CONSTANT derivable from the broadcast orbit, so applying it on the
    % model side is using public data, not truth assistance. It has exactly the standing of
    % cfg.frames.eopModel, which applies published polar motion against a truth-side pole
    % offset. Offset model.fracFreq from the truth value to simulate a residual.
    %
    % WHY THIS EXISTS (measured 2026-08-09). Without it the whole c*y*t ramp had to be
    % carried by the estimated clock states. The truth range carried the ramp while the
    % truth Doppler did not, so the 2-state clock (b' = bdot) could not satisfy both
    % channels, and the part the clock-bias state could not absorb leaked through the
    % Kalman gain into position: 13.1 m of position error on an OCXO Q against 0.2 m on a
    % caesium Q, with the error vector parallel to K*1 restricted to position (cos = 0.9997)
    % and the reported sigma identical to 4 s.f. in both. Pairing this with the truth-side
    % fix (relativisticFracFreq now reaching getFractionalFrequency, so the truth Doppler
    % carries the rate too) removes the ramp from z - h on BOTH channels and leaves the
    % clock states estimating only the oscillator's own residual.
    %
    % GATING. Everything below returns EXACTLY 0 unless
    % cfg.physics.relativity.clock.model.enable is true, so a run with relativity off is
    % byte-identical to before this class existed.
    %
    % REFERENCE EPOCH. bias_m takes the simulation time t_s, whose origin is
    % ReverseGNSSSimulation.tVec = (0:dt:duration), i.e. t_s = 0 at the first epoch --
    % the same instant the truth ClockModel starts integrating. The two therefore share an
    % origin by construction and cannot drift apart.

    methods (Static)

        function y = fracFreq(cfg)
            % fracFreq  Model-side relativistic fractional-frequency offset [-]; 0 when off.
            y = 0;
            enabled = false;
            try
                enabled = logical(cfg.physics.relativity.clock.model.enable);
            catch
                return
            end
            if ~enabled; return; end

            % Explicit model value wins (allows a deliberate model-vs-truth residual).
            try
                v = cfg.physics.relativity.clock.model.fracFreq;
                if isnumeric(v) && isscalar(v) && isfinite(v)
                    y = v;
                    return
                end
            catch
            end

            % Otherwise derive it from the orbit, exactly as a receiver would from the
            % broadcast ephemeris. ConfigFactory normally resolves this into
            % physics.relativity.clock.model.fracFreq; this branch is the safety net.
            alt_m = 35786000;
            try; alt_m = cfg.orbit.altitudeMean_m; catch; end
            y = revgnss.Relativity.geoClockFracFreq(alt_m);
        end

        function b_m = bias_m(cfg, t_s)
            % bias_m  Modelled relativistic clock BIAS at simulation time t_s [m]; 0 when off.
            y = models.clocks.RelativisticClockCorrection.fracFreq(cfg);
            if y == 0; b_m = 0; return; end
            b_m = revgnss.Constants.SPEED_OF_LIGHT_MPS * y * t_s;
        end

        function bdot_mps = rate_mps(cfg)
            % rate_mps  Modelled relativistic clock DRIFT [m/s]; 0 when off.
            y = models.clocks.RelativisticClockCorrection.fracFreq(cfg);
            if y == 0; bdot_mps = 0; return; end
            bdot_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS * y;
        end

    end
end
