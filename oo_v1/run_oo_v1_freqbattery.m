function manifest = run_oo_v1_freqbattery(varargin)
%RUN_OO_V1_FREQBATTERY  Uplink-carrier sweep: idealised/realism/matched-atmosphere x topologies.
%
%   manifest = run_oo_v1_freqbattery()                 % full matrix: 3 grades x 5 pairs x {S1R4,S6R4}
%   run_oo_v1_freqbattery('Grades',{'idealised','matchedatmo'},'SRList',{[1 4]})
%   run_oo_v1_freqbattery('Pairs',{[5.0 2.1]},'SliceTag','w3','Analyze',false)  % one parallel slice
%
%   WHY. The sim is a REVERSE GNSS (ground->space uplink); GPS L1/L2 are downlink RNSS
%   bands not licensable for a ground->GEO uplink. This battery sweeps physically-motivated
%   uplink carrier pairs (see docs/geo_uplink_frequency_analysis.md) across THREE grades and
%   TWO topologies, homing everything under output/FrequencyTests/.
%
%   GRADES (all start from masterConfig; only these differ):
%     idealised   - realism overlay OFF; realistic atmosphere (default). Optimistic clock/systematics.
%     realism     - realism overlay ON (realismGradeConfig); realistic atmosphere. Honest clock/systematics/forces.
%     matchedatmo - realism overlay OFF; atmosphere OFF (cfg.atmosphere.realistic=false -> tropo+iono
%                   enable=0 -> ZERO atmospheric error). Same as idealised EXCEPT the atmosphere, so
%                   contrasting idealised vs matchedatmo ISOLATES the ionosphere's contribution.
%
%   TOPOLOGIES (SRList, [nSpaceAssets nReceivers], Towers=5): {[1 4],[6 4]} = G5S1R4 (ground-only)
%   and G5S6R4 (5-secondary ISL swarm aiding the primary).
%
%   Frequency is applied via revgnss.SignalDefinition.setFrequencyOverride (golden-safe: default
%   off; ALWAYS cleared in a finally). config/internal/realisticAtmosphereConfig derives its iono K_L1 from
%   the active L1 so the modelled iono tracks the band.
%
%   Output layout:
%     output/FrequencyTests/G5S1R4/Battery_{idealised,realism,matchedatmo}_<L1>#<L2>/Report_.../...
%     output/FrequencyTests/G5S6R4/...
%     output/FrequencyTests/_manifests/<SliceTag>.mat   (per-slice manifest for the final analysis)
%   <L1>#<L2> = carrier pair in GHz to 2 decimals (e.g. 5.00#2.10).
%
%   Plots use a modern style: the comparison figures self-style in run_oo_v1_analysis and the
%   per-run report figures via +revgnss/ClockExactReportBuilder.makeCompactFig_ (no process-wide
%   groot mutation, so the compact report cells keep their report-scaled sizing). Slices run
%   disjoint subsets in parallel matlab -batch workers; a final run_oo_v1_analysis over the union.
%
%   See also: run_oo_v1_battery, run_oo_v1_analysis, revgnss.SignalDefinition.

    p = inputParser;
    p.addParameter('Duration', 3600, @(x)isnumeric(x)&&isscalar(x)&&x>0);
    p.addParameter('WritePdf', true);
    p.addParameter('Analyze',  true);
    p.addParameter('Pairs',    {}, @iscell);   % {[l1GHz l2GHz], ...}; empty -> default 5
    p.addParameter('Grades',   {'idealised','realism','matchedatmo'}, @iscell);
    p.addParameter('SRList',   {[1 4],[6 4]}, @iscell);   % {[nS nR], ...}
    p.addParameter('Towers',   5, @(x)isnumeric(x)&&isscalar(x));
    p.addParameter('OutRoot',  '', @(x)ischar(x)||isstring(x));  % default output/FrequencyTests
    p.addParameter('SliceTag', 'all', @(x)ischar(x)||isstring(x));
    p.parse(varargin{:});
    o = p.Results;

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir); addpath(fullfile(thisDir,'config')); addpath(fullfile(thisDir,'config','internal'));
    if isempty(o.OutRoot); o.OutRoot = fullfile(thisDir,'output','FrequencyTests'); else; o.OutRoot = char(o.OutRoot); end
    if ~isfolder(o.OutRoot); mkdir(o.OutRoot); end

    % Default sweep pairs (GHz), L1 = higher/primary. See the analysis doc.
    %   L-band GPS ref | S-band uplink | C-band uplink | C/S split-band | X-band uplink
    if isempty(o.Pairs)
        o.Pairs = { [1.57542 1.22760], [2.110 2.025], [6.425 5.925], [5.000 2.100], [8.400 7.900] };
    end

    gradeAbbr = containers.Map({'idealised','realism','matchedatmo'}, {'idea','real','matc'});
    allMat = {}; allLbl = {};
    manifest = struct('topology',{},'nS',{},'nR',{},'grade',{},'l1GHz',{},'l2GHz',{}, ...
                      'tag',{},'label',{},'matPath',{},'ok',{},'wall_s',{});

    % No process-local frequency override any more: the band travels with the config,
    % passed to run_oo_v1_battery as 'Band' and written into cfg.signals.<name>.
    nTot = numel(o.SRList)*numel(o.Pairs)*numel(o.Grades); ct = 0;
    for si = 1:numel(o.SRList)
        nS = o.SRList{si}(1); nR = o.SRList{si}(2);
        topo    = sprintf('G%dS%dR%d', o.Towers, nS, nR);
        topoDir = fullfile(o.OutRoot, topo);
        if ~isfolder(topoDir); mkdir(topoDir); end

        for pIdx = 1:numel(o.Pairs)
            pr = o.Pairs{pIdx}; l1 = pr(1); l2 = pr(2);
            tag = sprintf('%.2f#%.2f', l1, l2);

            for gIdx = 1:numel(o.Grades)
                grade = lower(o.Grades{gIdx}); ct = ct + 1;
                switch grade
                    case 'idealised';   isReal = false; atmo = 'realistic';
                    case 'realism';     isReal = true;  atmo = 'realistic';
                    case 'matchedatmo'; isReal = false; atmo = 'matched';
                    otherwise; error('run_oo_v1_freqbattery:grade','Unknown grade ''%s''.', grade);
                end
                ab  = 'grd'; if isKey(gradeAbbr,grade); ab = gradeAbbr(grade); end
                lbl = sprintf('S%d_%s_%.2f_%.2f', nS, ab, l1, l2);
                grp = sprintf('Battery_%s_%s', grade, tag);
                fprintf('\n########## %d/%d : %s | %s | L1=%.4f L2=%.4f GHz ##########\n', ct, nTot, topo, grade, l1, l2);

                tS = tic; mp = ''; ok = false;
                try
                    bm = run_oo_v1_battery('Duration',o.Duration, 'WritePdf',o.WritePdf, ...
                        'Analyze',false, 'Towers',o.Towers, 'SR',{[nS nR]}, 'TW',0, ...
                        'Realism',isReal, 'Atmosphere',atmo, 'OutRoot',topoDir, 'Group',grp, ...
                        'Band', struct('L1', l1, 'L2', l2));
                    okIdx = find([bm.ok], 1);
                    if ~isempty(okIdx)
                        mp = bm(okIdx).matPath; ok = true;
                        allMat{end+1} = mp;  %#ok<AGROW>
                        allLbl{end+1} = lbl; %#ok<AGROW>
                    end
                catch ME
                    fprintf('  FAILED %s %s %s: %s\n', topo, grade, tag, ME.message);
                end
                manifest(end+1) = struct('topology',topo,'nS',nS,'nR',nR,'grade',grade, ...
                    'l1GHz',l1,'l2GHz',l2,'tag',tag,'label',lbl,'matPath',mp,'ok',ok,'wall_s',toc(tS)); %#ok<AGROW>
            end
        end
    end

    % ---- Persist this slice's manifest --------------------------------------------
    manDir = fullfile(o.OutRoot,'_manifests'); if ~isfolder(manDir); mkdir(manDir); end
    slice = regexprep(char(o.SliceTag),'[^A-Za-z0-9._-]','_');
    save(fullfile(manDir,[slice '.mat']), 'manifest', 'allMat', 'allLbl');
    fprintf('\nSlice %s complete: %d/%d ok. Manifest: %s\n', slice, sum([manifest.ok]), numel(manifest), fullfile(manDir,[slice '.mat']));

    % ---- Optional combined analysis over THIS slice's runs -------------------------
    if (islogical(o.Analyze)&&o.Analyze || isequal(o.Analyze,1)) && ~isempty(allMat)
        try
            run_oo_v1_analysis(allMat, 'Label', allLbl, 'OutDir', fullfile(o.OutRoot,'analysis'), 'Open', false);
            fprintf('  Analysis -> %s\n', fullfile(o.OutRoot,'analysis'));
        catch ME
            fprintf('  (analysis failed: %s)\n', ME.message);
        end
    end
end
