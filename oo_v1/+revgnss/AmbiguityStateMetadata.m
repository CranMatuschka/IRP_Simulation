classdef AmbiguityStateMetadata
    % AmbiguityStateMetadata  EKF ambiguity state-map and covariance export.
    %
    % Exports float ambiguity state-map indices and final covariance sub-block
    % diagnostics from a live EKF object.  Metadata/covariance export only.
    % No integer fixing, no LAMBDA/MLAMBDA, no L2 carrier EKF.
    %
    % Usage:
    %   meta    = revgnss.AmbiguityStateMetadata.fromEkf(ekf);
    %   cov     = revgnss.AmbiguityStateMetadata.covarianceFromEkf(ekf);
    %   summary = revgnss.AmbiguityStateMetadata.attachToSummary(summary, meta, cov);
    %   lines   = revgnss.AmbiguityStateMetadata.summaryLines(meta, cov);

    methods (Static)

        function meta = fromEkf(ekf)
            % fromEkf  Extract ambiguity state-map metadata from EKF struct or object.
            meta = revgnss.AmbiguityStateMetadata.blankMeta_();
            try
                if ~ekf.estimateAmbiguities || ekf.nAmbiguities == 0
                    meta.warnings{end+1} = 'EKF has no ambiguity states.'; return
                end
                meta.available    = true;
                meta.ambiguityMode = char(ekf.ambiguityMode);
                meta.nAmbiguities  = ekf.nAmbiguities;
                meta.nSignals      = ekf.ambiguityNSignals;
                meta.nReceivers    = ekf.ambiguityNReceivers;
                meta.nTowers       = ekf.nTowers;
                sm                 = ekf.stateMap;

                is3d = strcmp(meta.ambiguityMode,'floatPerTowerReceiverSignal') && ...
                    isfield(sm,'ambiguityIdx3d') && ~isempty(sm.ambiguityIdx3d);

                meta.ambiguityIdx   = sm.ambiguityIdx;
                if is3d
                    meta.ambiguityIdx3d = sm.ambiguityIdx3d;
                    nT = meta.nTowers; nRx = meta.nReceivers; nSig = meta.nSignals;
                    tbl = repmat(struct('stateIndex',0,'towerIndex',0,'receiverIndex',0, ...
                        'signalIndex',0,'signalId','','label',''), nT*nRx*nSig, 1);
                    k = 0;
                    for ti = 1:nT
                        for ri = 1:nRx
                            for si = 1:nSig
                                k = k+1;
                                sigId = revgnss.SignalCatalog.signalId(si);
                                tbl(k).stateIndex    = sm.ambiguityIdx3d(ti,ri,si);
                                tbl(k).towerIndex    = ti;
                                tbl(k).receiverIndex = ri;
                                tbl(k).signalIndex   = si;
                                tbl(k).signalId      = sigId;
                                tbl(k).label         = sprintf('N_T%d_R%d_%s',ti,ri,sigId);
                            end
                        end
                    end
                else
                    nT = meta.nTowers; nSig = meta.nSignals;
                    tbl = repmat(struct('stateIndex',0,'towerIndex',0,'receiverIndex',1, ...
                        'signalIndex',0,'signalId','','label',''), nT*nSig, 1);
                    k = 0;
                    for ti = 1:nT
                        for si = 1:nSig
                            k = k+1;
                            sigId = revgnss.SignalCatalog.signalId(si);
                            tbl(k).stateIndex  = sm.ambiguityIdx(ti,si);
                            tbl(k).towerIndex  = ti;
                            tbl(k).signalIndex = si;
                            tbl(k).signalId    = sigId;
                            tbl(k).label       = sprintf('N_T%d_%s',ti,sigId);
                        end
                    end
                end
                meta.ambiguityTable = tbl;
                meta.stateIndices   = [tbl.stateIndex]';
                meta.labels         = {tbl.label}';
            catch ex
                meta.warnings{end+1} = ['fromEkf: ' ex.message];
            end
        end

        function cov = covarianceFromEkf(ekf)
            % covarianceFromEkf  Extract ambiguity covariance sub-block from EKF.
            cov = revgnss.AmbiguityStateMetadata.blankCov_();
            try
                meta = revgnss.AmbiguityStateMetadata.fromEkf(ekf);
                if ~meta.available
                    cov.warnings = [cov.warnings, meta.warnings]; return
                end
                P = ekf.P;
                if isempty(P) || ~all(isfinite(P(:)))
                    cov.warnings{end+1} = 'ekf.P is empty or nonfinite.'; return
                end
                idx = meta.stateIndices;
                n   = ekf.nx;
                if any(idx < 1) || any(idx > n)
                    cov.warnings{end+1} = sprintf( ...
                        'Ambiguity indices [%d..%d] out of range [1..%d].', ...
                        min(idx), max(idx), n); return
                end
                Psub = P(idx, idx);
                Psub = (Psub + Psub') / 2;
                cov.available      = true;
                cov.Pamb           = Psub;
                cov.std_m          = sqrt(max(0, diag(Psub)));
                cov.minVariance_m2 = min(diag(Psub));
                cov.maxVariance_m2 = max(diag(Psub));
                if all(isfinite(Psub(:))) && ~isempty(Psub)
                    cov.condition = cond(Psub);
                end
                if numel(idx) > 1
                    D = sqrt(diag(Psub)); D(D < eps) = eps;
                    Corr = Psub ./ (D * D');
                    mask = ~eye(numel(idx),'logical');
                    if any(mask(:))
                        cov.correlationMaxAbs = max(abs(Corr(mask)));
                    end
                end
            catch ex
                cov.warnings{end+1} = ['covarianceFromEkf: ' ex.message];
            end
        end

        function summary = attachToSummary(summary, meta, cov)
            % attachToSummary  Attach compact ambiguity metadata/covariance to summary.
            m.available     = meta.available;
            m.ambiguityMode = meta.ambiguityMode;
            m.nAmbiguities  = meta.nAmbiguities;
            m.nTowers       = meta.nTowers;
            m.nReceivers    = meta.nReceivers;
            m.nSignals      = meta.nSignals;
            m.stateIndices  = meta.stateIndices;
            m.labels        = meta.labels;
            m.warnings      = meta.warnings;
            summary.ambiguityStateMetadata = m;

            c.available         = cov.available;
            c.condition         = cov.condition;
            c.correlationMaxAbs = cov.correlationMaxAbs;
            c.std_m             = cov.std_m;
            c.minVariance_m2    = cov.minVariance_m2;
            c.maxVariance_m2    = cov.maxVariance_m2;
            c.warnings          = cov.warnings;
            if cov.available && numel(meta.stateIndices) <= 100
                c.Pamb = cov.Pamb;
            else
                c.Pamb = [];
            end
            summary.ambiguityCovarianceSummary = c;
        end

        function lines = summaryLines(meta, cov)
            % summaryLines  Concise cell array for report.
            lines = {};
            lines{end+1} = sprintf('MetadataAvailable   : %s', mat2str(meta.available));
            if meta.available
                lines{end+1} = sprintf('AmbiguityMode       : %s', meta.ambiguityMode);
                lines{end+1} = sprintf('nAmbiguities        : %d', meta.nAmbiguities);
                lines{end+1} = sprintf('nTowers             : %d', meta.nTowers);
                lines{end+1} = sprintf('nReceivers          : %d', meta.nReceivers);
                lines{end+1} = sprintf('nSignals            : %d', meta.nSignals);
                lines{end+1} = 'StateIndexSource    : state-map';
            end
            lines{end+1} = sprintf('CovAvailable        : %s', mat2str(cov.available));
            if cov.available
                if isfinite(cov.condition)
                    lines{end+1} = sprintf('CovCondition        : %.2e', cov.condition);
                end
                if isfinite(cov.correlationMaxAbs)
                    lines{end+1} = sprintf('MaxCorrelation      : %.4f', cov.correlationMaxAbs);
                end
                if isfinite(cov.minVariance_m2) && isfinite(cov.maxVariance_m2)
                    lines{end+1} = sprintf('Std range           : [%.3f, %.3f] m', ...
                        sqrt(max(0,cov.minVariance_m2)), sqrt(max(0,cov.maxVariance_m2)));
                end
            end
        end

    end

    methods (Static, Access = private)

        function meta = blankMeta_()
            meta.available      = false;
            meta.ambiguityMode  = 'none';
            meta.nAmbiguities   = 0;
            meta.nTowers        = 0;
            meta.nReceivers     = 0;
            meta.nSignals       = 0;
            meta.ambiguityIdx   = [];
            meta.ambiguityIdx3d = [];
            meta.ambiguityTable = struct([]);
            meta.stateIndices   = [];
            meta.labels         = {};
            meta.warnings       = {};
        end

        function cov = blankCov_()
            cov.available         = false;
            cov.Pamb              = [];
            cov.std_m             = [];
            cov.condition         = NaN;
            cov.correlationMaxAbs = NaN;
            cov.minVariance_m2    = NaN;
            cov.maxVariance_m2    = NaN;
            cov.warnings          = {};
        end

    end
end
