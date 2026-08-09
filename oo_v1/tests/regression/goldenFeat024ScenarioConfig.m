function cfg = goldenFeat024ScenarioConfig(durationOverride_s)
%GOLDENFEAT024SCENARIOCONFIG  Frozen reference for the SCINTILLATION OBLIQUITY path.
%   Certifies cfg.errors.ionosphere.scintillation.obliquityModel = 'matchIonoMapping',
%   the consistency fix that stops the Conker S4 elevation scaling using a hardcoded
%   flat-Earth 1/sin(el) while effects.ionosphere.mappingModel selects 'thinShell' for
%   the first-order slant delay piercing the SAME layer.
%
%   WHY THIS FIXTURE EXISTS. The default ('simpleSecant') is already covered by the
%   three existing goldens -- and covered ONLY by two of them: the 'single' golden ships
%   S4zen = 0, which makes S4 identically zero and the obliquity structurally INERT, so
%   it cannot detect a regression in this path at all. Nothing gated the NON-default
%   branch. This fixture does: it freezes the numbers the 'matchIonoMapping' branch
%   produces, so a future edit to MappingFunctions.ionosphere, to the shell height, or
%   to scintObliquity_ is caught rather than absorbed.
%
%   CONSTRUCTION. Delegates to goldenRealismScenarioConfig and changes exactly ONE leaf.
%   That is deliberate: the realism fixture is the one that carries S4zen = 0.3 and
%   therefore exercises the clamp, and deriving from it means any delta between
%   golden_realism_<tier> and golden_feat024_<tier> is attributable to the obliquity
%   alone. It is the regression twin of the ladder rung
%   config/ladder/feat/feat024_scintObliquityMatchIono.json, which applies the same
%   single delta to golden_baseline.json.
%
%   MEASURED EFFECT (3600 s, seed 42, paired -- same unit normals rescaled): Stockholm
%   scintillation sigma 2.1213 m (clamped) -> 0.5188 m; network mean scintillation
%   variance 1.0592 -> 0.1729 m^2. See docs/golden_baseline_provenance.md section 13a.
%
%   The frozen NUMBERS live in golden/golden_feat024_<tier>.mat; only this construction
%   code evolves. durationOverride_s (optional): short SMOKE duration; empty = full.
    if nargin < 1; durationOverride_s = []; end
    thisDir = fileparts(mfilename('fullpath'));      % .../oo_v1/tests/regression
    addpath(thisDir);                                % goldenRealismScenarioConfig

    cfg = goldenRealismScenarioConfig(durationOverride_s);

    % --- The single delta this fixture certifies ----------------------------------------
    cfg.errors.ionosphere.scintillation.obliquityModel = 'matchIonoMapping';

    % Guard the premise rather than assume it: 'matchIonoMapping' resolves through
    % effects.ionosphere.mappingModel, and it is only a real change while that is
    % 'thinShell' and S4zen is non-zero. If a future default flip made either untrue this
    % fixture would silently become a duplicate of the realism golden and would certify
    % nothing, so fail loudly instead.
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
        ['This fixture certifies matchIonoMapping against a thinShell delay mapping, ' ...
         'but atmosphere.realisticProfile.effects.ionosphere.mappingModel is ''%s''. ' ...
         'The fixture would be a no-op duplicate of golden_realism.'], ...
        rp.effects.ionosphere.mappingModel);
    assert(rp.errors.ionosphere.scintillation.S4zen > 0, ...
        'goldenFeat024ScenarioConfig:inertS4zen', ...
        ['realisticProfile S4zen is 0, which makes S4 identically zero and the ' ...
         'obliquity structurally inert -- this fixture would certify nothing.']);
end
