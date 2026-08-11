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
            empty = struct('status','notAvailable','mean',NaN,'nisPerDof',NaN, ...
                           'median',NaN,'p95',NaN,'expectedDof',NaN, ...
                           'fractionInside',NaN,'nSamples',0);
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
                       'fractionInside',NaN,'nSamples',0);
            if isempty(nisVec) || isempty(dofVec); return; end
            ok = isfinite(nisVec) & isfinite(dofVec) & dofVec > 0 & nisVec >= 0;
            nv = nisVec(ok);  dv = dofVec(ok);
            s.nSamples = numel(nv);
            if s.nSamples < minSamp
                s.status = 'insufficientSamples'; return;
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
