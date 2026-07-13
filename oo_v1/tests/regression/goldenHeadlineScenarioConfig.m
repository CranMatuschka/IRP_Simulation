function cfg = goldenHeadlineScenarioConfig(durationOverride_s)
%GOLDENHEADLINESCENARIOCONFIG  Frozen HEADLINE reference: the single-antenna golden
%   baseline but with the 4-antenna cross (nReceivers=4, attitude ON).
%
%   Delegates to goldenScenarioConfig for EVERY frozen pin (nSpaceAssets=1, ISL off,
%   atmosphere.realistic=false, nTowers=5, report off, clock templateSource) and only
%   changes nReceivers to 4. This protects the attitude-path physics (carrier lever-arm
%   quaternion EKF) that the single-antenna golden cannot reach, while sharing the exact
%   clean matched contract so it stays byte-reproducible.
%
%   The frozen NUMBERS live in golden/golden_headline_<tier>.mat; only this construction
%   code evolves. durationOverride_s (optional): short SMOKE duration; empty = full 3600 s.
    if nargin < 1; durationOverride_s = []; end
    cfg = goldenScenarioConfig(durationOverride_s);

    % The only difference from the single-antenna golden: the 4-antenna cross. With
    % nReceivers=4 the masterConfig lever-arm cross is retained by finalizeConfig and
    % attitude estimation is turned ON (ConfigFactory auto-attitude else-branch).
    cfg.scenario.nReceivers = 4;
end
