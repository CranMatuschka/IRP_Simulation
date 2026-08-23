function test_distributed_covariance_network_link_graph_connectivity()
% test_distributed_covariance_network_link_graph_connectivity  Plan Section 3.5 item 2:
% linkGraphConnectivityReport is pure graph CONNECTIVITY (topology only -- whether a stored cross
% block exists for a pair is already binary, so no numerical tolerance is involved; full rigidity
% theory, which needs edge geometry not just topology, is deliberately out of scope). Real
% filter.ReverseGNSSEKF-backed network members throughout, no mocks.
%
% REACHABILITY NOTE (found while writing this test, confirmed by source inspection of
% +revgnss/DistributedCovarianceNetwork.m, and documented there on linkGraphConnectivityReport's
% own header): registerFleetMembers is explicitly one-shot for the WHOLE configured fleet, and
% declareIndependentPriorPairs unconditionally declares a cross block for EVERY pair among
% currently-registered members in a single call, with no method anywhere removing a crossBlocks_
% entry afterward. Together these mean isFullySpanning=false is NOT reachable via the public API
% on any network constructed the way IndependentFleetCoordinator.initialize() constructs one
% (registerFleetMembers then declareIndependentPriorPairs for the same fixed member set) -- there
% is no supported way to register a member and leave it with zero cross blocks to every other
% member. This test therefore exercises only the fully-spanning case, at two different fleet
% sizes, and does not fabricate a "partially spanning" fixture that would require bypassing the
% class's own invariants to construct. The union-find logic's isFullySpanning=false branch is
% still correct by code review (a plain, general label-propagation algorithm, not special-cased
% to the reachable case); it awaits a future stage that adds partial/incremental fleet membership
% before it can be live-exercised, matching this session's own established practice of recording
% exactly which branches are/aren't reachable rather than silently claiming untested coverage.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_covariance_network_link_graph_connectivity ===\n');
i_test_fully_spanning_two_member_();
i_test_fully_spanning_three_member_();
fprintf('=== test_distributed_covariance_network_link_graph_connectivity: ALL PASS ===\n');
end

% ================================================================================================
function i_test_fully_spanning_two_member_()
[network,~] = i_networkWithMembers_(2);
report = network.linkGraphConnectivityReport();
assert(report.memberCount==2 && report.trackedPairCount==1 && report.possiblePairCount==1, ...
    'a 2-member network must have exactly 1 possible and 1 tracked pair');
assert(report.connectedComponentCount==1 && report.isFullySpanning==true, ...
    'a 2-member network is trivially fully spanning');
fprintf('  PASS 2-member network: 1/1 pairs tracked, isFullySpanning=true\n');
end

% ================================================================================================
function i_test_fully_spanning_three_member_()
[network,ids] = i_networkWithMembers_(3);
report = network.linkGraphConnectivityReport();
fprintf('  memberCount=%d trackedPairCount=%d possiblePairCount=%d connectedComponentCount=%d isFullySpanning=%d\n', ...
    report.memberCount,report.trackedPairCount,report.possiblePairCount, ...
    report.connectedComponentCount,report.isFullySpanning);
assert(report.memberCount==3,'expected 3 members');
assert(report.trackedPairCount==3,'declareIndependentPriorPairs must have declared all 3 pairs');
assert(report.possiblePairCount==3,'expected nchoosek(3,2)=3 possible pairs');
assert(report.connectedComponentCount==1,'a fully-tracked 3-member network must be one component');
assert(report.isFullySpanning==true,'a fully-tracked 3-member network must report isFullySpanning=true');
assert(numel(unique(report.componentIdByMember))==1,'every member must share the same component id');
assert(numel(report.spannedPairs)==3,'spannedPairs must name all 3 declared pairs');
allNames = [report.spannedPairs{:}];
assert(isempty(setdiff(ids,unique(allNames))),'spannedPairs must collectively mention every member');
fprintf('  PASS 3-member network: 3/3 pairs tracked, isFullySpanning=true, all members co-located\n');
end

% ================================================================================================
function [network, ids] = i_networkWithMembers_(n)
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = arrayfun(@(k) sprintf('spacecraft:%d',k),1:n,'UniformOutput',false);
ekfs = cell(1,n); providers = cell(1,n);
for k = 1:n
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',max(n,2),'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
memberRecords = arrayfun(@(k) providers{k}.memberRegistrationRecord(0),1:n);
network.registerFleetMembers(memberRecords);
network.declareIndependentPriorPairs(0);
end
