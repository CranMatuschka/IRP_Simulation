classdef IntegerAmbiguityFixer
% IntegerAmbiguityFixer  Guarded raw-carrier integer ambiguity fixing.
%
% Only for the controlled singleAssetCarrierAttitude scenario.
% Only for raw carrier floatPerTowerReceiverSignal ambiguity states.
% NOT LAMBDA/MLAMBDA. NOT carrier-IF fixing. NOT WL/NL. NOT false-fix-risk.
%
% runtime struct:
%   fixState  containers.Map: trackKey -> struct(arcId,Bfixed_m) for held fixes
%   dt_s      epoch duration [s]

    methods (Static)

        function s = assess(runtime, ekf, cpInfo, cfg)
            s = revgnss.IntegerAmbiguityFixer.blank_();
            if ~revgnss.IntegerAmbiguityFixer.isEnabled_(cfg); return; end
            s.enabled = true;
            s.mode    = 'controlledRawCarrier';

            scenOk = false;
            try; scenOk = strcmp(cfg.scenario.name,'singleAssetCarrierAttitude'); catch; end
            if ~scenOk; s.classification = 'disabled-not-single-asset-attitude'; return; end

            if ~ekf.estimateAmbiguities || ekf.nAmbiguities == 0
                s.blockers{end+1} = 'no EKF ambiguity states';
                s.classification  = 'unavailable-metadata'; return
            end
            ambMode = lower(ekf.ambiguityMode);
            if contains(ambMode,'ionofree') || contains(ambMode,'_if')
                s.classification = 'disabled-carrier-if-noninteger'; return
            end

            [cands, bks] = revgnss.IntegerAmbiguityFixer.buildCandidates_(ekf, cpInfo, cfg, runtime);
            s.blockers    = [s.blockers, bks];
            s.nCandidates = numel(cands);
            if s.nCandidates == 0; s.classification = 'no-candidates'; return; end

            sigVec  = [cands.sigma_cycles];
            distVec = [cands.distanceToInteger_cycles];
            sv = sigVec(isfinite(sigVec));
            if ~isempty(sv)
                s.minSigmaCycles  = min(sv);
                s.meanSigmaCycles = mean(sv);
                s.maxSigmaCycles  = max(sv);
            end
            dv = distVec(isfinite(distVec));
            if ~isempty(dv); s.maxDistanceToIntegerCycles = max(dv); end

            [eligible, rejected] = revgnss.IntegerAmbiguityFixer.validateResiduals_(cands, cpInfo, cfg);
            s.nRejected = numel(rejected);

            [newFixes, nHeld] = revgnss.IntegerAmbiguityFixer.filterHeld_(eligible, runtime.fixState);
            s.nHeld        = nHeld;
            s.nAccepted    = numel(newFixes);
            s.candidateTable = newFixes;

            if s.nAccepted > 0
                s.classification = 'active-fixed-raw-carrier';
            elseif nHeld > 0
                s.classification = 'active-held';
            elseif s.nCandidates > 0
                s.classification = 'active-no-fixes';
            end
            s.integerFixingImplemented = true;
        end

        function resetOnSlip(fixState, resetRequests)
            if isempty(fixState) || ~isa(fixState,'containers.Map'); return; end
            for ri = 1:numel(resetRequests)
                ai = 1;
                if isfield(resetRequests(ri),'receiverIdx')
                    ai = resetRequests(ri).receiverIdx;
                end
                k = sprintf('T%03d_A%03d_S%02d', resetRequests(ri).towerIdx, ai, resetRequests(ri).signalIdx);
                if isKey(fixState, k); remove(fixState, k); end
            end
        end

        function lines = summaryLines(s)
            lines = {sprintf('Stage 63 class: %s | enabled: %s | cand: %d | acc: %d | held: %d | rej: %d', ...
                s.classification, mat2str(s.enabled), s.nCandidates, s.nAccepted, s.nHeld, s.nRejected)
                'LAMBDA:false | carrierIF:false | WL/NL:false | falseFixRisk:false | PPP:false'};
        end

    end  % methods (Static)

    methods (Static, Access = private)

        function ok = isEnabled_(cfg)
            ok = false;
            try; ok = logical(cfg.estimator.integerAmbiguity.enable); catch; end
        end

        function v = getThresh_(cfg, name, def)
            v = def;
            try; v = cfg.estimator.integerAmbiguity.(name); catch; end
        end

        function [cands, blockers] = buildCandidates_(ekf, cpInfo, cfg, runtime)
            cands = struct([]); blockers = {};
            if ~isfield(cpInfo,'ambiguityStateIdx') || ~isfield(cpInfo,'trackKey') || ...
               ~iscell(cpInfo.trackKey); return; end

            threshSig  = revgnss.IntegerAmbiguityFixer.getThresh_(cfg,'maxSigma_cycles',0.15);
            threshDist = revgnss.IntegerAmbiguityFixer.getThresh_(cfg,'maxDistanceToInteger_cycles',0.20);
            threshArc  = revgnss.IntegerAmbiguityFixer.getThresh_(cfg,'minArcLength_s',300);
            fv_cyc2    = revgnss.IntegerAmbiguityFixer.getThresh_(cfg,'fixVariance_cycles2',1e-4);
            dt_s = 1.0; try; dt_s = runtime.dt_s; catch; end

            seen  = containers.Map('KeyType','int32','ValueType','logical');
            nRows = numel(cpInfo.towerIdx);
            for mi = 1:nRows
                stIdx = cpInfo.ambiguityStateIdx(mi);
                if stIdx <= 0; continue; end
                if isKey(seen, int32(stIdx)); continue; end
                seen(int32(stIdx)) = true;

                si = cpInfo.signalIdx(mi);
                try
                    % Resolved band: the catalogue read here sized every integer search
                    % in 190.29 mm / 244.21 mm cycles regardless of the scenario's band.
                    sigId  = revgnss.SignalCatalog.signalId(si);
                    lambda = revgnss.SignalUtils.wavelength(cfg, sigId);
                catch
                    continue
                end

                Bf_m     = ekf.x(stIdx);
                sig_m    = sqrt(max(0, ekf.P(stIdx,stIdx)));
                sig_cyc  = sig_m / lambda;
                Bf_cyc   = Bf_m / lambda;
                N_hat    = round(Bf_cyc);
                dist_cyc = abs(Bf_cyc - N_hat);

                arcLen_s = NaN; arcId = 0;
                if isfield(cpInfo,'currentArcEpoch') && mi <= numel(cpInfo.currentArcEpoch)
                    arcLen_s = double(cpInfo.currentArcEpoch(mi)) * dt_s;
                    arcId    = cpInfo.arcId(mi);
                end

                c.ambiguityStateIdx        = stIdx;
                c.towerIdx                 = cpInfo.towerIdx(mi);
                c.receiverIdx              = cpInfo.antennaIdx(mi);
                c.signalIdx                = si;
                c.wavelength_m             = lambda;
                c.trackKey                 = cpInfo.trackKey{mi};
                c.Bfloat_m                 = Bf_m;
                c.sigma_m                  = sig_m;
                c.sigma_cycles             = sig_cyc;
                c.Bfloat_cycles            = Bf_cyc;
                c.nearestInteger_cycles    = N_hat;
                c.distanceToInteger_cycles = dist_cyc;
                c.Bfixed_m                 = N_hat * lambda;
                c.fixSigma_m               = sqrt(fv_cyc2) * lambda;
                c.arcLength_s              = arcLen_s;
                c.arcId                    = arcId;
                c.eligible                 = true;
                c.blockers                 = {};
                c.residualRmsBefore_m      = NaN;
                c.residualRmsAfter_m       = NaN;

                if isnan(arcLen_s) || arcLen_s < threshArc
                    c.eligible = false;
                    c.blockers{end+1} = sprintf('arcLen %.0fs < %.0fs', arcLen_s, threshArc);
                end
                if sig_cyc > threshSig
                    c.eligible = false;
                    c.blockers{end+1} = sprintf('sigma %.3f > %.3f cyc', sig_cyc, threshSig);
                end
                if dist_cyc > threshDist
                    c.eligible = false;
                    c.blockers{end+1} = sprintf('dist %.3f > %.3f cyc', dist_cyc, threshDist);
                end

                if isempty(cands); cands = c; else; cands(end+1) = c; end %#ok<AGROW>
            end
        end

        function [eligible, rejected] = validateResiduals_(cands, cpInfo, cfg)
            eligible = struct([]); rejected = struct([]);
            threshRms = revgnss.IntegerAmbiguityFixer.getThresh_(cfg,'maxResidualRmsIncrease_m',0.01);
            for ci = 1:numel(cands)
                c = cands(ci);
                if ~c.eligible
                    if isempty(rejected); rejected = c; else; rejected(end+1) = c; end %#ok<AGROW>
                    continue
                end
                rowMask = (cpInfo.ambiguityStateIdx == c.ambiguityStateIdx);
                if ~any(rowMask)
                    c.eligible = false; c.blockers{end+1} = 'no rows for residual check';
                    if isempty(rejected); rejected = c; else; rejected(end+1) = c; end %#ok<AGROW>
                    continue
                end
                pref   = cpInfo.prefit_m(rowMask);
                rmsBef = sqrt(mean(pref.^2));
                rmsAft = sqrt(mean((pref - (c.Bfixed_m - c.Bfloat_m)).^2));
                c.residualRmsBefore_m = rmsBef; c.residualRmsAfter_m = rmsAft;
                if rmsAft > rmsBef + threshRms
                    c.eligible = false;
                    c.blockers{end+1} = sprintf('rms %.4f->%.4f worsens', rmsBef, rmsAft);
                    if isempty(rejected); rejected = c; else; rejected(end+1) = c; end %#ok<AGROW>
                    continue
                end
                if isempty(eligible); eligible = c; else; eligible(end+1) = c; end %#ok<AGROW>
            end
        end

        function [newFixes, nHeld] = filterHeld_(eligible, fixState)
            newFixes = struct([]); nHeld = 0;
            if isempty(fixState) || ~isa(fixState,'containers.Map')
                newFixes = eligible; return
            end
            for ei = 1:numel(eligible)
                c = eligible(ei);
                if isKey(fixState, c.trackKey)
                    ent = fixState(c.trackKey);
                    if ent.arcId == c.arcId; nHeld = nHeld + 1; continue; end
                end
                if isempty(newFixes); newFixes = c; else; newFixes(end+1) = c; end %#ok<AGROW>
            end
        end

        function s = blank_()
            s.enabled                             = false;
            s.mode                                = 'disabled';
            s.classification                      = 'disabled';
            s.nCandidates                         = 0;
            s.nAccepted                           = 0;
            s.nHeld                               = 0;
            s.nRejected                           = 0;
            s.nReset                              = 0;
            s.candidateTable                      = struct([]);
            s.blockers                            = {};
            s.minSigmaCycles                      = NaN;
            s.meanSigmaCycles                     = NaN;
            s.maxSigmaCycles                      = NaN;
            s.maxDistanceToIntegerCycles          = NaN;
            s.integerFixingImplemented            = false;
            s.lambdaImplemented                   = false;
            s.carrierIfIntegerFixingImplemented   = false;
            s.wideLaneNarrowLaneFixingImplemented = false;
            s.falseFixRiskControlled              = false;
            s.pppGradeClaim                       = false;
        end

    end  % methods (Static, Access = private)

end
