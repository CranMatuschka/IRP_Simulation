classdef EkfInnovationAccounting
    % EkfInnovationAccounting  Separate EKF innovation NIS into physical / gauge /
    %   augmented contributions.
    %
    % Physical rows: real measurement rows passed by MeasurementModel (code, doppler,
    %   carrier, IF combinations).  Gauge rows: datum/clock constraint rows appended by
    %   appendClockGaugeRows / appendTxDelayGaugeRows before update().
    %
    % The existing summary.meanNIS is the augmented (physical + gauge) NIS.  That field
    %   is preserved as a legacy alias; physicalNIS is the correct chi-squared diagnostic.
    %
    % Usage (from ReverseGNSSSimulation.step):
    %   rowClass = EkfInnovationAccounting.classifyRows(measTypePerRow, nPhys, nGauge);
    %   acc      = EkfInnovationAccounting.compute(nu_aug, S_aug, rowClass);
    %   rms_     = EkfInnovationAccounting.residualRms(nu_aug, rowClass);
    %   compact_ = EkfInnovationAccounting.compact(acc, rms_);

    methods (Static)

        function rowClass = classifyRows(measTypePerRow, nPhysical, nGauge)
            % classifyRows  Build row-classification masks for the augmented innovation vector.
            %
            %   measTypePerRow — cell array of strings for physical rows; may be empty
            %                    or wrong length
            %   nPhysical      — number of physical measurement rows
            %   nGauge         — total gauge rows appended after physical rows
            %
            % Returns rowClass struct with logical column vectors of length nTotal.

            nTotal = nPhysical + nGauge;
            rowClass.nTotal    = nTotal;
            rowClass.nPhysical = nPhysical;
            rowClass.nGauge    = nGauge;
            rowClass.augmentedDof = nTotal;
            rowClass.physicalDof  = nPhysical;
            rowClass.gaugeDof     = nGauge;

            rowClass.physicalMask        = [true(nPhysical,1);  false(nGauge,1)];
            rowClass.gaugeMask           = [false(nPhysical,1); true(nGauge,1)];
            rowClass.codeMask            = false(nTotal,1);
            rowClass.codeIonoFreeMask    = false(nTotal,1);
            rowClass.dopplerMask         = false(nTotal,1);
            rowClass.carrierMask         = false(nTotal,1);
            rowClass.carrierIonoFreeMask = false(nTotal,1);
            rowClass.twoWayTimeTransferMask = false(nTotal,1);
            rowClass.twoWayIslRangeMask = false(nTotal,1);
            rowClass.unknownPhysicalMask = false(nTotal,1);
            rowClass.warnings            = {};

            if ~isempty(measTypePerRow) && iscell(measTypePerRow) && ...
                    numel(measTypePerRow) == nPhysical
                for mi = 1:nPhysical
                    switch measTypePerRow{mi}
                        case 'code';    rowClass.codeMask(mi)         = true;
                        case 'ifCode';  rowClass.codeIonoFreeMask(mi) = true;
                        case 'doppler'; rowClass.dopplerMask(mi)      = true;
                        case 'carrier'; rowClass.carrierMask(mi)      = true;
                        case 'twoWayTimeTransfer'; rowClass.twoWayTimeTransferMask(mi) = true;
                        case 'islTwoWayRange'; rowClass.twoWayIslRangeMask(mi) = true;
                        otherwise;      rowClass.unknownPhysicalMask(mi) = true;
                    end
                end
            elseif nPhysical > 0
                rowClass.unknownPhysicalMask(1:nPhysical) = true;
                rowClass.warnings{end+1} = ...
                    'Row type metadata unavailable; physical rows classified as unknown.';
            end

            if nGauge == 0 && nPhysical > 0
                rowClass.warnings{end+1} = 'No gauge rows in this update.';
            end
        end

        function acc = compute(y, S, rowClass)
            % compute  Compute NIS for augmented, physical, gauge, and per-type subsets.
            %
            %   y        — innovation vector (augmented: physical rows first, then gauge)
            %   S        — innovation covariance (augmented)
            %   rowClass — output of classifyRows()
            %
            % NIS for a subset:  y_sub' * (S_sub \ y_sub)  (exact, using submatrix of S)
            % This is the exact chi-squared statistic under H_0.  E[NIS_sub / dof] = 1.

            acc.warnings = {};

            nRows = numel(y);
            allMask = true(nRows, 1);

            [acc.augmentedNIS,       acc.augmentedDof,       w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, allMask);
            acc.warnings = [acc.warnings, w_];

            [acc.physicalNIS,        acc.physicalDof,        w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.physicalMask);
            acc.warnings = [acc.warnings, w_];

            [acc.gaugeNIS,           acc.gaugeDof,           w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.gaugeMask);
            acc.warnings = [acc.warnings, w_];

            [acc.codeNIS,            acc.codeDof,            w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.codeMask);
            acc.warnings = [acc.warnings, w_];

            [acc.codeIonoFreeNIS,    acc.codeIonoFreeDof,    w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.codeIonoFreeMask);
            acc.warnings = [acc.warnings, w_];

            [acc.dopplerNIS,         acc.dopplerDof,         w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.dopplerMask);
            acc.warnings = [acc.warnings, w_];

            [acc.carrierNIS,         acc.carrierDof,         w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.carrierMask);
            acc.warnings = [acc.warnings, w_];

            [acc.carrierIonoFreeNIS, acc.carrierIonoFreeDof, w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.carrierIonoFreeMask);
            acc.warnings = [acc.warnings, w_];

            [acc.twoWayTimeTransferNIS, acc.twoWayTimeTransferDof, w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.twoWayTimeTransferMask);
            acc.warnings = [acc.warnings, w_];

            [acc.twoWayIslRangeNIS, acc.twoWayIslRangeDof, w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.twoWayIslRangeMask);
            acc.warnings = [acc.warnings, w_];

            [acc.unknownPhysicalNIS, acc.unknownPhysicalDof, w_] = revgnss.EkfInnovationAccounting.nisForMask_(y, S, rowClass.unknownPhysicalMask);
            acc.warnings = [acc.warnings, w_];
        end

        function rms_ = residualRms(residual, rowClass)
            % residualRms  Compute residual RMS for augmented, physical, gauge, per-type.

            rms_.augmentedRms       = revgnss.EkfInnovationAccounting.rmsForMask_(residual, true(numel(residual),1));
            rms_.physicalRms        = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.physicalMask);
            rms_.gaugeRms           = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.gaugeMask);
            % codeRms covers ALL code-domain rows (raw single-frequency OR ionosphere-free),
            % so the reported code residual is finite under codeMode='ionosphereFree' (whose
            % rows are tagged 'ifCode'). For single-frequency codeIonoFreeMask is empty, so
            % this is identical to the raw-code mask (golden-safe). The IF-only breakdown
            % remains available separately in codeIonoFreeRms.
            rms_.codeRms            = revgnss.EkfInnovationAccounting.rmsForMask_(residual, ...
                rowClass.codeMask | rowClass.codeIonoFreeMask);
            rms_.codeIonoFreeRms    = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.codeIonoFreeMask);
            rms_.dopplerRms         = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.dopplerMask);
            rms_.carrierRms         = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.carrierMask);
            rms_.carrierIonoFreeRms = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.carrierIonoFreeMask);
            rms_.twoWayTimeTransferRms = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.twoWayTimeTransferMask);
            rms_.twoWayIslRangeRms = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.twoWayIslRangeMask);
            rms_.unknownPhysicalRms = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.unknownPhysicalMask);
        end

        function c = compact(acc, rms_)
            % compact  Report-safe struct summarising innovation accounting.

            c.physicalNIS          = acc.physicalNIS;
            c.gaugeNIS             = acc.gaugeNIS;
            c.augmentedNIS         = acc.augmentedNIS;
            c.physicalDof          = acc.physicalDof;
            c.gaugeDof             = acc.gaugeDof;
            c.augmentedDof         = acc.augmentedDof;
            c.physicalNisPerDof    = revgnss.EkfInnovationAccounting.safeDiv_(acc.physicalNIS,   acc.physicalDof);
            c.gaugeNisPerDof       = revgnss.EkfInnovationAccounting.safeDiv_(acc.gaugeNIS,      acc.gaugeDof);
            c.augmentedNisPerDof   = revgnss.EkfInnovationAccounting.safeDiv_(acc.augmentedNIS,  acc.augmentedDof);
            c.physicalResidualRms  = rms_.physicalRms;
            c.gaugeResidualRms     = rms_.gaugeRms;
            c.augmentedResidualRms = rms_.augmentedRms;
            c.codeResidualRms      = rms_.codeRms;
            c.carrierResidualRms   = rms_.carrierRms;
            c.dopplerResidualRms   = rms_.dopplerRms;
            % PER-TYPE NIS. compute() has always calculated these and compact() threw them
            % away, leaving only the per-type residual RMS above -- which cannot answer the
            % question that actually matters when the aggregate NIS moves: WHICH measurement
            % block is mis-weighted. A residual RMS says how big the error is; only NIS/dof
            % says whether R and P cover it. Added 2026-08-10 while chasing a 1.50x aggregate
            % NIS that turned out to sit in one block.
            typeNames_ = {'code','codeIonoFree','carrier','carrierIonoFree','doppler'};
            for tn_ = typeNames_
                nisF_ = [tn_{1} 'NIS']; dofF_ = [tn_{1} 'Dof'];
                if isfield(acc, nisF_) && isfield(acc, dofF_)
                    c.(nisF_) = acc.(nisF_);
                    c.(dofF_) = acc.(dofF_);
                    c.([tn_{1} 'NisPerDof']) = ...
                        revgnss.EkfInnovationAccounting.safeDiv_(acc.(nisF_), acc.(dofF_));
                end
            end
            c.twoWayTimeTransferNIS = acc.twoWayTimeTransferNIS;
            c.twoWayTimeTransferDof = acc.twoWayTimeTransferDof;
            c.twoWayTimeTransferResidualRms = rms_.twoWayTimeTransferRms;
            c.twoWayIslRangeNIS = acc.twoWayIslRangeNIS;
            c.twoWayIslRangeDof = acc.twoWayIslRangeDof;
            c.twoWayIslRangeResidualRms = rms_.twoWayIslRangeRms;
            c.gaugeRowsPresent     = acc.gaugeDof > 0;

            if ~c.gaugeRowsPresent
                c.accountingClassification = 'physical-only';
            elseif acc.physicalDof > 0
                c.accountingClassification = 'physical-plus-gauge';
            elseif acc.augmentedDof > 0
                c.accountingClassification = 'augmented-only-metadata-missing';
            else
                c.accountingClassification = 'no-rows';
            end
            c.warnings = acc.warnings;
        end

        function [nis, dof, warns] = nisForMask_(y, S, mask)
            % nisForMask_  NIS of the y/S rows selected by mask: y'*(S\y), pinv-guarded.
            %   Public (not just an internal compute() helper) so callers that need a
            %   row grouping compute() doesn't expose directly -- e.g. ReverseGNSSSimulation
            %   merging 'code'+'ifCode' rows for the legacy per-type NIS panel scope -- can
            %   reuse the same exact-S-normalised, pinv-guarded computation.
            warns = {};
            dof = sum(mask);
            if dof == 0
                nis = NaN;
                return
            end
            ym = y(mask);
            Sm = S(mask, mask);
            Sm = 0.5 * (Sm + Sm');
            try
                nis = ym' * (Sm \ ym);
                if ~isfinite(nis) || nis < 0
                    nis = ym' * (pinv(Sm) * ym);
                    warns{end+1} = 'pinv fallback used (NIS non-finite from backslash).';
                end
            catch
                try
                    nis = ym' * (pinv(Sm) * ym);
                    warns{end+1} = 'pinv fallback used (backslash threw).';
                catch
                    nis = NaN;
                    warns{end+1} = 'NIS computation failed; result is NaN.';
                end
            end
        end

    end

    methods (Static, Access = private)

        function r = rmsForMask_(x, mask)
            if ~any(mask)
                r = NaN;
                return
            end
            r = sqrt(mean(x(mask).^2));
        end

        function r = safeDiv_(a, b)
            if b > 0 && isfinite(a) && isfinite(b)
                r = a / b;
            else
                r = NaN;
            end
        end

    end
end
