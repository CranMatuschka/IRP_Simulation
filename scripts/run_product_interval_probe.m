function run_product_interval_probe()
%RUN_PRODUCT_INTERVAL_PROBE Does the tower-clock product cause the two-way colour?
%
%   The reference run reports a lag-one innovation autocorrelation of 0.725 on
%   the two-way rows, the highest of any channel, and removing multipath leaves
%   it unchanged. The broadcast product is held for updateInterval_s and then
%   extrapolated linearly, so its residual is smooth inside each window. If the
%   product is the cause, rho(1) must rise with the interval.
%
%   Three rungs at 5, 30 and 90 s. 30 s is the control and must reproduce the
%   frozen reference. 90 s is the longest interval that keeps the product age
%   inside validity_s = 120, so no validity policy fires and one key moves.

    here = fileparts(fileparts(mfilename('fullpath')));   % repo root, NOT scripts/
    % This file moved into scripts/ on 2026-08-23. Every fullfile(here,...) below
    % resolves against the REPOSITORY ROOT, so the extra fileparts is load-bearing:
    % without it config/, output/ and tests/ would be looked for inside scripts/.
    cd(here);
    addpath(here);
    addpath(fullfile(here, 'config'));
    addpath(fullfile(here, 'config', 'internal'));

    rungs = { 'prod005_productInterval5s',  5; ...
              'prod030_productInterval30s', 30; ...
              'prod090_productInterval90s', 90 };

    n = size(rungs, 1);
    res = struct('name', {}, 'interval', {}, 'twNis', {}, 'twRho', {}, 'twNeff', {}, ...
                 'codeRho', {}, 'overallNis', {}, 'pos', {}, 'clk', {});

    for k = 1:n
        name = rungs{k, 1};
        iv   = rungs{k, 2};
        fprintf('\n=== PROBE %d/%d  %s  interval = %d s ===\n', k, n, name, iv);
        t0 = tic;
        try
            out = run_oo_v1(fullfile('config', 'ladder', 'prod', [name '.json']), 3600);
        catch err
            fprintf('PROBE FAILED %s: %s\n', name, err.message);
            continue
        end
        s = out.summary;

        % Pull the two-way row out of the run's own consistency table. The
        % per-channel autocorrelation is exported to the summary only for code,
        % carrier and Doppler, so the two-way figure is read from the table text.
        [twRho, twNeff] = twoWayFromTable_(s);

        r = numel(res) + 1;
        res(r).name       = name;
        res(r).interval   = iv;
        res(r).twNis      = getfield_(s, 'arcNisTwoWayPerDof');
        res(r).twRho      = twRho;
        res(r).twNeff     = twNeff;
        res(r).codeRho    = getfield_(s, 'arcNisCodeLag1');
        res(r).overallNis = getfield_(s, 'arcNisOverallPerDof');
        res(r).pos        = getfield_(s, 'finalPositionRMS_m');
        res(r).clk        = getfield_(s, 'clockBiasRMS_runwide_m');
        fprintf('  done in %.1f min   twoWay rho(1) = %.4f\n', toc(t0)/60, twRho);
    end

    fprintf('\n\n================ PRODUCT INTERVAL PROBE ================\n');
    fprintf('%-10s %-10s %-10s %-10s %-10s %-10s\n', ...
            'interval', 'twNIS', 'tw rho1', 'tw Neff', 'code rho1', 'overall');
    for k = 1:numel(res)
        fprintf('%-10d %-10.4f %-10.4f %-10.0f %-10.4f %-10.4f\n', ...
                res(k).interval, res(k).twNis, res(k).twRho, res(k).twNeff, ...
                res(k).codeRho, res(k).overallNis);
    end

    if numel(res) >= 2
        rhos = [res.twRho];
        ivs  = [res.interval];
        fprintf('\nVERDICT\n');
        fprintf('  two-way rho(1) spans %.4f to %.4f over an interval span of %dx\n', ...
                min(rhos), max(rhos), round(max(ivs)/min(ivs)));
        if issorted(rhos) && (max(rhos) - min(rhos)) > 0.05
            fprintf('  rho(1) RISES monotonically with the interval.\n');
            fprintf('  CONFIRMED: the broadcast product residual is the cause.\n');
        elseif (max(rhos) - min(rhos)) <= 0.05
            fprintf('  rho(1) is FLAT across the span.\n');
            fprintf('  REFUTED: the product interval does not drive the two-way colour.\n');
        else
            fprintf('  rho(1) moves but not monotonically. Inconclusive, report the values.\n');
        end
    end

    save(fullfile(here, 'output', 'product_interval_probe.mat'), 'res');
    fprintf('\nsaved: output/product_interval_probe.mat\n');
end

function v = getfield_(s, f)
    if isfield(s, f); v = double(s.(f)); else; v = NaN; end
end

function [rho, neff] = twoWayFromTable_(s)
%TWOWAYFROMTABLE_ Read the two-way autocorrelation from the run's own NIS table.
    rho = NaN; neff = NaN;
    if isfield(s, 'arcNisTwoWayLag1') && isfinite(s.arcNisTwoWayLag1)
        rho  = double(s.arcNisTwoWayLag1);
        neff = double(getfield_(s, 'arcNisTwoWayNEff'));
        return
    end
    if ~isfield(s, 'arcNisTable'); return; end
    txt = char(s.arcNisTable);
    tok = regexp(txt, 'twoWay\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+\S+[^\n]*?\s+([\d.]+)\s+([\d.]+)', ...
                 'tokens', 'once');
    if ~isempty(tok)
        rho  = str2double(tok{1});
        neff = str2double(tok{2});
    end
end
