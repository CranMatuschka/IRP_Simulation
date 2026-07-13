classdef EkfInnovationAccounting
    % EkfInnovationAccounting  Separate EKF innovation NIS into physical / gauge /
    %   augmented contributions.  Stage 57.
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
            %   measTypePerRow — cell array of strings for physical rows ('code','ifCode',
            %                    'doppler','carrier'); may be empty or wrong length
            %   nPhysical      — number of physical measurement rows
            %   nGauge         — total gauge rows appended after physical rows
            %
            % Returns rowClass struct with logical column vectors of length nTotal.

            nTotal = nPhysical + nGauge;
            rowClass.nTotal    = nTotal;
            rowClass.nPhysical = nPhysical;
            rowClass.nGauge    = nGauge;

            rowClass.physicalMask        = [true(nPhysical,1);  false(nGauge,1)];
            rowClass.gaugeMask           = [false(nPhysical,1); true(nGauge,1)];
            rowClass.codeMask            = false(nTotal,1);
            rowClass.codeIonoFreeMask    = false(nTotal,1);
            rowClass.dopplerMask         = false(nTotal,1);
            rowClass.carrierMask         = false(nTotal,1);
            rowClass.carrierIonoFreeMask = false(nTotal,1);
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
            rms_.unknownPhysicalRms = revgnss.EkfInnovationAccounting.rmsForMask_(residual, rowClass.unknownPhysicalMask);
        end

        function c = compact(acc, rms_)
            % compact  Report-safe struct summarising Stage 57 innovation accounting.

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

    end

    methods (Static, Access = private)

        function [nis, dof, warns] = nisForMask_(y, S, mask)
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
