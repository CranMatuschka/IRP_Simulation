classdef AttitudeJacobianAudit
    % AttitudeJacobianAudit  Stage 34 attitude Jacobian consistency audit.
    %
    % Compares H attitude columns against finite-difference range partials when
    % per-row LOS + lever metadata is available. When only row-type strings are
    % available (production), falls back to H-only summary (metadata-unavailable).
    %
    % Classifications (in priority order):
    %   'not-estimated'                  -- Euler states absent from stateMap
    %   'no-attitude-columns'            -- H empty or all attitude cols zero
    %   'zero-lever-arm-zero-sensitivity'-- lever zero AND H att cols near-zero
    %   'metadata-unavailable-h-only'    -- no per-row LOS metadata; H summary only
    %   'finite-diff-consistent'         -- finite-diff agrees with H attitude rows
    %   'finite-diff-inconsistent'       -- mismatch found between H and finite-diff
    %   'diagnostic-only'                -- fallback
    %
    % Usage:
    %   s = revgnss.AttitudeJacobianAudit.audit(H, stateMap, cfg, rowMeta)
    %   J = revgnss.AttitudeJacobianAudit.finiteDiffRangeAttitudePartial(rpy,lev,los)
    %   h = revgnss.AttitudeJacobianAudit.hOnlySummary(H, eulerIdx)

    methods (Static)

        function s = audit(H, stateMap, cfg, rowMeta)
            % audit  Classify attitude Jacobian consistency.
            %
            % rowMeta is normally measTypePerRow (cell of type strings) from
            % ObservabilityDiagnostics — no LOS data, so finiteDiffAvailable=false.
            % Pass structs with fields los_ref_unit/lever_body_m/rpy_rad per row
            % for the finite-diff path (test harness or future integration).
            if nargin < 4; rowMeta = {}; end
            s = revgnss.AttitudeJacobianAudit.blankStruct_();

            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeJacobianAudit') && ...
                    isfield(cfg.diagnostics.attitudeJacobianAudit,'enable')
                s.enabled = logical(cfg.diagnostics.attitudeJacobianAudit.enable);
            end
            if ~s.enabled; return; end

            if isempty(H) || ~isnumeric(H)
                s.classification = 'no-attitude-columns';
                s.warnings{end+1} = 'H is empty; attitude Jacobian audit skipped.';
                return
            end

            [M, nx] = size(H);
            s.nRows = M;

            % Euler state indices
            if isfield(stateMap,'euler_idx')
                s.eulerIdx = stateMap.euler_idx(:)';
            end
            if isempty(s.eulerIdx) || max(s.eulerIdx) > nx
                s.classification = 'not-estimated';
                return
            end

            % H-only summary (always computed when Euler states present)
            hs = revgnss.AttitudeJacobianAudit.hOnlySummary(H, s.eulerIdx);
            s.attitudeColumnNorm       = hs.norm;
            s.attitudeRank             = hs.rank;
            s.attitudeCondition        = hs.condition;
            s.attitudeSensitiveRowCount = hs.nSensitiveRows;

            % Lever-arm check via AttitudeObservability (gated: missing cfg -> skip)
            hasNonzeroLever = false;
            try
                la = revgnss.AttitudeObservability.leverArmStats(cfg);
                hasNonzeroLever = la.hasNonzeroLeverArm;
            catch; end

            if ~hasNonzeroLever && s.attitudeColumnNorm < 1e-12
                s.classification = 'zero-lever-arm-zero-sensitivity';
                s.warnings{end+1} = ...
                    'Zero lever arms and near-zero H attitude columns: no attitude sensitivity.';
                return
            end

            if ~hasNonzeroLever && s.attitudeColumnNorm >= 1e-12
                s.warnings{end+1} = sprintf( ...
                    'Zero lever arms but nonzero H attitude column norm (%.2e): possible inconsistency.', ...
                    s.attitudeColumnNorm);
            end

            % Check whether rowMeta carries per-row LOS struct metadata
            hasLosMeta = false;
            if iscell(rowMeta) && numel(rowMeta) == M && M > 0
                r1 = rowMeta{1};
                hasLosMeta = isstruct(r1) && isfield(r1,'los_ref_unit') && ...
                             isfield(r1,'lever_body_m') && isfield(r1,'rpy_rad');
            end

            if ~hasLosMeta
                s.nRowsWithMetadata   = 0;
                s.finiteDiffAvailable = false;
                s.classification      = 'metadata-unavailable-h-only';
                if s.attitudeColumnNorm < 1e-12
                    s.warnings{end+1} = ...
                        'H attitude columns near-zero; check lever-arm geometry and measurement rows.';
                end
                return
            end

            % --- Finite-difference consistency check ---
            s.finiteDiffAvailable = true;
            s.nRowsWithMetadata   = M;
            eulerColsInH = s.eulerIdx(s.eulerIdx <= nx);
            allDiffs     = zeros(1, M);
            nChecked     = 0;

            for i = 1:M
                meta = rowMeta{i};
                try
                    J_fd  = revgnss.AttitudeJacobianAudit.finiteDiffRangeAttitudePartial( ...
                                meta.rpy_rad, meta.lever_body_m, meta.los_ref_unit);
                    h_row = H(i, eulerColsInH);
                    if numel(h_row) == 3
                        nChecked = nChecked + 1;
                        d = max(abs(J_fd - h_row));
                        s.maxAbsDiff = max(s.maxAbsDiff, d);
                        allDiffs(nChecked) = d;
                        if d < 1e-4
                            s.nFiniteDiffPass = s.nFiniteDiffPass + 1;
                        else
                            s.nFiniteDiffFail = s.nFiniteDiffFail + 1;
                            s.warnings{end+1} = sprintf('Row %d: max|H-Jfd|=%.2e', i, d);
                        end
                    end
                catch ex
                    s.warnings{end+1} = sprintf('Row %d fd error: %s', i, ex.message);
                end
            end

            s.nRowsCheckedFiniteDiff = nChecked;
            if nChecked > 0
                s.rmsDiff = rms(allDiffs(1:nChecked));
                if s.nFiniteDiffFail == 0
                    s.classification = 'finite-diff-consistent';
                else
                    s.classification = 'finite-diff-inconsistent';
                    s.warnings{end+1} = sprintf('%d/%d rows inconsistent (tol 1e-4 m/rad).', ...
                        s.nFiniteDiffFail, nChecked);
                end
            end
        end

        function J = finiteDiffRangeAttitudePartial(rpy_rad, lever_body_m, los_ref_unit)
            % finiteDiffRangeAttitudePartial  d/d(rpy)[los' * C(rpy) * lever], 1x3.
            %
            % Computes the finite-difference partial of pseudorange w.r.t. the three
            % Euler angles using a symmetric difference quotient (eps = 1e-6 rad).
            eps_rad = 1e-6;
            rpy = rpy_rad(:);
            lev = lever_body_m(:);
            los = los_ref_unit(:);
            if norm(los) > 0; los = los / norm(los); end
            J = zeros(1, 3);
            for k = 1:3
                dp = rpy; dp(k) = dp(k) + eps_rad;
                dm = rpy; dm(k) = dm(k) - eps_rad;
                Cp = revgnss.AttitudeKinematics.bodyToEcefRotation(dp);
                Cm = revgnss.AttitudeKinematics.bodyToEcefRotation(dm);
                J(k) = (los' * Cp * lev - los' * Cm * lev) / (2 * eps_rad);
            end
        end

        function hs = hOnlySummary(H, eulerIdx)
            % hOnlySummary  Frobenius norm, rank, and condition of H attitude columns.
            hs.norm         = 0;
            hs.rank         = 0;
            hs.condition    = NaN;
            hs.nSensitiveRows = 0;
            if isempty(H) || isempty(eulerIdx); return; end
            [M, nx] = size(H);
            attIdx  = eulerIdx(eulerIdx <= nx);
            if isempty(attIdx); return; end
            H_att   = H(:, attIdx);
            hs.norm = norm(H_att, 'fro');
            if hs.norm < 1e-15; return; end
            sv      = svd(H_att);
            tol     = max(M, numel(attIdx)) * eps(hs.norm);
            sv_pos  = sv(sv > tol);
            hs.rank = numel(sv_pos);
            if numel(sv_pos) >= 2
                hs.condition = sv_pos(1) / sv_pos(end);
            end
            rowNorms = vecnorm(H_att, 2, 2);
            maxRN    = max(rowNorms);
            if maxRN > 0
                hs.nSensitiveRows = sum(rowNorms > 0.01 * maxRN);
            end
        end

    end

    methods (Static, Access = private)

        function s = blankStruct_()
            s.enabled                   = false;
            s.nRows                     = 0;
            s.eulerIdx                  = [];
            s.attitudeColumnNorm        = 0;
            s.attitudeRank              = 0;
            s.attitudeCondition         = NaN;
            s.attitudeSensitiveRowCount = 0;
            s.nRowsWithMetadata         = 0;
            s.nRowsCheckedFiniteDiff    = 0;
            s.nFiniteDiffPass           = 0;
            s.nFiniteDiffFail           = 0;
            s.maxAbsDiff                = 0;
            s.rmsDiff                   = NaN;
            s.finiteDiffAvailable       = false;
            s.classification            = 'diagnostic-only';
            s.warnings                  = {};
        end

    end
end
