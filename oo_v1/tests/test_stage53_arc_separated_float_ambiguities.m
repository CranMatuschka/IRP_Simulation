function results = test_stage53_arc_separated_float_ambiguities()
% test_stage53_arc_separated_float_ambiguities  Stage 53 arc-separated ambiguity tests.
%
% T1: CarrierTrackManager arc ID initialises to 1, increments on slip
% T2: getArcStateForRows returns correct arcId and currentArcEpoch per row
% T3: AmbiguityArcState.fromCpInfo with arcId field → available=true, nUniqueArcIds>0
% T4: AmbiguityArcState.fromCpInfo without arcId → available=false
% T5: CarrierIonoFreeRowBuilder arc consistency — consistent when arcIdL1==arcIdL2

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: CarrierTrackManager arc ID initialises to 1 and increments on slip
try
    tm1 = revgnss.CarrierTrackManager();
    cfg1.measurements.carrier.slipDetection.enable                = true;
    cfg1.measurements.carrier.slipDetection.threshold_m           = 0.1;
    cfg1.measurements.carrier.slipDetection.minEpochsBeforeDetect = 1;
    cfg1.measurements.carrier.slipDetection.action                = 'resetAndSkip';

    % Epoch 1: normal observation → arcId should become 1.
    cp1.towerIdx  = 1; cp1.antennaIdx = 1; cp1.signalIdx = 1;
    cp1.prefit_m  = 0.01;
    cp1.trackKey  = {'T001_A001_S01'};
    [~, ~, ~] = tm1.process(cp1, cfg1);
    as1 = tm1.getArcStateForRows(cp1);
    assert(as1.arcId(1) == 1, 'T1: arcId must be 1 after first epoch');

    % Epoch 2: large jump (slip) → arcId should increment to 2.
    cp2.towerIdx  = 1; cp2.antennaIdx = 1; cp2.signalIdx = 1;
    cp2.prefit_m  = 50.0;   % well above threshold
    cp2.trackKey  = {'T001_A001_S01'};
    [~, ~, ~] = tm1.process(cp2, cfg1);
    as2 = tm1.getArcStateForRows(cp2);
    assert(as2.arcId(1) == 2, 'T1: arcId must be 2 after a slip');
    results(end+1) = struct('name','T1_arcId_increments_on_slip','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_arcId_increments_on_slip','passed',false,'message',ex.message);
end

%% T2: getArcStateForRows returns correct per-row arc metadata
try
    tm2 = revgnss.CarrierTrackManager();
    cfg2.measurements.carrier.slipDetection.enable                = true;
    cfg2.measurements.carrier.slipDetection.threshold_m           = 0.1;
    cfg2.measurements.carrier.slipDetection.minEpochsBeforeDetect = 1;
    cfg2.measurements.carrier.slipDetection.action                = 'resetAndSkip';

    % Two tracks, both normal.
    cp2a.towerIdx   = [1; 2];
    cp2a.antennaIdx = [1; 1];
    cp2a.signalIdx  = [1; 1];
    cp2a.prefit_m   = [0.01; 0.02];
    cp2a.trackKey   = {'T001_A001_S01','T002_A001_S01'};
    [~, ~, ~] = tm2.process(cp2a, cfg2);
    as2 = tm2.getArcStateForRows(cp2a);
    assert(numel(as2.arcId) == 2,       'T2: arcId must have 2 elements');
    assert(all(as2.arcId == 1),         'T2: all arcIds must be 1 after first epoch');
    assert(all(as2.currentArcEpoch == 1), 'T2: currentArcEpoch must be 1 after first epoch');
    assert(all(as2.slipCount == 0),     'T2: slipCount must be 0 with no slips');
    results(end+1) = struct('name','T2_getArcStateForRows_per_row','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_getArcStateForRows_per_row','passed',false,'message',ex.message);
end

