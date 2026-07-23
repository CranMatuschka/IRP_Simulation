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
            nisByType = diag.getNISByType();
            d_        = diag.getData();
            codeDof   = double(d_.meas.nCodeRows(:));
            doppDof   = double(d_.meas.nDopplerRows(:));
            allRows   = double(d_.meas.nRows(:));
            carrRows  = max(allRows - codeDof - doppDof, 0);

            result.nisCode    = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.code,    codeDof,  minSamp);
            result.nisDoppler = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.doppler, doppDof,  minSamp);
            result.nisCarrier = revgnss.ConsistencyStatistics.groupStat_( ...
                nisByType.carrier, carrRows, minSamp);
            result.nisDiffAtt.status = 'notAvailable';
            result.nisDiffAtt.note   = 'diffAttRows not separately NIS-tracked in base diagnostics v1';

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

        function r = defaultResult_()
            empty = struct('status','notAvailable','mean',NaN,'nisPerDof',NaN, ...
                           'median',NaN,'p95',NaN,'expectedDof',NaN, ...
                           'fractionInside',NaN,'nSamples',0);
            r.available      = false;
            r.nisOverall     = empty;
            r.nisCode        = empty;
            r.nisDoppler     = empty;
            r.nisCarrier     = empty;
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
