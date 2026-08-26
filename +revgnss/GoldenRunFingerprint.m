classdef GoldenRunFingerprint
    % GoldenRunFingerprint  A run reduced to the numbers a regression can actually assert on.
    %
    % WHY THIS EXISTS. The headline numbers -- 1.53x rotation gain, 99.9963 % wide-lane fix
    % rate, 56x shape improvement -- were values read off a console or a MATLAB prompt. None
    % was pinned to anything, so nothing could tell whether a later change had moved them, and
    % two of the three could not be regenerated from the repository at all. This class turns a
    % run into an ORDERED, NAMED set of scalars that can be frozen in tests/golden/ and
    % compared, which makes "the tree is still green" a checkable statement.
    %
    % WHAT A FINGERPRINT IS NOT. It is not a claim that the numbers are RIGHT. It is a claim that
    % they have not MOVED. A frozen fingerprint is re-cut deliberately, with the reason recorded
    % in tests/golden/README_golden.md, whenever a commit is supposed to change an estimator.
    % The one fixture that must never move is ground_orientation_inert120, where every
    % ground-referenced gate
    % is off: if that fingerprint shifts, a supposedly gated change has leaked into the
    % default path and the commit is wrong no matter how good its own numbers look.
    %
    % SCENARIO HASH. Each fingerprint records the SHA-256 of the scenario JSON it came from, so a
    % silently edited scenario is caught even when the run is not repeated. That is the failure
    % mode that makes a golden worse than useless -- one that passes while measuring something
    % else.
    %
    %   fp  = revgnss.GoldenRunFingerprint.fromRun(out)          % ReportRunner output struct
    %   fp  = revgnss.GoldenRunFingerprint.fromMat(matPath)      % a written swarm .mat
    %   revgnss.GoldenRunFingerprint.write(fp, jsonPath)
    %   fp  = revgnss.GoldenRunFingerprint.read(jsonPath)
    %   rep = revgnss.GoldenRunFingerprint.compare(actual, frozen, relTol)
    %   revgnss.GoldenRunFingerprint.print(rep)

    methods (Static)

        function fp = fromRun(out, cfg, scenarioFile)
            % fromRun  Fingerprint the struct revgnss.ReportRunner returned.
            F = revgnss.GoldenRunFingerprint;
            if nargin < 2; cfg = []; end
            if nargin < 3; scenarioFile = ''; end
            if isempty(cfg) && isstruct(out) && isfield(out,'cfg'); cfg = out.cfg; end
            % The federated path's return struct carries no cfg (ReportRunner builds it from
            % pdfPath/matPath/summary/rel/version only), so the scenario identity has to come
            % from the .mat it just wrote. Without this the fingerprint records an empty
            % scenarioName and the identity check the whole golden rests on silently passes.
            if isempty(cfg) && isstruct(out) && isfield(out,'matPath') && ~isempty(out.matPath) ...
                    && isfile(out.matPath)
                try
                    S = load(out.matPath, 'cfg');
                    if isfield(S,'cfg'); cfg = S.cfg; end
                catch
                    % A .mat that cannot be read leaves scenarioName empty, which the golden
                    % test then rejects by name -- louder than a silent partial fingerprint.
                end
            end
            rel = struct();
            if isstruct(out) && isfield(out,'rel'); rel = out.rel; end
            summ = struct();
            if isstruct(out) && isfield(out,'summary'); summ = out.summary; end
            fp = F.build_(rel, summ, cfg, scenarioFile);
        end

        function fp = fromMat(matPath, scenarioFile)
            % fromMat  Fingerprint a written swarm .mat without re-running anything.
            F = revgnss.GoldenRunFingerprint;
            if nargin < 2; scenarioFile = ''; end
            S = load(matPath, 'rel', 'summary', 'cfg');
            rel = struct(); summ = struct(); cfg = [];
            if isfield(S,'rel');     rel  = S.rel;     end
            if isfield(S,'summary'); summ = S.summary; end
            if isfield(S,'cfg');     cfg  = S.cfg;     end
            fp = F.build_(rel, summ, cfg, scenarioFile);
        end

        function write(fp, jsonPath)
            % write  Freeze a fingerprint.
            %
            % NUMBERS ARE STORED AS STRINGS, and that is not a stylistic choice. jsonencode
            % writes NaN as null and jsondecode reads null back as [] -- so a frozen NaN
            % returns as an empty array, every NaN-valued field fails its length check, and the
            % gate reports a failure that is purely an encoding artefact. A vector of NaNs is
            % worse: it decodes to a CELL. Writing '%.17g' round-trips every double exactly,
            % including NaN and Inf, and leaves the file readable and diffable, which a golden
            % that humans have to review deliberately should be.
            F = revgnss.GoldenRunFingerprint;
            d = fileparts(jsonPath);
            if ~isempty(d) && ~isfolder(d); mkdir(d); end
            payload = struct('labels', struct(), 'values', struct());
            f = fieldnames(fp);
            for i = 1:numel(f)
                v = fp.(f{i});
                if ischar(v) || isstring(v)
                    payload.labels.(f{i}) = char(v);
                else
                    payload.values.(f{i}) = F.numToStr_(v);
                end
            end
            txt = jsonencode(payload, 'PrettyPrint', true);
            fid = fopen(jsonPath, 'w');
            if fid < 0; error('GoldenRunFingerprint:write','Cannot open %s', jsonPath); end
            closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fprintf(fid, '%s\n', txt);
        end

        function fp = read(jsonPath)
            raw = jsondecode(fileread(jsonPath));
            fp = struct();
            if isfield(raw,'labels') && isstruct(raw.labels)
                f = fieldnames(raw.labels);
                for i = 1:numel(f); fp.(f{i}) = char(raw.labels.(f{i})); end
            end
            if isfield(raw,'values') && isstruct(raw.values)
                f = fieldnames(raw.values);
                for i = 1:numel(f)
                    fp.(f{i}) = revgnss.GoldenRunFingerprint.strToNum_(raw.values.(f{i}));
                end
            end
        end

        function rep = compare(actual, frozen, relTol, absTol)
            % compare  Field-by-field, with a RELATIVE tolerance and an absolute floor so a value
            % that is legitimately near zero does not fail on its own round-off.
            if nargin < 3 || isempty(relTol); relTol = 1e-9; end
            if nargin < 4 || isempty(absTol); absTol = 1e-12; end
            rep = struct('pass', true, 'nChecked', 0, 'failures', {{}}, 'missing', {{}}, ...
                'extra', {{}}, 'relTol', relTol, 'absTol', absTol);
            fa = fieldnames(actual); ff = fieldnames(frozen);
            rep.extra   = setdiff(fa, ff);
            rep.missing = setdiff(ff, fa);
            for i = 1:numel(ff)
                k = ff{i};
                if ~isfield(actual, k); continue; end
                a = actual.(k); b = frozen.(k);
                if ischar(a) || isstring(a) || ischar(b) || isstring(b)
                    rep.nChecked = rep.nChecked + 1;
                    if ~strcmp(char(a), char(b))
                        rep.pass = false;
                        rep.failures{end+1} = sprintf('%s: "%s" != "%s"', k, char(a), char(b));
                    end
                    continue
                end
                a = double(a(:)); b = double(b(:));
                if numel(a) ~= numel(b)
                    rep.pass = false;
                    rep.failures{end+1} = sprintf('%s: length %d != %d', k, numel(a), numel(b));
                    continue
                end
                rep.nChecked = rep.nChecked + numel(a);
                bothNaN = isnan(a) & isnan(b);
                d = abs(a - b);
                tol = absTol + relTol*abs(b);
                bad = ~bothNaN & ~(d <= tol);
                if any(bad)
                    rep.pass = false;
                    j = find(bad, 1);
                    rep.failures{end+1} = sprintf('%s(%d): %.12g != %.12g (|d| = %.3g > %.3g)', ...
                        k, j, a(j), b(j), d(j), tol(j));
                end
            end
        end

        function print(rep)
            if rep.pass
                fprintf('  GOLDEN PASS  (%d values, relTol %.1e)\n', rep.nChecked, rep.relTol);
            else
                fprintf(2, '  GOLDEN FAIL  (%d values, relTol %.1e)\n', rep.nChecked, rep.relTol);
            end
            for i = 1:numel(rep.failures); fprintf(2, '    %s\n', rep.failures{i}); end
            if ~isempty(rep.missing)
                fprintf(2, '    missing from actual: %s\n', strjoin(rep.missing(:).', ', '));
            end
            if ~isempty(rep.extra)
                fprintf('    new fields (not asserted): %s\n', strjoin(rep.extra(:).', ', '));
            end
        end

        function h = fileSha256(p)
            % fileSha256  Hex SHA-256 of a file, for pinning a fingerprint to its scenario.
            h = '';
            if ~isfile(p); return; end
            fid = fopen(p, 'r'); if fid < 0; return; end
            closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
            bytes = fread(fid, Inf, '*uint8');
            md = java.security.MessageDigest.getInstance('SHA-256');
            d  = typecast(md.digest(bytes), 'uint8');
            h  = lower(reshape(dec2hex(d).', 1, []));
        end
    end

    methods (Static, Access = private)

        function s = numToStr_(v)
            % numToStr_  Exact decimal round-trip for any double, NaN and Inf included.
            v = double(v(:)).';
            if isempty(v); s = {}; return; end
            s = cell(1, numel(v));
            for i = 1:numel(v); s{i} = sprintf('%.17g', v(i)); end
        end

        function v = strToNum_(s)
            if isempty(s); v = []; return; end
            if ischar(s) || isstring(s); s = {char(s)}; end
            if ~iscell(s); v = double(s(:)).'; return; end
            v = zeros(1, numel(s));
            for i = 1:numel(s); v(i) = str2double(s{i}); end
        end

        function fp = build_(rel, summ, cfg, scenarioFile)
            F = revgnss.GoldenRunFingerprint;
            fp = struct();
            fp.scenarioName   = F.str_(cfg, {'scenario','name'}, '');
            fp.durationSecond = F.num_(cfg, {'simulation','duration_s'}, NaN);
            fp.nSpaceAssets   = F.num_(cfg, {'scenario','nSpaceAssets'}, NaN);
            fp.seed           = F.num_(cfg, {'simulation','seed'}, NaN);
            fp.scenarioSha256 = '';
            if ~isempty(scenarioFile); fp.scenarioSha256 = F.fileSha256(scenarioFile); end

            % --- ISL relative layer ---------------------------------------------------------
            fp.shapeErrRaw_m        = F.num_(rel, {'shapeErrRaw_m'}, NaN);
            fp.shapeErrSolved_m     = F.num_(rel, {'shapeErrSolved_m'}, NaN);
            fp.baselineErrRaw_m     = F.num_(rel, {'baselineErrRaw_m'}, NaN);
            fp.baselineErrSolved_m  = F.num_(rel, {'baselineErrSolved_m'}, NaN);
            fp.formalShapeSigma_m   = F.num_(rel, {'formalShapeSigma_m'}, NaN);
            fp.relClockErrSolved_m  = F.num_(rel, {'relClockErrSolved_m'}, NaN);
            fp.weaklyObservable     = double(F.num_(rel, {'weaklyObservable'}, 0));

            % --- 3-parameter ground rotation stage -------------------------------------------
            fp.rotationGateOn     = double(F.num_(rel, {'rotationGateOn'}, 0));
            fp.rotationReason     = F.str_(rel, {'rotationReason'}, 'absent');
            fp.rotationTheta_rad  = F.vec_(rel, {'rotationTheta_rad'}, 3);
            fp.rotationSigma_rad  = F.vec_(rel, {'rotationSigma_rad'}, 3);
            fp.rotationNObs       = F.num_(rel, {'rotationNObs'}, NaN);
            fp.rotationCondition  = F.num_(rel, {'rotationCondition'}, NaN);

            % --- Joint shape+rotation stage ---------------------------------------------------
            jnt = struct();
            if isstruct(rel) && isfield(rel,'joint'); jnt = rel.joint; end
            fp.jointGateOn          = double(F.num_(rel, {'jointGateOn'}, 0));
            fp.jointReason          = F.str_(rel, {'jointReason'}, 'absent');
            fp.jointAccepted        = double(F.num_(jnt, {'accepted'}, 0));
            fp.jointAcceptReason    = F.str_(jnt, {'acceptReason'}, 'absent');
            fp.jointTheta_rad       = F.vec_(rel, {'jointTheta_rad'}, 3);
            fp.jointThetaSigma_rad  = F.vec_(rel, {'jointThetaSigma_rad'}, 3);
            fp.jointShapeStep_m     = F.num_(rel, {'jointShapeStep_m'}, NaN);
            fp.jointNObs            = F.num_(rel, {'jointNObs'}, NaN);
            fp.jointShapeFrame      = F.str_(jnt, {'shapeFrame'}, 'absent');
            fp.jointShapePriorSigma_m = F.num_(jnt, {'shapePriorSigma_m'}, NaN);
            fp.jointShapePriorSource  = F.str_(jnt, {'shapePriorSource'}, 'absent');
            fp.jointObservableShapeDof = F.num_(jnt, {'observableShapeDof'}, NaN);
            fp.jointShapeDofTotal      = F.num_(jnt, {'shapeDofTotal'}, NaN);
            fp.jointShapeGainMedian    = F.num_(jnt, {'shapeGainMedian'}, NaN);
            fp.jointShapeGainMax       = F.num_(jnt, {'shapeGainMax'}, NaN);
            fp.jointSeparationPenalty  = F.num_(jnt, {'separationPenalty'}, NaN);
            fp.jointSeparationPenaltyFree = F.num_(jnt, {'separationPenaltyFree'}, NaN);
            fp.jointTurnAngle_deg      = F.num_(jnt, {'turnAngle_deg'}, NaN);
            fp.jointRotationSnrMin     = F.num_(jnt, {'rotationSnrMin'}, NaN);
            fp.jointVarianceFactor     = F.num_(jnt, {'varianceFactor'}, NaN);
            fp.jointLeverArmMode       = F.str_(jnt, {'leverArmMode'}, 'absent');
            fp.jointLeverArmDdSystematic_m = F.num_(jnt, {'leverArmDdSystematic_m'}, NaN);

            % --- Carrier ambiguity probe -------------------------------------------------------
            cp = struct();
            if isstruct(rel) && isfield(rel,'carrierProbe'); cp = rel.carrierProbe; end
            fp.carrierProbeReason   = F.str_(cp, {'reason'}, 'absent');
            fp.carrierGeomErrRms_m  = F.num_(cp, {'geomErrRms_m'}, NaN);
            fp.carrierNEffective    = F.num_(cp, {'nEffectiveEpochs'}, NaN);
            names = {'wideLane','L2','L1','narrowLane'};
            for b = 1:4
                fp.(['carrierFixRate_' names{b}]) = F.band_(cp, b, 'fixRate');
                fp.(['carrierP95_' names{b}])     = F.band_(cp, b, 'p95AbsFloatErr_cyc');
            end

            % --- Beamforming budget (the mission number) ---------------------------------------
            bs = struct();
            if isstruct(rel) && isfield(rel,'beamformingSeries'); bs = rel.beamformingSeries; end
            fp.beamPathErrRms_m      = F.num_(bs, {'tailPathErrorRms_m'}, NaN);
            fp.beamCoherenceFreq_Hz  = F.num_(bs, {'coherenceFrequency_Hz'}, NaN);
            fp.beamSpotDisplacement_m = F.num_(bs, {'tailSpotDisplacement_m'}, NaN);
            fp.beamTiltFraction      = F.num_(bs, {'tiltFraction'}, NaN);
            fp.beamGainLoss_dB       = F.vec_(bs, {'tailCoherentGainLoss_dB'}, 3);

            % --- Orientation coherence budget (execution-plan G1/G2/G5) ------------------------
            ob = struct();
            if isstruct(rel) && isfield(rel,'orientationBudget'); ob = rel.orientationBudget; end
            fp.orientRotationErr_deg   = F.num_(ob, {'rotationErr_deg'}, NaN);
            fp.orientRimDisplacement_m = F.num_(ob, {'rimDisplacement_m'}, NaN);
            fp.orientRotationLever_m   = F.num_(ob, {'rotationLever_m'}, NaN);
            fp.orientGainLoss_dB       = F.vec_(ob, {'gainLoss_dB'}, 3);
            fp.orientMispointBeamwidths = F.vec_(ob, {'mispointBeamwidths'}, 3);

            % --- Per-asset absolute -------------------------------------------------------------
            fp.absErr_m = [];
            if isstruct(summ) && isfield(summ,'perAsset') && ~isempty(summ.perAsset)
                pa = summ.perAsset;
                v = nan(1, numel(pa));
                for i = 1:numel(pa)
                    if isfield(pa(i),'absErr_m'); v(i) = pa(i).absErr_m; end
                end
                fp.absErr_m = v;
            end
        end

        function v = band_(cp, b, field)
            v = NaN;
            if ~isstruct(cp) || ~isfield(cp,'bands') || isempty(cp.bands); return; end
            if numel(cp.bands) < b; return; end
            if isfield(cp.bands(b), field); v = double(cp.bands(b).(field)); end
        end

        function v = num_(s, path, dflt)
            v = dflt; c = s;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (isnumeric(c) || islogical(c)); v = double(c(1)); end
        end

        function v = vec_(s, path, n)
            v = nan(1,n); c = s;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if isnumeric(c) && numel(c) == n; v = double(c(:)).'; end
        end

        function v = str_(s, path, dflt)
            v = dflt; c = s;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (ischar(c) || isstring(c)); v = char(c); end
        end
    end
end
