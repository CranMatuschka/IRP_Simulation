classdef BaselineDiffAttitudeDiag
    % BaselineDiffAttitudeDiag  Baseline-differenced carrier attitude diagnostic.
    %
    % For receiver pairs (ai > 1, reference = 1) and tower ti:
    %   delta_phi(ti,ai) = phi(ti,ai) - phi(ti,1)
    %   delta_rho_model  = u_ti' * C(euler) * (lever_ai - lever_1)
    %
    % With truth ambiguities subtracted: residual = delta_phi - delta_rho_model - delta_B_truth
    % should equal noise if the geometric model is correct.
    %
    % MATHEMATICAL SEPARABILITY RESULT (Stage 14.9):
    % With one free float ambiguity per carrier measurement row, H_amb = I_{M×M},
    % which spans all of R^M.  Any attitude-induced signal H_att (M×3) lies in
    % span(H_amb), so rank([H_att H_amb]) = rank(H_amb) always.
    % Attitude is mathematically NOT separable from free float ambiguities.
    % Baseline differencing reduces M by nTowers but leaves M-nTowers differential
    % float ambiguities — still one per row — so non-separability persists.
    % Resolution requires: integer ambiguity fixing, or known/constrained ambiguities.

    methods (Static)

        function result = compute(cpInfoSeries, cfg, leverArms_body_m)
            % compute  Compute baseline-differenced carrier residuals and separability.
            %
            % cpInfoSeries : cell array of cpInfo structs returned by buildEkfRows.
            %   Each entry has fields: towerIdx, antennaIdx, phi_m (z_phi), prefit_m.
            % cfg          : config struct (for geometry and settings).
            % leverArms_body_m : [3 x nRx] lever arms in body frame.
            %
            % Returns result struct with fields:
            %   nDifferences   : number of baseline-differenced pairs computed
            %   residualsRMS_m : RMS of raw delta_phi (not ambiguity-corrected)
            %   separable      : always false with free float ambiguities
            %   note           : explanatory string

            result.nDifferences    = 0;
            result.residualsRMS_m  = NaN;
            result.separable       = false;
            result.note = ['With free float ambiguities (one per row), H_amb spans R^M. ' ...
                'Attitude is never separable. Baseline differencing does not resolve this.'];

            if isempty(cpInfoSeries) || ~iscell(cpInfoSeries)
                return
            end
            nRx = size(leverArms_body_m, 2);
            if nRx < 2
                result.note = 'Need nRx >= 2 for baseline differencing.';
                return
            end

            deltas = zeros(0,1);
            for k = 1:numel(cpInfoSeries)
                cp = cpInfoSeries{k};
                if isempty(cp) || ~isfield(cp,'phi_m') || ~isfield(cp,'towerIdx')
                    continue
                end
                tiList = unique(cp.towerIdx);
                for ti = tiList(:)'
                    rowRef = find(cp.towerIdx == ti & cp.antennaIdx == 1, 1);
                    if isempty(rowRef); continue; end
                    phi_ref = cp.phi_m(rowRef);
                    for ai = 2:nRx
                        rowAi = find(cp.towerIdx == ti & cp.antennaIdx == ai, 1);
                        if isempty(rowAi); continue; end
                        deltas(end+1,1) = cp.phi_m(rowAi) - phi_ref; %#ok<AGROW>
                    end
                end
            end

            result.nDifferences   = numel(deltas);
            if result.nDifferences > 0
                result.residualsRMS_m = rms(deltas);
            end
        end

        function explain()
            % explain  Print separability analysis to console.
            fprintf('\nATTITUDE-AMBIGUITY SEPARABILITY (Stage 14.9)\n');
            fprintf('=============================================\n');
            fprintf('With M float ambiguity states for M carrier measurements:\n');
            fprintf('  H_amb = I_{M×M}  →  rank(H_amb) = M\n');
            fprintf('  H_att ∈ R^{M×3}  →  H_att ⊆ span(H_amb)\n');
            fprintf('  rank([H_att H_amb]) = rank(H_amb) = M\n');
            fprintf('Attitude is NOT separable from free float ambiguities.\n\n');
            fprintf('Baseline differencing (phi_i - phi_ref, same tower):\n');
            fprintf('  Cancels b_rx and b_twr, but keeps M-nTowers differential ambiguities.\n');
            fprintf('  One differential ambiguity per row → still not separable.\n\n');
            fprintf('Resolution: fixed/known ambiguities (validated by knownAmbiguityAttitudeValidation).\n');
        end

    end
end