%% T3: AmbiguityArcState.fromCpInfo with arcId → available=true
try
    cp3.towerIdx        = [1; 1];
    cp3.antennaIdx      = [1; 1];
    cp3.signalIdx       = [1; 2];
    cp3.trackKey        = {'T001_A001_S01','T001_A001_S02'};
    cp3.arcId           = [1; 1];
    cp3.currentArcEpoch = [120; 120];
    cp3.slipCount       = [0; 0];
    cp3.ionoFreeCombined = false;
    aas3 = revgnss.AmbiguityArcState.fromCpInfo(cp3);
    assert(aas3.arcMetadataAvailable,      'T3: arcMetadataAvailable must be true');
    assert(aas3.nUniqueArcIds == 1,        'T3: nUniqueArcIds must be 1');
    assert(aas3.nRowsMissingArcId == 0,   'T3: nRowsMissingArcId must be 0');
    assert(aas3.nRows == 2,               'T3: nRows must be 2');
    assert(isfinite(aas3.meanArcEpoch),   'T3: meanArcEpoch must be finite');
    results(end+1) = struct('name','T3_fromCpInfo_with_arcId','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_fromCpInfo_with_arcId','passed',false,'message',ex.message);
end

%% T4: AmbiguityArcState.fromCpInfo without arcId → available=false
try
    cp4.towerIdx   = [1];
    cp4.antennaIdx = [1];
    cp4.signalIdx  = [1];
    cp4.trackKey   = {'T001_A001_S01'};
    % No arcId field.
    aas4 = revgnss.AmbiguityArcState.fromCpInfo(cp4);
    assert(~aas4.arcMetadataAvailable, 'T4: arcMetadataAvailable must be false without arcId');
    assert(strcmp(aas4.classification,'unavailable'), 'T4: classification must be unavailable');
    results(end+1) = struct('name','T4_fromCpInfo_no_arcId_unavailable','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_fromCpInfo_no_arcId_unavailable','passed',false,'message',ex.message);
end

%% T5: CarrierIonoFreeRowBuilder arc consistency fields
try
    % Build a minimal cpInfo with arcId to test arc consistency attachment.
    % Use arcId=[1;1] for idx1, [1;1] for idx2 → all consistent.
    Mp = 2;
    nSt = 8;  % dummy state size
    cpIF5.towerIdx          = [1;1;1;1];
    cpIF5.antennaIdx        = [1;1;1;1];
    cpIF5.signalIdx         = [1;1;2;2];
    cpIF5.phi_m             = [0.1;0.2;0.15;0.25];
    cpIF5.prefit_m          = [0.01;0.02;0.01;0.02];
    cpIF5.trackKey          = {'T001_A001_S01','T002_A001_S01', ...
                               'T001_A001_S02','T002_A001_S02'};
    cpIF5.ambiguityStateIdx = [1;2;3;4];
    cpIF5.arcId             = [1;1;1;1];  % all arc ID 1
    z5 = [0.1;0.2;0.15;0.25];
    h5 = [0.09;0.19;0.14;0.24];
    H5 = eye(4, nSt);
    R5 = 0.01 * eye(4);
    cfg5.signals.twoFrequency.enable = true;
    [~,~,~,~,cpIF_out] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z5, h5, H5, R5, cpIF5, Mp, cfg5);
    assert(isfield(cpIF_out,'arcIdL1'),        'T5: arcIdL1 must be set');
    assert(isfield(cpIF_out,'arcIdL2'),        'T5: arcIdL2 must be set');
    assert(isfield(cpIF_out,'arcConsistent'),  'T5: arcConsistent must be set');
    assert(all(cpIF_out.arcConsistent),        'T5: all pairs must be arc-consistent when arcIdL1==arcIdL2');
    assert(cpIF_out.nArcConsistentPairs == Mp,  'T5: nArcConsistentPairs must equal Mp');
    assert(cpIF_out.nArcInconsistentPairs == 0, 'T5: nArcInconsistentPairs must be 0');
    results(end+1) = struct('name','T5_if_arc_consistency_check','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T5_if_arc_consistency_check','passed',false,'message',ex.message);
end

end
