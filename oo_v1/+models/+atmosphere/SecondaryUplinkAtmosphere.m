classdef SecondaryUplinkAtmosphere
    % SecondaryUplinkAtmosphere  Guard-A divergent uplink atmosphere for tower->secondary rows.
    %
    % Relocated verbatim from revgnss.SecondaryGroundMeasurementBuilder (Phase 3b-2 C3) so the
    % shared profile-driven secondary-row path and the retiring builder both call ONE implementation.
    % Truth-side-only (into z, cannot cancel), PER-TOWER zenith Gauss-Markov (node = ti), deliberately
    % SHARED across all secondaries a tower observes -- per-LOS divergence comes only from the
    % elevation mapping, so the secondary<->secondary axis stays correlated and the radial<->clock
    % wall cannot average it down. Default off (atmosphere.enable=false) -> callers add nothing.

    methods (Static)
        function [dAtmo, Ratmo] = losUplink(ec, ti, el, t_s, dt, elvFloor, ...
                sTrop, sIono, tauT, tauI, shellH, nCap, chargeR)
            % sig 0=tropo, 1=iono. Truth-side metres. Ratmo>0 only when chargeR (else left for
            % Guard-C NEES). BYTE-IDENTICAL to SecondaryGroundMeasurementBuilder.losUplinkAtmo_.
            gT  = models.atmosphere.SecondaryUplinkAtmosphere.unitProc(ec, ti, 0, tauT, t_s);
            gI  = models.atmosphere.SecondaryUplinkAtmosphere.unitProc(ec, ti, 1, tauI, t_s);
            m_w = 1 / max(sin(el), sin(elvFloor));                                    % wet-tropo mapping
            M_i = models.atmosphere.MappingFunctions.ionosphere(el, 'thinShell', shellH); % iono obliquity
            dAtmo = sTrop*m_w*gT + sIono*M_i*gI;
            if chargeR
                nT = min(max(tauT/dt,1), nCap);  nI = min(max(tauI/dt,1), nCap);
                Ratmo = nT*(sTrop*m_w)^2 + nI*(sIono*M_i)^2;   % correlated bias: white R cannot average it
            else
                Ratmo = 0;                                     % honest-gate default: leave for Guard C NEES
            end
        end

        function gval = unitProc(ec, node, sig, tau, t_s)
            % Continuous, unit-variance, interval-correlated process: piecewise-linear interpolation
            % between per-interval knots (k=floor(t/tau)). C0, correlation length ~tau, NOT white,
            % order-independent (pure fn of node/sig/t). BYTE-IDENTICAL to the retired unitProc_.
            k  = floor(t_s/tau);  f = t_s/tau - k;
            u0 = ec.drawKeyedInterval(models.noise.RngSource.ATMO_SEC_UPLINK, node, 0, sig, k);
            u1 = ec.drawKeyedInterval(models.noise.RngSource.ATMO_SEC_UPLINK, node, 0, sig, k+1);
            gval = ((1-f)*u0 + f*u1) / sqrt((1-f)^2 + f^2);
        end
    end
end
