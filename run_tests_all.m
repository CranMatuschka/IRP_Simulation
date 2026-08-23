function root = run_tests_all(varargin)
%RUN_TESTS_ALL  Orchestrate the full Tests_All battery under output/Report_YYYYMMDD/Tests_All_HHMM/.
%
%   run_tests_all('Stamp','1234')                       % run EVERY slice sequentially
%   run_tests_all('Stamp','1234','Slice','ladder_default')  % run ONE slice (parallel worker)
%   run_tests_all('Stamp','1234','Slice','index')       % write the master index only
%
%   Four categories, each in its own subfolder of Tests_All_<Stamp>/, per-run folders named
%   Report_ts#_G#S#R#_TW# (ladders append the rung tag). Everything is 3600 s, one-way where
%   the spec says so, full PDFs (WritePdf).
%
%     Ladder_default   run_error_ladder('default')  -- idealised-grade error ladder, TW0,
%                      G5S1R1/G5S1R4/G5S6R4, 14 rungs each (baseline/isolated/accumulated).
%     Ladder_realism   run_error_ladder('realism')  -- realism-grade, extras disabled, TW0.
%     Battery_TW       run_oo_v1_battery            -- normal battery G5/G12 x {S1R1,S1R4,S6R4}
%                      x {TW0,TW1}.
%     Battery_L1#L2    run_oo_v1_battery per (grade,pair) -- 3 grades x 5 carrier pairs x
%                      {S1R4,S6R4} x {TW0,TW1}, homed under Battery_L1#L2/<grade>_<l1>#<l2>/.
%
%   SLICES (for parallel matlab -batch workers; all share the SAME Stamp so they agree on the
%   Tests_All_<Stamp> folder): 'ladder_default','ladder_realism','battery_tw',
%   'freq_idealised','freq_realism','freq_matchedatmo','index','all' (default).
%
%   See also: run_error_ladder, run_oo_v1_battery, run_oo_v1_analysis.

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir); addpath(fullfile(thisDir,'config'));

    p = inputParser;
    p.addParameter('Stamp',    '',    @(x)ischar(x)||isstring(x));
    p.addParameter('Slice',    'all', @(x)ischar(x)||isstring(x));
    p.addParameter('Duration', 3600,  @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('WritePdf', true);
    p.addParameter('Topos',    {[5 1 1],[5 1 4],[5 6 4]}, @iscell);
    p.parse(varargin{:});
    o = p.Results;
    slice = lower(char(o.Slice));
    dur   = o.Duration; pdf = logical(o.WritePdf);

    if isempty(o.Stamp); o.Stamp = datestr(now,'HHMM'); end %#ok<TNOW1,DATST>
    stamp   = regexprep(char(o.Stamp),'[^0-9A-Za-z_]','');
    dateStr = datestr(now,'yyyymmdd'); %#ok<TNOW1,DATST>
    root    = fullfile(thisDir,'output',['Report_' dateStr], ['Tests_All_' stamp]);
    if ~isfolder(root); mkdir(root); end
    fprintf('\n########## TESTS_ALL  slice=%s  root=%s ##########\n', slice, root);

    freqPairs  = { [1.57542 1.22760], [2.110 2.025], [6.425 5.925], [5.000 2.100], [8.400 7.900] };

    doAll = strcmp(slice,'all');

    if doAll || strcmp(slice,'ladder_default')
        run_error_ladder('default', 'Topos',o.Topos, 'Duration',dur, 'WritePdf',pdf, ...
            'Analyze',true, 'GroupDir', fullfile(root,'Ladder_default'));
    end
    if doAll || strcmp(slice,'ladder_realism')
        run_error_ladder('realism', 'Topos',o.Topos, 'Duration',dur, 'WritePdf',pdf, ...
            'Analyze',true, 'GroupDir', fullfile(root,'Ladder_realism'));
    end
    if doAll || strcmp(slice,'battery_tw')
        run_oo_v1_battery('OutRoot',root, 'Group','Battery_TW', 'Duration',dur, ...
            'WritePdf',pdf, 'Analyze',true, 'Towers',[5 12], 'SR',{[1 1],[1 4],[6 4]}, 'TW',[0 1]);
    end
    if doAll || strcmp(slice,'freq_idealised')
        i_freqSlice(root, 'idealised',   false, 'realistic', freqPairs, dur, pdf);
    end
    if doAll || strcmp(slice,'freq_realism')
        i_freqSlice(root, 'realism',     true,  'realistic', freqPairs, dur, pdf);
    end
    if doAll || strcmp(slice,'freq_matchedatmo')
        i_freqSlice(root, 'matchedatmo', false, 'matched',   freqPairs, dur, pdf);
    end
    if doAll || strcmp(slice,'index')
        i_writeIndex(root);
    end

    fprintf('\n########## TESTS_ALL slice=%s DONE. root=%s ##########\n', slice, root);
end

% ===========================================================================================
function i_freqSlice(root, grade, isReal, atmo, pairs, dur, pdf)
%I_FREQSLICE  One frequency-battery grade: 5 pairs x {S1R4,S6R4} x {TW0,TW1} = 20 runs.
    grpRoot = fullfile(root,'Battery_L1#L2');
    if ~isfolder(grpRoot); mkdir(grpRoot); end
    % The band travels with the config ('Band' -> cfg.signals.<name>), not through a
    % process-local override that the config could never see.
    mats = {}; lbls = {};
    for pIdx = 1:numel(pairs)
        l1 = pairs{pIdx}(1); l2 = pairs{pIdx}(2);
        tagP = sprintf('%.2f#%.2f', l1, l2);
        fprintf('\n---- FREQ [%s] pair %d/%d : %s GHz ----\n', grade, pIdx, numel(pairs), tagP);
        try
            bm = run_oo_v1_battery('OutRoot',grpRoot, 'Group',sprintf('%s_%s',grade,tagP), ...
                'Duration',dur, 'WritePdf',pdf, 'Analyze',false, 'Towers',5, ...
                'SR',{[1 4],[6 4]}, 'TW',[0 1], 'Realism',isReal, 'Atmosphere',atmo, ...
                'Band', struct('L1', l1, 'L2', l2));
            for kk = 1:numel(bm)
                if bm(kk).ok
                    mats{end+1} = bm(kk).matPath;               %#ok<AGROW>
                    lbls{end+1} = sprintf('%s_%s', tagP, bm(kk).tag); %#ok<AGROW>
                end
            end
        catch ME
            fprintf('  FREQ FAILED %s %s: %s\n', grade, tagP, ME.message);
        end
    end

    if numel(mats) >= 2
        try
            run_oo_v1_analysis(mats, 'Label', lbls, ...
                'OutDir', fullfile(grpRoot, ['analysis_' grade]), 'Open', false);
            fprintf('  FREQ analysis [%s] -> %s\n', grade, fullfile(grpRoot,['analysis_' grade]));
        catch ME
            fprintf('  (freq analysis failed %s: %s)\n', grade, ME.message);
        end
    end
end

% ===========================================================================================
function i_writeIndex(root)
%I_WRITEINDEX  Master markdown index: category run-counts + analysis pointers.
    cats = {'Ladder_default','Ladder_realism','Battery_TW','Battery_L1#L2'};
    fid = fopen(fullfile(root,'Tests_All_summary.md'),'w');
    if fid < 0; return; end
    fprintf(fid, '# Tests_All battery\n\n');
    fprintf(fid, 'Root: `%s`\n\n', root);
    fprintf(fid, '| Category | Report .mat runs | Report .pdf | Analysis dirs |\n');
    fprintf(fid, '|---|---:|---:|---|\n');
    total = 0;
    for c = 1:numel(cats)
        d = fullfile(root, cats{c});
        nMat = 0; nPdf = 0; anas = {};
        if isfolder(d)
            mats = dir(fullfile(d,'**','Report_*.mat'));  nMat = numel(mats);
            pdfs = dir(fullfile(d,'**','Report_*.pdf'));  nPdf = numel(pdfs);
            ad   = dir(fullfile(d,'**','analysis*'));
            for a = 1:numel(ad)
                if ad(a).isdir; anas{end+1} = strrep(fullfile(ad(a).folder,ad(a).name), root, '.'); end %#ok<AGROW>
            end
        end
        total = total + nMat;
        fprintf(fid, '| %s | %d | %d | %s |\n', cats{c}, nMat, nPdf, strjoin(unique(anas),'<br>'));
    end
    fprintf(fid, '\n**Total report .mat runs: %d**\n', total);
    fclose(fid);
    fprintf('  Master index -> %s  (%d total runs)\n', fullfile(root,'Tests_All_summary.md'), total);
end
