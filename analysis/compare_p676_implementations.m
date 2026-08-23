function compare_p676_implementations()
% compare_p676_implementations  Evidence that analysis/p676_annex1.m is transcribed correctly.
%
% Runs the repo's plain-MATLAB P.676-13 Annex 1 against an INDEPENDENT transcription
% of the same Recommendation (MathWorks gaspl, P.676-10), and against the repo's own
% Annex 2 approximation.
%
% THE TOOLBOX IS NEEDED ONLY HERE. Nothing in the simulation, and nothing in
% generate_gas_absorption_table.m, requires it. This script SKIPS with a message when
% gaspl is absent, so it is safe to run anywhere.
%
% WHAT EACH COMPARISON PROVES
%
%   A. Dry path with e = 0 on BOTH sides -> expect EXACTLY 0.00e+00 relative error.
%      The oxygen line table is byte-identical between P.676-10 and -13, and the
%      equations are the same, so anything other than an exact match is a
%      transcription error in equations (1)-(9) or in Table 1. This is the check that
%      makes Annex 1 worth preferring over Annex 2: Annex 2's -4 to -11% approximation
%      gap is wide enough to HIDE a wrong coefficient, this one is not.
%
%   B. Total with rho = 7.5 -> expect -0.1% to -3.6%, NOT zero. The water vapour table
%      was REVISED between P.676-10 and -13 (22.235 GHz b1 0.1130 -> 0.1079,
%      b3 28.11 -> 26.38, and the 1780 GHz line by 21%). The gap is largest at
%      24.125 GHz because that is where water vapour is 81% of the total. A gap of
%      ZERO here would mean the v13 table had not actually been picked up.
%
%   C. Annex 2 against Annex 1 -> the approximation error, for the record.
%
% ⚠ TRAP, and it cost a wrong result once. Do NOT compare "dry" attenuation by calling
% one side with rho = 0 and the other with rho = 7.5. Water vapour partial pressure e
% broadens the OXYGEN lines through equations (6a) and (7) and enters the dry continuum
% through (9), so dry attenuation in a moist atmosphere is a different quantity from dry
% attenuation in a dry one. Doing that showed a spurious 1% disagreement.

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);

    % Surface state: ITU-R P.835 mean annual global reference atmosphere at h = 0.
    T_K      = 288.15;
    RHO_GM3  = 7.5;
    Pd_hPa   = 1013.25 - RHO_GM3*T_K/216.7;      % total minus e -> DRY air pressure
    Tc       = T_K - 273.15;

    % 915 MHz is omitted: gaspl validates f >= 1 GHz and refuses it outright, which is
    % itself the evidence for the validity-floor caveat in the plan's B5.
    f_GHz = [1.0 1.17645 1.22760 1.57542 2.45 5.2 5.8 24.125 61.25];

    haveRef = exist('gaspl', 'file') == 2;
    if ~haveRef
        fprintf(['compare_p676_implementations: SKIPPED -- gaspl not available.\n' ...
                 'This script is the optional cross-check. The frozen table and the\n' ...
                 'simulation do not depend on it.\n']);
        return;
    end

    fprintf('\n=== A. DRY PATH, e = 0 both sides (expect EXACTLY 0) ===\n');
    fprintf('%9s %20s %20s %12s\n', 'f GHz', 'p676_annex1.m', 'independent', 'rel err');
    worstDry = 0;
    for k = 1:numel(f_GHz)
        f   = f_GHz(k);
        go  = p676_annex1(f, Pd_hPa, T_K, 0);
        ref = gaspl(1000, f*1e9, Tc, Pd_hPa*100, 0);
        rel = abs(go/ref - 1);
        worstDry = max(worstDry, rel);
        fprintf('%9.3f %20.12e %20.12e %12.2e\n', f, go, ref, rel);
    end
    fprintf('worst dry-path relative error: %.2e\n', worstDry);
    assert(worstDry == 0, ...
        ['p676_annex1.m does NOT reproduce the independent Annex 1 transcription on the ' ...
         'dry path (worst %.3e). Equations (1)-(9) or Table 1 are mis-transcribed.'], worstDry);

    fprintf('\n=== B. TOTAL, rho = 7.5 (expect a NON-zero v13-vs-v10 water vapour gap) ===\n');
    fprintf('%9s %20s %20s %12s\n', 'f GHz', 'annex1 v13', 'independent v10', 'rel');
    gaps = zeros(1, numel(f_GHz));
    for k = 1:numel(f_GHz)
        f = f_GHz(k);
        [go, gw] = p676_annex1(f, Pd_hPa, T_K, RHO_GM3);
        ref      = gaspl(1000, f*1e9, Tc, Pd_hPa*100, RHO_GM3);
        gaps(k)  = (go+gw)/ref - 1;
        fprintf('%9.3f %20.12e %20.12e %11.3f%%\n', f, go+gw, ref, 100*gaps(k));
    end
    [~, iw] = max(abs(gaps));
    fprintf('largest gap %.3f%% at %.3f GHz (expected: 24.125, where wet is 81%% of total)\n', ...
        100*gaps(iw), f_GHz(iw));
    assert(max(abs(gaps)) > 1e-6, ...
        ['The v13 and v10 water vapour tables agree exactly, which cannot happen -- ' ...
         'Table 2 in p676_annex1.m is probably still the v10 data.']);

    fprintf('\n=== C. ANNEX 2 approximation error against ANNEX 1 ===\n');
    fprintf('%9s %20s %20s %12s\n', 'f GHz', 'annex 2', 'annex 1', 'rel');
    for k = 1:numel(f_GHz)
        f = f_GHz(k);
        [go1, gw1]           = p676_annex1(f, Pd_hPa, T_K, RHO_GM3);
        [go2, gw2, ho, hw]   = p676_annex2(f, Pd_hPa, T_K, RHO_GM3);
        % Annex 2 returns specific attenuation plus equivalent heights, so compare the
        % SPECIFIC attenuation here -- the zenith comparison lives in the plan's B1.
        fprintf('%9.3f %20.12e %20.12e %11.3f%%\n', ...
            f, go2+gw2, go1+gw1, 100*((go2+gw2)/(go1+gw1) - 1));
    end
    fprintf('(equivalent heights at the last frequency: h_o = %.4f km, h_w = %.4f km)\n', ho, hw);

    fprintf('\nAll assertions passed.\n');
end
