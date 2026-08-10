function cfg = goldenFeat024ScenarioConfig(durationOverride_s)
%GOLDENFEAT024SCENARIOCONFIG  Frozen reference for the SCINTILLATION OBLIQUITY path.
%   Certifies cfg.errors.ionosphere.scintillation.obliquityModel = 'simpleSecant', the
%   legacy flat-Earth 1/sin(el) hardcode, against a run whose first-order slant delay
%   pierces the SAME layer through the thin shell.
%
%   THE POLARITY OF THIS FIXTURE FLIPPED ON 2026-08-09. masterConfig's default moved from
%   'simpleSecant' to 'matchIonoMapping' (see the block comment at that leaf for the
%   measured reason: the legacy over-mapping drove S4 through the min(0.7,.) clamp and
%   pinned the row sigma at a hardcoded 2.1213 m). The DEFAULT branch is therefore now
%   covered by the realism and headline goldens, and this fixture flipped to guard the
%   branch that is no longer the default, so BOTH obliquity paths stay frozen. The
%   numbers in golden/golden_feat024_<tier>.mat were re-captured in the same change and
%   are the legacy-secant numbers -- they are NOT comparable with the pre-flip captures.
%
%   WHY EITHER BRANCH NEEDS ITS OWN FIXTURE. The 'single' golden ships S4zen = 0, which
%   makes S4 identically zero and the obliquity structurally INERT, so it cannot detect a
%   regression in this path at all. Only a fixture built on the realism config -- which
%   carries S4zen = 0.3 and therefore exercises the clamp -- can.
%
%   CONSTRUCTION. Delegates to goldenRealismScenarioConfig and changes exactly ONE leaf,
%   so any delta between golden_realism_<tier> and golden_feat024_<tier> is attributable
%   to the obliquity alone. It is the regression twin of the ladder rung
%   config/ladder/feat/feat024_scintObliquityLegacySecant.json, which applies the same
%   single delta to golden_baseline.json.
%
%   The frozen NUMBERS live in golden/golden_feat024_<tier>.mat; only this construction
%   code evolves. durationOverride_s (optional): short SMOKE duration; empty = full.
    if nargin < 1; durationOverride_s = []; end
    thisDir = fileparts(mfilename('fullpath'));      % .../oo_v1/tests/regression
    addpath(thisDir);                                % goldenRealismScenarioConfig

    cfg = goldenRealismScenarioConfig(durationOverride_s);

    % --- The single delta this fixture certifies ----------------------------------------
    cfg.errors.ionosphere.scintillation.obliquityModel = 'simpleSecant';

    % Guard the premise rather than assume it. This fixture is only worth its runtime while
    % it differs from the realism golden, which needs THREE things to hold: the realistic
    % profile is actually merged, it selects a non-secant delay mapping, and S4zen is
    % non-zero so the obliquity is not structurally inert. If a future edit breaks any of
    % them the fixture would silently become a duplicate and certify nothing -- fail loudly.
    %
    % NOTE the values checked are the realisticProfile SOURCES, not the resolved leaves.
    % At fixture-construction time cfg.effects.ionosphere.mappingModel is still
    % masterConfig's 'simpleSecant' and scintillation.S4zen is still 0; both are replaced
    % when ConfigFactory.applyAtmosphereProfile deep-merges atmosphere.realisticProfile
    % during finalisation, i.e. INSIDE the run. Asserting on the resolved leaves here
    % fails against a correct config -- checking the source is what actually holds.
    assert(isfield(cfg.atmosphere,'realistic') && cfg.atmosphere.realistic, ...
        'goldenFeat024ScenarioConfig:profileNotApplied', ...
        ['atmosphere.realistic is not true, so the realistic-atmosphere profile will ' ...
         'never be merged and neither thinShell nor S4zen = 0.3 will reach the run.']);
    rp = cfg.atmosphere.realisticProfile;
    assert(strcmp(rp.effects.ionosphere.mappingModel,'thinShell'), ...
        'goldenFeat024ScenarioConfig:mappingModel', ...
        ['This fixture certifies simpleSecant against a thinShell delay mapping, but ' ...
         'atmosphere.realisticProfile.effects.ionosphere.mappingModel is ''%s''. The ' ...
         'fixture would be a no-op duplicate of golden_realism.'], ...
        rp.effects.ionosphere.mappingModel);
    assert(rp.errors.ionosphere.scintillation.S4zen > 0, ...
        'goldenFeat024ScenarioConfig:inertS4zen', ...
        ['realisticProfile S4zen is 0, which makes S4 identically zero and the ' ...
         'obliquity structurally inert -- this fixture would certify nothing.']);

    % The polarity guard: this fixture pins the NON-default branch. If masterConfig's
    % default is ever moved back to 'simpleSecant' the two configs coincide and the
    % coverage this fixture provides silently disappears.
    defaultObliquity = masterConfig('baseOnly');
    assert(~strcmp(defaultObliquity.errors.ionosphere.scintillation.obliquityModel, ...
                   'simpleSecant'), ...
        'goldenFeat024ScenarioConfig:polarity', ...
        ['masterConfig''s default obliquityModel is ''simpleSecant'' again, which is what ' ...
         'this fixture pins -- it now duplicates golden_realism. Flip this fixture to the ' ...
         'branch that is NOT the default so both paths stay frozen.']);
end
