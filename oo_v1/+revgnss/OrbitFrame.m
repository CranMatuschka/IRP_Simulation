classdef OrbitFrame
    % OrbitFrame  Radial / along-track / cross-track (RAC) orbital frame.
    %
    %   The RAC frame decomposes an orbital-error vector into physically
    %   interpretable components, which raw ECEF X/Y/Z cannot. The basis is built
    %   from the truth position and velocity:
    %
    %       r_hat = r / |r|                            (radial, outward)
    %       h_hat = (r x v) / |r x v|                  (cross-track, orbit normal)
    %       a_hat = h_hat x r_hat                      (along-track, ~velocity)
    %
    %   RAC components of an error e are [dot(e,r_hat); dot(e,a_hat); dot(e,h_hat)].

    methods (Static)

        function [rHat, aHat, hHat, ok] = racBasis(r, v)
            % racBasis  Orthonormal RAC basis from position r and velocity v.
            %   ok = false (and zero vectors) when r or the angular momentum is
            %   degenerate, so callers can fall back safely.
            r = r(:); v = v(:);
            rHat = [0;0;0]; aHat = rHat; hHat = rHat; ok = false;
            nr = norm(r);
            if ~(nr > 0) || any(~isfinite(r)); return; end
            rHat = r / nr;
            h = cross(r, v);
            nh = norm(h);
            if ~(nh > 0) || any(~isfinite(v)); return; end
            hHat = h / nh;
            aHat = cross(hHat, rHat);
            ok = true;
        end

        function rac = ecefToRac(errEcef, rTruth, vTruth)
            % ecefToRac  Project ECEF error columns into the RAC frame.
            %   errEcef, rTruth, vTruth are [3 x n]. Returns [3 x n] = radial,
            %   along-track, cross-track. Degenerate epochs become NaN columns.
            n = size(errEcef, 2);
            rac = nan(3, n);
            for k = 1:n
                [rH, aH, hH, ok] = revgnss.OrbitFrame.racBasis(rTruth(:,k), vTruth(:,k));
                if ok
                    ek = errEcef(:,k);
                    rac(:,k) = [dot(ek, rH); dot(ek, aH); dot(ek, hH)];
                end
            end
        end

        function rac = ecefToRacGeo(errEcef, rEcef, vEcef, omega)
            % ecefToRacGeo  RAC projection using the effective inertial velocity.
            %   For a (near-)geostationary orbit the ECEF velocity is ~0, so
            %   cross(r, v_ecef) is degenerate and the plain RAC basis collapses.
            %   The inertial velocity v_eff = v_ecef + omega x r (omega = Earth
            %   rotation) restores a well-defined along/cross-track frame, still
            %   expressed in ECEF axes so the ECEF error can be projected directly.
            if nargin < 4 || isempty(omega)
                w = 7.2921150e-5;
                try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
                omega = [0; 0; w];
            end
            n = size(errEcef, 2);
            rac = nan(3, n);
            for k = 1:n
                rk = rEcef(:,k);
                veff = vEcef(:,k) + cross(omega, rk);
                [rH, aH, hH, ok] = revgnss.OrbitFrame.racBasis(rk, veff);
                if ok
                    ek = errEcef(:,k);
                    rac(:,k) = [dot(ek, rH); dot(ek, aH); dot(ek, hH)];
                end
            end
        end

    end
end
