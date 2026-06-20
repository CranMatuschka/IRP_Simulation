function results = test_stage52_carrier_arc_evidence()
% test_stage52_carrier_arc_evidence  Stage 52 carrier arc evidence tests.
%
% T1: fromSummary with no-slip arc data → available=true, nArcs>0,
%     classification='arcs-exported'
% T2: fromSummary with slip events → nSlipEvents>0,
%     classification='arcs-exported-with-slips'
% T3: arcQuality uses Stage 52 summary fields → available=true when
%     carrierArcEvidenceAvailable=true
% T4: no false claims — available=false without carrier arc data

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: no-slip arc evidence from summary
try
    s1.carrierArcEvidenceAvailable      = true;
    s1.carrierArcEvidenceClassification = 'arcs-exported';
    s1.carrierArcNActiveTracks          = 3;
    s1.carrierArcNArcs                  = 3;
    s1.carrierArcNSlipEvents            = 0;
    s1.carrierArcTotalEpochs            = 3600;
    s1.carrierArcMinLength_s            = 1200.0;
    s1.carrierArcMeanLength_s           = 1200.0;
    s1.carrierArcMaxLength_s            = 1200.0;
    ae1 = revgnss.CarrierArcEvidence.fromSummary(s1);
    assert(ae1.available,                            'T1: available must be true');
    assert(ae1.nArcs > 0,                            'T1: nArcs must be > 0');
    assert(strcmp(ae1.classification,'arcs-exported'), 'T1: classification must be arcs-exported');
    assert(ae1.nActiveTracks == 3,                   'T1: nActiveTracks must be 3');
    assert(ae1.nSlipEvents == 0,                     'T1: nSlipEvents must be 0');
    assert(abs(ae1.minArcLength_s - 1200) < 1e-9,   'T1: minArcLength_s mismatch');
    results(end+1) = struct('name','T1_no_slip_arc_from_summary','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_no_slip_arc_from_summary','passed',false,'message',ex.message);
end

%% T2: slip-split arc evidence from summary
try
    s2.carrierArcEvidenceAvailable      = true;
    s2.carrierArcEvidenceClassification = 'arcs-exported-with-slips';
    s2.carrierArcNActiveTracks          = 2;
    s2.carrierArcNArcs                  = 4;
    s2.carrierArcNSlipEvents            = 2;
    s2.carrierArcTotalEpochs            = 1800;
    s2.carrierArcMinLength_s            = 300.0;
    s2.carrierArcMeanLength_s           = 450.0;
    s2.carrierArcMaxLength_s            = 600.0;
    ae2 = revgnss.CarrierArcEvidence.fromSummary(s2);
    assert(ae2.available,                                       'T2: available must be true');
    assert(ae2.nSlipEvents > 0,                                 'T2: nSlipEvents must be > 0');
    assert(strcmp(ae2.classification,'arcs-exported-with-slips'), ...
        'T2: classification must be arcs-exported-with-slips');
    assert(ae2.nArcs == 4,                                      'T2: nArcs must be 4');
    results(end+1) = struct('name','T2_slip_split_arc_from_summary','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_slip_split_arc_from_summary','passed',false,'message',ex.message);
end

%% T3: gate arcQuality uses Stage 52 summary fields
try
    s3.carrierArcEvidenceAvailable = true;
    s3.carrierArcNSlipEvents       = 0;
    s3.carrierArcMinLength_s       = 900.0;
    cfg3.measurements.carrier.slipDetection.enable = true;
    aq3 = revgnss.AmbiguityFixingReadinessGate.arcQuality(s3, cfg3);
    assert(aq3.available,                            'T3: arcQuality must be available');
    assert(aq3.slipCount == 0,                       'T3: slipCount must be 0');
    assert(abs(aq3.minArcLength_s - 900) < 1e-9,    'T3: minArcLength_s mismatch');
    assert(strcmp(aq3.classification,'no-slips-reported'), ...
        'T3: classification must be no-slips-reported');
    results(end+1) = struct('name','T3_gate_uses_stage52_fields','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_gate_uses_stage52_fields','passed',false,'message',ex.message);
end

%% T4: no false claims — unavailable without carrier arc data
try
    ae4 = revgnss.CarrierArcEvidence.fromSummary(struct());
    assert(~ae4.available, 'T4: available must be false when no arc data in summary');
    assert(strcmp(ae4.classification,'unavailable'), 'T4: classification must be unavailable');
    % fromTrackManager with empty input also returns unavailable
    ae4b = revgnss.CarrierArcEvidence.fromTrackManager([], struct());
    assert(~ae4b.available, 'T4: fromTrackManager with [] must return available=false');
    results(end+1) = struct('name','T4_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_no_false_claims','passed',false,'message',ex.message);
end

end
