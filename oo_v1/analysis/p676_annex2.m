function [gamma_o, gamma_w, h_o, h_w] = p676_annex2(f_GHz, Pd_hPa, T_K, rho_gm3)
% p676_annex2  ITU-R P.676 Annex 2 approximate gaseous attenuation.
%
%   [go, gw, ho, hw] = p676_annex2(f_GHz, Pd_hPa, T_K, rho_gm3)
%
%   go, gw  specific attenuation at the surface [dB/km] (dry air, water vapour)
%   ho, hw  equivalent heights [km]
%
%   Zenith attenuation is then  A = go*ho + gw*hw  [dB].
%
% PLAIN MATLAB. No toolbox. Pd_hPa is DRY AIR pressure, not total.
%
% Source: Recommendation ITU-R P.676-10 (09/2013), Annex 2, equations for the
% approximate estimation of gaseous attenuation. Stated validity 1-350 GHz.
% Coefficients transcribed via the ITU-Rpy reference implementation and
% cross-validated against an independent P.676 implementation -- see
% compare_annex2_vs_linebyline.m. THE PRIMARY RECOMMENDATION TEXT HAS NOT YET
% BEEN READ DIRECTLY; verify before citing in the traceability register.

    rp = Pd_hPa / 1013.0;
    rt = 288.0 / T_K;

    phi = @(a,b,c,d) rp^a * rt^b * exp(c*(1-rp) + d*(1-rt));

    % ---- dry air ----------------------------------------------------------
    delta = -0.00306 * phi(3.211, -14.94,  1.583, -16.37);

    xi1 = phi( 0.0717, -1.8132,  0.0156, -1.6515);
    xi2 = phi( 0.5146, -4.6368, -0.1921, -5.7416);
    xi3 = phi( 0.3414, -6.5851,  0.2130, -8.5854);
    xi4 = phi(-0.0112,  0.0092, -0.1033, -0.0009);
    xi5 = phi( 0.2705, -2.7192, -0.3016, -4.1033);
    xi6 = phi( 0.2445, -5.9191,  0.0422, -8.0719);
    xi7 = phi(-0.1833,  6.5589, -0.2402,  6.1310);

    g54 =  2.192 * phi(1.8286, -1.9487, 0.4051, -2.8509);
    g58 = 12.590 * phi(1.0045,  3.5610, 0.1588,  1.2834);
    g60 = 15.000 * phi(0.9003,  4.1335, 0.0427,  1.6088);
    g62 = 14.280 * phi(0.9886,  3.4176, 0.1827,  1.3429);
    g64 =  6.819 * phi(1.4320,  0.6258, 0.3177, -0.5914);
    g66 =  1.908 * phi(2.0717, -4.1404, 0.4910, -4.8718);

    f = f_GHz;
    if f <= 54
        gamma_o = ( (7.2*rt^2.8) / (f^2 + 0.34*rp^2*rt^1.6) + ...
                    (0.62*xi3) / ((54-f)^(1.16*xi1) + 0.83*xi2) ) ...
                  * f^2 * rp^2 * 1e-3;
    elseif f <= 60
        gamma_o = exp( log(g54)/24.0 * (f-58)*(f-60) ...
                     - log(g58)/ 8.0 * (f-54)*(f-60) ...
                     + log(g60)/12.0 * (f-54)*(f-58) );
    elseif f <= 62
        gamma_o = g60 + (g62 - g60) * (f - 60) / 2.0;
    elseif f <= 66
        gamma_o = exp( log(g62)/8.0 * (f-64)*(f-66) ...
                     - log(g64)/4.0 * (f-62)*(f-66) ...
                     + log(g66)/8.0 * (f-62)*(f-64) );
    elseif f <= 120
        gamma_o = ( 3.02e-4*rt^3.5 + (0.283*rt^3.8)/((f-118.75)^2 + 2.91*rp^2*rt^1.6) ...
                  + (0.502*xi6*(1 - 0.0163*xi7*(f-66))) / ((f-66)^(1.4346*xi4) + 1.15*xi5) ) ...
                  * f^2 * rp^2 * 1e-3;
    else
        gamma_o = ( (3.02e-4)/(1 + 1.9e-5*f^1.5) ...
                  + (0.283*rt^0.3)/((f-118.75)^2 + 2.91*rp^2*rt^1.6) ) ...
                  * f^2 * rp^2 * rt^3.5 * 1e-3 + delta;
    end

    % ---- water vapour -----------------------------------------------------
    eta1 = 0.955*rp*rt^0.68 + 0.006*rho_gm3;
    eta2 = 0.735*rp*rt^0.50 + 0.0353*rt^4*rho_gm3;
    gg   = @(fi) 1 + ((f - fi)/(f + fi))^2;

    gamma_w = ( ...
        (3.98*eta1*exp(2.23*(1-rt))) / ((f-  22.235)^2 +  9.42*eta1^2) * gg(22.0) + ...
        (11.96*eta1*exp(0.70*(1-rt))) / ((f- 183.310)^2 + 11.14*eta1^2)            + ...
        (0.081*eta1*exp(6.44*(1-rt))) / ((f- 321.226)^2 +  6.29*eta1^2)            + ...
        (3.660*eta1*exp(1.60*(1-rt))) / ((f- 325.153)^2 +  9.22*eta1^2)            + ...
        (25.37*eta1*exp(1.09*(1-rt))) / ((f- 380.000)^2)                           + ...
        (17.40*eta1*exp(1.46*(1-rt))) / ((f- 448.000)^2)                           + ...
        (844.6*eta1*exp(0.17*(1-rt))) / ((f- 557.000)^2) * gg(557.0)               + ...
        (290.0*eta1*exp(0.41*(1-rt))) / ((f- 752.000)^2) * gg(752.0)               + ...
        (8.3328e4*eta2*exp(0.99*(1-rt))) / ((f-1780.00)^2) * gg(1780.0) ...
        ) * f^2 * rt^2.5 * rho_gm3 * 1e-4;

    % ---- equivalent heights ------------------------------------------------
    t1 = (4.64)/(1 + 0.066*rp^-2.3) * exp(-((f - 59.7)/(2.87 + 12.4*exp(-7.9*rp)))^2);
    t2 = (0.14*exp(2.21*rp)) / ((f - 118.75)^2 + 0.031*exp(2.2*rp));
    t3 = (0.0114)/(1 + 0.14*rp^-2.6) * f * ...
         (-0.0247 + 0.0001*f + 1.61e-6*f^2) / ...
         (1 - 0.0169*f + 4.1e-5*f^2 + 3.2e-7*f^3);

    h_o = (6.1)/(1 + 0.17*rp^-1.1) * (1 + t1 + t2 + t3);
    if f < 70
        h_o = min(h_o, 10.7 * rp^0.3);
    end

    sw  = (1.013)/(1 + exp(-8.6*(rp - 0.57)));
    h_w = 1.66 * (1 + (1.39*sw)/((f -  22.235)^2 + 2.56*sw) ...
                    + (3.37*sw)/((f - 183.310)^2 + 4.69*sw) ...
                    + (1.58*sw)/((f - 325.100)^2 + 2.89*sw));
end
