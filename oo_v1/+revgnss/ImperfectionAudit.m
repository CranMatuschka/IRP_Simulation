classdef ImperfectionAudit
    % ImperfectionAudit  Predicates: does an effect leave a real truth~=model residual?
    %
    % Several effects (antenna PCO, hardware delay) are ENABLED in the shipped config yet
    % contribute EXACTLY ZERO to the innovation z-h, because truth and model apply the same
    % constant identically (it cancels) and/or the offset is zero. Reports must not advertise
    % such matched effects as active "imperfections". These predicates decide whether an
    % effect actually survives z-h, so the truth-estimation-separation audit / captions can be
    % conditioned on a REAL residual, and validateMasterConfig can warn on an inert-but-enabled
    % effect. They also flip to true when the gated opt-in residual channels are turned on.

    methods (Static)

        function tf = pcoLeavesResidual(cfg)
            % pcoLeavesResidual  True iff antenna PCO leaves a nonzero truth~=model residual.
            %   Matched (both sides apply the SAME offset) or zero offset -> false. True when
            %   the per-side enables are asymmetric with a nonzero offset, OR the gated
            %   truth-only calibration residual (effects.antennaPCO.calibrationResidual) is on
            %   with a nonzero magnitude.
            tf = false;
            try
                pco = cfg.effects.antennaPCO;
                tEn = isfield(pco,'truth') && islogical_(pco.truth.enable) && pco.truth.enable;
                mEn = isfield(pco,'model') && islogical_(pco.model.enable) && pco.model.enable;
                recv = getvec_(pco, 'receiverOffset_body_m');
                twr  = getvec_(pco, 'towerOffset_enu_m');
                anyOffset = any(abs(recv) > 0) || any(abs(twr) > 0);
                if xor(tEn, mEn) && anyOffset
                    tf = true;   % one side applies PCO, the other does not -> uncorrected in z-h
                end
                if isfield(pco,'calibrationResidual') && isfield(pco.calibrationResidual,'enable') && ...
                        pco.calibrationResidual.enable && (tEn || mEn)
                    cr = getvec_(pco.calibrationResidual, 'receiverOffset_body_m');
                    if any(abs(cr) > 0); tf = true; end
                end
            catch; end
        end

        function tf = hwDelayLeavesResidual(cfg)
            % hwDelayLeavesResidual  True iff hardware delay leaves a nonzero truth~=model residual.
            %   Matched constant (truth.default_m==model.default_m, both enabled) with the
            %   stochastic residual off -> false. True when the enables are asymmetric with a
            %   nonzero constant, the constants differ, or the truth-only stochastic residual
            %   (residualStochastic.enable + sigma_m>0 + truth.enable) is on.
            tf = false;
            try
                hc  = cfg.errors.hardwareDelay;
                tEn = isfield(hc,'truth') && hc.truth.enable;
                mEn = isfield(hc,'model') && hc.model.enable;
                tD  = 0; mD = 0;
                if isfield(hc,'truth') && isfield(hc.truth,'default_m'); tD = hc.truth.default_m; end
                if isfield(hc,'model') && isfield(hc.model,'default_m'); mD = hc.model.default_m; end
                if (xor(tEn, mEn) && (abs(tD) > 0 || abs(mD) > 0)) || (tEn && mEn && abs(tD - mD) > 0)
                    tf = true;
                end
                stoch = isfield(hc,'residualStochastic') && isfield(hc.residualStochastic,'enable') && ...
                        hc.residualStochastic.enable;
                sig = 0; if isfield(hc,'sigma_m'); sig = hc.sigma_m; end
                if stoch && sig > 0 && tEn; tf = true; end
            catch; end
        end

        function tf = pcoEnabled(cfg)
            % pcoEnabled  True iff antenna PCO is switched on at all (either side).
            tf = false;
            try
                pco = cfg.effects.antennaPCO;
                tf = (isfield(pco,'enable') && pco.enable) || ...
                     (isfield(pco,'truth') && pco.truth.enable) || ...
                     (isfield(pco,'model') && pco.model.enable);
            catch; end
        end

        function tf = hwDelayEnabled(cfg)
            % hwDelayEnabled  True iff hardware delay is switched on at all (either side).
            tf = false;
            try
                hc = cfg.errors.hardwareDelay;
                tf = (isfield(hc,'enable') && hc.enable) || ...
                     (isfield(hc,'truth') && hc.truth.enable) || ...
                     (isfield(hc,'model') && hc.model.enable);
            catch; end
        end

        function tf = secondaryClockConverges(d)
            % secondaryClockConverges  Honesty predicate. Pass when every ESTIMATED
            % secondary clock's final-third bias error stays within +/-3sigma with >=90%
            % coverage. HONEST by design: b_tx is observable only relative to the primary
            % clock (radial<->clock wall) and aliases the along-LOS product-position error,
            % so this fails on short runs / loose or absent product -- surface it, don't hide.
            tf = false;
            try
                if ~isstruct(d) || ~isfield(d,'secondaryClock'); return; end
                E = d.secondaryClock.error_m; S = d.secondaryClock.sigma_m;
                if isempty(E); return; end
                N = size(E,2); i0 = max(1, floor(2*N/3));
                ok = true;
                for r = 1:size(E,1)
                    e = E(r, i0:end); s = S(r, i0:end);
                    m = isfinite(e) & isfinite(s);
                    if ~any(m); ok = false; break; end
                    if mean(abs(e(m)) <= 3*s(m)) < 0.90; ok = false; break; end
                end
                tf = ok;
            catch; tf = false; end
        end

    end
end

% ---- file-scope helpers ----------------------------------------------------
function v = getvec_(s, f)
    v = zeros(3,1);
    if isfield(s, f) && isnumeric(s.(f)) && ~isempty(s.(f)); v = s.(f)(:); end
end

function tf = islogical_(x)
    tf = islogical(x) || isnumeric(x);
end
