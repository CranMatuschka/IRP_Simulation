function cfg = goldenCorrelatedScenarioConfig(durationOverride_s)
%GOLDENCORRELATEDSCENARIOCONFIG  Frozen CORRELATED-ERROR reference: the 4-antenna headline
%   golden with the two error terms whose R treatment is correlation-sensitive switched ON.
%
%   WHY THIS FIXTURE EXISTS. The Stage-85 gate could not see a whole class of change.
%   Resolved 2026-08-13, goldenHeadlineScenarioConfig comes out with
%       errors.hardwareDelay.sigma_m       = 0
%       errors.multipath.truth.enable      = false
%       errors.multipath.coloredGM.enable  = false
%   so every code path that depends on those terms is inert in the fixture. Two fixes landed
%   in 142cec3 -- the hwDelay common-mode off-diagonal in CodeMeasurementBuilder and the
%   per-signal multipath sharedThisCall memo in ErrorChain -- and BOTH goldens
%   (smoke 184/184, headline 183/183) passed at rtol 1e-9 while the fixes were active in the
%   tree. They passed because the fixture cannot reach the code, not because the numbers are
%   safe: golden_baseline.json, which the whole ladder is built on, resolves the same three
%   leaves to 0.05 / true / true. A gate that certifies "unchanged" for a change it
%   structurally cannot execute is worse than no gate, because it is quoted as evidence.
%
%   WHAT IT ADDS, AND WHY EACH ONE. Exactly three leaves differ from the headline golden.
%     1. errors.hardwareDelay.sigma_m = 0.05 (+ truth.enable) -- ErrorChain.hardwareDelay_
%        draws this with an EMPTY antenna argument, so every row of a tower gets a
%        bit-identical draw, and CodeMeasurementBuilder reuses it unchanged across signals.
%        The rows are therefore correlated at rho = +1 and R must carry the off-diagonal.
%        This is the ONLY shipped-fixture path that exercises corrSrcs_ beyond trop/iono.
%     2. errors.multipath.truth.enable + coloredGM.enable -- turns on the per-signal
%        Gauss-Markov chain in ErrorChain.multipathForSignal, which is the only caller of
%        the sharedThisCall memo. Without it the memo is dead code in every fixture.
%     3. sharedAcrossAntennas stays at the headline value; it is what makes the memo
%        load-bearing (aiKey collapses to 1, so all four antennas share one chain).
%
%   It delegates to goldenHeadlineScenarioConfig for EVERY other frozen pin, so the two
%   fixtures differ by exactly the terms named above and a diff between their goldens is
%   attributable to those terms alone. 4 antennas is deliberate: at nReceivers = 1 the
%   antenna-sharing memo is a strict no-op and the fixture would be blind again.
%
%   THIS FIXTURE IS NOT A CLAIM THAT 0.05 m IS THE RIGHT HARDWARE DELAY. It is the value
%   golden_baseline.json already ships, chosen here so the fixture exercises the same
%   magnitude the ladder does. The gate's job is to detect movement, not to endorse a budget.
%
%   The frozen NUMBERS live in golden/golden_correlated_<tier>.mat; only this construction
%   code evolves. durationOverride_s (optional): short SMOKE duration; empty = full tier.
    if nargin < 1; durationOverride_s = []; end
    cfg = goldenHeadlineScenarioConfig(durationOverride_s);

    % --- 1. Hardware delay: a per-TOWER error common to every antenna and signal row -----
    % truth.enable is set explicitly rather than relying on the master errors.hardwareDelay
    % switch: ErrorChain.hardwareDelay_ deliberately does NOT read that master flag (see its
    % header), so the truth/model pair is what actually gates the term.
    cfg.errors.hardwareDelay.sigma_m      = 0.05;
    cfg.errors.hardwareDelay.truth.enable = true;
    cfg.errors.hardwareDelay.model.enable = false;   % truth-only: leaves a real residual

    % --- 2. Coloured multipath, per signal, shared across the antenna cross --------------
    cfg.errors.multipath.truth.enable                       = true;
    cfg.errors.multipath.coloredGM.enable                   = true;
    cfg.errors.multipath.coloredGM.sharedAcrossAntennas.enable = true;
end
