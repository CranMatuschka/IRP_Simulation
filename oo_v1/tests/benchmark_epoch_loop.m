function benchmark_epoch_loop(varargin)
%BENCHMARK_EPOCH_LOOP  Profile the steady-state EKF epoch loop of oo_v1.
%
%   benchmark_epoch_loop()                       % default config, 130 s
%   benchmark_epoch_loop('Duration',200)         % longer sample
%   benchmark_epoch_loop('Realism',true)         % realism-grade config
%   benchmark_epoch_loop('Out','prof.txt')       % also dump ranked table to file
%
% Purpose: give an authoritative per-function ranking of where a single run's
% per-epoch time goes, so byte-identical optimizations (see
% docs/performance_optimization_plan.md) can be prioritized and re-measured.
%
% NOTE: the MATLAB profiler adds ~5-8x uniform overhead, so use the ms/epoch as a
% RELATIVE ranking, not an absolute wall-clock. R2025b's profile('info')
% FunctionTable has NO 'SelfTime' field; self time is derived here from Children.

    p = inputParser;
    p.addParameter('Duration', 130, @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('Realism', false, @(x)islogical(x)||ismember(x,[0 1]));
    p.addParameter('Out', '', @(x)ischar(x)||isstring(x));
    p.addParameter('TopN', 40, @(x)isnumeric(x)&&isscalar(x));
    p.parse(varargin{:});
    o = p.Results;

    root = fileparts(fileparts(mfilename('fullpath')));   % tests/.. -> repo root
    addpath(root); addpath(fullfile(root,'config'));

    cfg = masterConfig();
    if o.Realism; cfg = realismGradeConfig(cfg); end
    cfg.simulation.duration_s = o.Duration;
    cfg.plots.enable = false; cfg.report.enable = false;

    sim = revgnss.ReverseGNSSSimulation(cfg);
    evalc('sim.initialize();');
    sim.step(1); sim.step(2);                 % JIT warmup

    profile off; profile clear; profile on -historysize 20000000;
    tRun = tic;
    for k = 3:sim.nEpochs; sim.step(k); end
    wall = toc(tRun);
    profile off;
    nE = sim.nEpochs - 2;

    p2 = profile('info'); T = p2.FunctionTable;
    % Derive self time = TotalTime - sum(child TotalTime attributed from this fn)
    selfT = [T.TotalTime];
    for i = 1:numel(T)
        if ~isempty(T(i).Children)
            selfT(i) = T(i).TotalTime - sum([T(i).Children.TotalTime]);
        end
    end
    [~,ord] = sort(selfT,'descend');

    hdr = sprintf('%s nx=%d nTowers=%d nRx=%d  %d epochs\nWALL %.2f s => %.1f ms/epoch, %.2f ep/s (UNDER PROFILER; ~5-8x real overhead)\n', ...
        ternary(o.Realism,'REALISM','DEFAULT'), sim.ekf.nx, sim.nTowers, ...
        size(sim.asset.receiverLeverArms_body_m,2), nE, wall, 1000*wall/nE, nE/wall);
    line = sprintf('%-52s %8s %8s %9s\n','FUNCTION (by SELF time)','TotT','SelfT','Calls');
    body = '';
    for i = 1:min(o.TopN,numel(ord))
        j = ord(i); nm = T(j).FunctionName; if numel(nm)>50; nm = nm(end-49:end); end
        body = [body sprintf('%-52s %8.2f %8.2f %9d\n', nm, T(j).TotalTime, selfT(j), T(j).NumCalls)]; %#ok<AGROW>
    end
    fprintf('%s%s%s', hdr, line, body);
    if ~isempty(o.Out)
        fid = fopen(o.Out,'w'); fprintf(fid,'%s%s%sDONE\n',hdr,line,body); fclose(fid);
        fprintf('Wrote %s\n', o.Out);
    end
end

function y = ternary(c,a,b); if c; y=a; else; y=b; end; end
