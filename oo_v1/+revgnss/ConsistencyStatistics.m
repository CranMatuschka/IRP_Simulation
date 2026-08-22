classdef ConsistencyStatistics
    % ConsistencyStatistics  NIS/NEES consistency diagnostics for the synthetic campaign.
    %
    % Reads pre-computed per-epoch NIS and NEES values from a completed Diagnostics
    % object and returns grouped status assessments.
    %
    % Scientific caveat: results are labelled partialCovarianceAwareSynthetic.
    % They are consistency evidence, not real-world proof.

    methods (Static)

        function result = computeFromDiag(diag, cfg)
            % computeFromDiag  Compute NIS/NEES statistics from a SimulationDataStore or Diagnostics.

            result = revgnss.ConsistencyStatistics.defaultResult_();
            if isempty(diag) || diag.nEpochs < 2
                return;
            end

            minSamp = 20;
            try; minSamp = cfg.validation.statistics.nis.minSamplesPerGroup; catch; end

            % ----- NIS -------------------------------------------------------
            % Each group's dof MUST be the count of the rows whose innovations went into
            % that group's numerator. The carrier dof used to be inferred as
            % nRows - nCodeRows - nDopplerRows, which is not that count: the measurement
            % stack carries eleven row-type labels (code, ifCode, carrier, doppler,
            % twoWayTimeTransfer, gauge, diffAtt, islCode, islDoppler, islCarrier,
            % islTwoWayRange), and the subtraction swept EIGHT of them into "carrier".
            % NIS_carrier is masked strictly on 'carrier', so those rows inflated the
            % denominator while contributing nothing to the numerator -- carrier NIS read
            % LOW by exactly the ratio of the padding. Measured on the golden's 105-row
            % budget (40 code + 40 doppler + 20 carrier + 5 twoWayTimeTransfer): dof 25 vs
            % the true 20, reporting NIS/dof 0.9866 where the honest value is 1.2333, i.e.
            % a 23%-overconfident carrier channel reading as perfectly consistent.
            % nCarrierRows was stored all along; it simply was not read.
            nisByType = diag.getNISByType();
            d_        = diag.getData();
            codeDof   = double(d_.meas.nCodeRows(:));
            doppDof   = double(d_.meas.nDopplerRows(:));
            allRows   = double(d_.meas.nRows(:));
            [carrRows, carrSrc] = revgnss.ConsistencyStatistics.carrierDof_( ...
                d_, allRows, codeDof, doppDof);
            twttRows  = revgnss.ConsistencyStatistics.rowCount_(d_, 'nTwoWayTimeTransferRows', ...
                                                                numel(allRows));

            result.nisCode    = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.code,    codeDof,  minSamp);
            result.nisDoppler = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.doppler, doppDof,  minSamp);
            result.nisCarrier = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.carrier, carrRows, minSamp);
            result.nisCarrierDofSource = carrSrc;
            if isfield(nisByType, 'twoWayTimeTransfer') && any(twttRows > 0)
                result.nisTwoWayTimeTransfer = revgnss.ConsistencyStatistics.groupStat_( ...
                    nisByType.twoWayTimeTransfer, twttRows, minSamp);
            end
            result.nisDiffAtt.status = 'notAvailable';
            result.nisDiffAtt.note   = 'diffAttRows not separately NIS-tracked in base diagnostics v1';

            % Rows belonging to no classified group. Reported rather than absorbed: the
            % whole defect above was an unaccounted remainder being silently attributed to
            % whichever group happened to be computed by subtraction. A nonzero value here
            % means a row type is present that no NIS group covers (gauge, diffAtt, the
            % ISL family), which is a gap in the diagnosis -- not licence to pad a dof.
            unclassified = max(allRows - codeDof - doppDof - carrRows - twttRows, 0);
            result.nisUnclassifiedRowsMean = mean(unclassified(isfinite(unclassified)));
            result.nisRowBudgetCloses      = result.nisUnclassifiedRowsMean < 1e-9;

            nisAll = d_.consistency.NIS(:);
            result.nisOverall = revgnss.ConsistencyStatistics.groupStat_( ...
                nisAll, allRows, minSamp);

            % ----- NEES ------------------------------------------------------
            result.neesPos = revgnss.ConsistencyStatistics.neesStat_( ...
                diag.getNEES(), minSamp);
            result.neesVel = revgnss.ConsistencyStatistics.neesStat_( ...
                revgnss.ConsistencyStatistics.getField_(diag,'NEES_vel'), minSamp);
            result.neesClk = revgnss.ConsistencyStatistics.neesStat_( ...
                revgnss.ConsistencyStatistics.getField_(diag,'NEES_clk'), minSamp);
            result.neesAtt = revgnss.ConsistencyStatistics.neesStat_( ...
                revgnss.ConsistencyStatistics.getField_(diag,'NEES_att'), minSamp);

            if ~strcmp(result.neesPos.status,'notAvailable') && ...
               ~strcmp(result.neesVel.status,'notAvailable')
                result.neesCore.status = revgnss.ConsistencyStatistics.worseStat_( ...
                    result.neesPos.status, result.neesVel.status);
                result.neesCore.note   = 'positionAndVelocityCombined';
            end

            result.nisInterpretation  = 'partialCovarianceAwareSynthetic';
            result.neesInterpretation = 'partialCovarianceAwareSynthetic';
            result.available = true;
        end

        function txt = formatNisTable(cs)
            % formatNisTable  Per-channel measurement-covariance verdict for ONE run.
            %
            % Answers the question the aggregate NIS cannot: which observable is
            % mis-weighted, in which direction, and by how much. NIS/dof is
            % actual/expected, so below 1 the filter expected more error than it got
            % (CONSERVATIVE -- it under-uses that observable) and above 1 it expected less
            % (OPTIMISTIC -- it is overconfident, the dangerous direction). The factor is
            % quoted in VARIANCE, with the sigma factor beside it since sigma is what the
            % config actually sets.
            %
            % The rho and N_eff columns are load-bearing, not decoration. nSamples counts
            % epochs; a strongly autocorrelated series has far fewer independent samples,
            % and a channel with N_eff of a few cannot support a confident verdict however
            % many epochs were run. Read the band as a heuristic, never as a significance
            % test.
            rows = { 'code',     'nisCode'; ...
                     'carrier',  'nisCarrier'; ...
                     'doppler',  'nisDoppler'; ...
                     'twoWay',   'nisTwoWayTimeTransfer'; ...
                     'OVERALL',  'nisOverall' };
            L = {};
            L{end+1} = '=== MEASUREMENT COVARIANCE CONSISTENCY (this run) ===';
            L{end+1} = sprintf('  %-9s %8s %9s %9s %-26s %8s %9s', ...
                'channel','rows/ep','NIS/dof','sigma x','verdict','rho(1)','N_eff');
            for k = 1:size(rows,1)
                nm = rows{k,1}; fld = rows{k,2};
                if ~isfield(cs, fld); continue; end
                g = cs.(fld);
                if ~isfinite(g.nisPerDof)
                    L{end+1} = sprintf('  %-9s %8s %9s %9s %-26s', nm, '-', '-', '-', ...
                        char(string(g.status))); %#ok<AGROW>
                    continue
                end
                r = g.nisPerDof;
                if r < 1
                    verdict = sprintf('conservative %.2fx', 1/max(r,eps));
                    sigX    = sqrt(1/max(r,eps));
                else
                    verdict = sprintf('OPTIMISTIC   %.2fx', r);
                    sigX    = sqrt(r);
                end
                if r >= 0.8 && r <= 1.25; verdict = 'consistent'; end
                L{end+1} = sprintf('  %-9s %8.1f %9.4f %9.2f %-26s %8.4f %9.1f', ...
                    nm, g.expectedDof, r, sigX, verdict, g.lag1Autocorr, g.nEff); %#ok<AGROW>
            end
            if isfield(cs,'nisUnclassifiedRowsMean') && isfinite(cs.nisUnclassifiedRowsMean)
                L{end+1} = sprintf('  unclassified rows/epoch: %.2f   budget closes: %d', ...
                    cs.nisUnclassifiedRowsMean, cs.nisRowBudgetCloses);
            end
            L{end+1} = '  NIS/dof < 1 = conservative (wastes information); > 1 = overconfident.';
            L{end+1} = '  Low N_eff means the verdict rests on few independent samples -- treat with care.';
            txt = strjoin(L, newline);
        end

    end  % public static

    methods (Static, Access = private)

        function [dof, src] = carrierDof_(d_, allRows, codeDof, doppDof)
            % carrierDof_  Rows whose innovations enter NIS_carrier.
            %
            % Prefers the STORED count. Falls back to the old subtraction only for a store
            % predating meas.nCarrierRows, and says so through src so a caller can tell a
            % measured dof from an inferred one -- the inferred value is only correct when
            % code, doppler and carrier are the sole row types present, which is exactly
            % the assumption that made the original defect invisible on simple fixtures.
            if isfield(d_, 'meas') && isfield(d_.meas, 'nCarrierRows') && ...
                    ~isempty(d_.meas.nCarrierRows)
                dof = double(d_.meas.nCarrierRows(:));
                src = 'stored';
                if numel(dof) == numel(allRows)
                    return;
                end
                % Length disagreement means the two series describe different runs; the
                % subtraction is no safer, so refuse rather than silently pick one.
                error('ConsistencyStatistics:carrierRowLengthMismatch', ...
                    ['meas.nCarrierRows has %d entries but meas.nRows has %d. These must ' ...
                     'index the same epochs for a per-epoch dof to mean anything.'], ...
                    numel(dof), numel(allRows));
            end
            dof = max(allRows - codeDof - doppDof, 0);
            src = 'inferredBySubtraction';
        end

        function v = rowCount_(d_, name, n)
            % rowCount_  Optional per-epoch row count as a length-n column; zeros if absent.
            v = zeros(n, 1);
            if isfield(d_, 'meas') && isfield(d_.meas, name) && ~isempty(d_.meas.(name))
                x = double(d_.meas.(name)(:));
                if numel(x) == n
                    v = x;
                end
            end
        end

        function r = defaultResult_()
            % SHAPE MUST MATCH groupStat_'s RETURN, field for field. It did not between
            % 2026-08-17 and today: groupStat_ returns lag1Autocorr and nEff, this struct
            % did not carry them, and the two-way channel falls back to THIS struct
            % whenever two-way time transfer is unavailable, which is the entire
            % single-asset ladder. ReportRunner then read .nEff off it, threw, and its
            % bare catch NaN'd all eleven arcNis metrics -- including the ones already
            % computed correctly. Adding a group statistic here without adding it to
            % groupStat_ (or the reverse) re-arms exactly that failure.
            empty = struct('status','notAvailable','mean',NaN,'nisPerDof',NaN, ...
                           'median',NaN,'p95',NaN,'expectedDof',NaN, ...
                           'fractionInside',NaN,'nSamples',0, ...
                           'lag1Autocorr',NaN,'nEff',NaN);
            r.available      = false;
            r.nisOverall     = empty;
            r.nisCode        = empty;
            r.nisDoppler     = empty;
            r.nisCarrier     = empty;
            r.nisTwoWayTimeTransfer = empty;
            r.nisCarrierDofSource   = 'notAvailable';
            r.nisUnclassifiedRowsMean = NaN;
            r.nisRowBudgetCloses      = false;
            r.nisDiffAtt     = struct('status','notAvailable','note','');
            r.neesPos        = struct('status','notAvailable','mean',NaN,'median',NaN,'p95',NaN, ...
                                      'fractionInside',NaN,'nSamples',0);
            r.neesVel        = r.neesPos;
            r.neesClk        = r.neesPos;
            r.neesAtt        = r.neesPos;
            r.neesCore       = struct('status','notAvailable','note','');
            r.nisInterpretation  = 'notRun';
            r.neesInterpretation = 'notRun';
        end

        function s = groupStat_(nisVec, dofVec, minSamp)
            s = struct('status','notAvailable','mean',NaN,'nisPerDof',NaN,...
                       'median',NaN,'p95',NaN,'expectedDof',NaN, ...
                       'fractionInside',NaN,'nSamples',0, ...
                       'lag1Autocorr',NaN,'nEff',NaN);
            if isempty(nisVec) || isempty(dofVec); return; end
            ok = isfinite(nisVec) & isfinite(dofVec) & dofVec > 0 & nisVec >= 0;
            nv = nisVec(ok);  dv = dofVec(ok);
            s.nSamples = numel(nv);
            if s.nSamples < minSamp
                s.status = 'insufficientSamples'; return;
            end

            % Lag-1 autocorrelation and the EFFECTIVE sample size it implies.
            % nSamples counts epochs, which is NOT how many independent samples the mean
            % rests on. A NIS series driven by a slowly-varying error is strongly
            % autocorrelated, and this project has previously measured N_eff of order 1-2
            % against thousands of epochs counted. Without this column a ratio of 0.65 off
            % 3601 epochs reads as overwhelming evidence when it may rest on a handful of
            % independent samples. AR(1) approximation: nEff = N*(1-rho)/(1+rho).
            if s.nSamples >= 3
                x = nv(:) - mean(nv);
                den = sum(x.^2);
                if den > 0
                    s.lag1Autocorr = sum(x(1:end-1).*x(2:end)) / den;
                    rho = min(max(s.lag1Autocorr, -0.999), 0.999);
                    s.nEff = s.nSamples * (1 - rho) / (1 + rho);
                end
            end
            s.mean = mean(nv);
            s.median = median(nv);
            s.p95 = revgnss.ConsistencyStatistics.percentile_(nv, 95);
            s.expectedDof = mean(dv);
            s.nisPerDof = s.mean / mean(dv);
            ratio = nv ./ max(dv, 1);
            s.fractionInside = mean(ratio >= 0.1 & ratio <= 5.0);
            s.status = revgnss.ConsistencyStatistics.nisStatus_(s.nisPerDof);
        end

        function s = neesStat_(v, minSamp)
            s = struct('status','notAvailable','mean',NaN,'median',NaN,'p95',NaN, ...
                       'fractionInside',NaN,'nSamples',0);
            if isempty(v); return; end
            ok = isfinite(v) & v >= 0;
            nv = v(ok);
            s.nSamples = numel(nv);
            if s.nSamples < minSamp; s.status = 'insufficientSamples'; return; end
            s.mean = mean(nv);
            s.median = median(nv);
            s.p95 = revgnss.ConsistencyStatistics.percentile_(nv, 95);
            s.fractionInside = mean(nv >= 0.1 & nv <= 5.0);
            s.status = revgnss.ConsistencyStatistics.nisStatus_(s.mean);
        end

        function st = nisStatus_(perDof)
            if isnan(perDof); st = 'notAvailable'; return; end
            if perDof < 0.5;  st = 'warnLow';      return; end
            if perDof > 2.0;  st = 'warnHigh';     return; end
            st = 'pass';
        end

        function p = percentile_(v, pct)
            v = sort(v(:));
            if isempty(v); p = NaN; return; end
            q = 1 + (numel(v)-1) * pct / 100;
            lo = floor(q); hi = ceil(q);
            if lo == hi
                p = v(lo);
            else
                p = v(lo) + (q-lo) * (v(hi)-v(lo));
            end
        end

        function st = worseStat_(a, b)
            order = {'fail','warnHigh','warnLow','insufficientSamples','notAvailable','pass'};
            ia = find(strcmp(order, a), 1); if isempty(ia); ia = numel(order); end
            ib = find(strcmp(order, b), 1); if isempty(ib); ib = numel(order); end
            st = order{min(ia, ib)};
        end

        function v = getDopplerDof_(diag)
            try
                v = double(diag.getData().meas.nDopplerRows(:));
            catch
                v = zeros(diag.nEpochs, 1);
            end
        end

        function v = getField_(diag, fieldName)
            try
                d_ = diag.getData();
                if isfield(d_.consistency, fieldName)
                    v = d_.consistency.(fieldName)(:);
                else
                    v = [];
                end
            catch
                v = [];
            end
        end

    end  % private static
end
