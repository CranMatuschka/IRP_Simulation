function results = test_stage47_carrier_iono_free_float_rows()
% test_stage47_carrier_iono_free_float_rows  Stage 47 carrier IF float EKF row tests.
%
% T1: shouldCombine returns true/false per toggle state.
% T2: buildFromStack produces correct IF z/h/H/R from synthetic L1+L2 data.
% T3: CarrierIonoFreeEkfDiagnostics — no false claims (integer/PPP/fixed).
% T4: combineJacobians explicit combination and dimension-mismatch throw.

results = struct('name', {}, 'passed', {}, 'message', {});
results = addTest(results, 'T1_shouldCombine',         @t1_shouldCombine);
results = addTest(results, 'T2_buildFromStack',        @t2_buildFromStack);
results = addTest(results, 'T3_no_false_claims',       @t3_no_false_claims);
results = addTest(results, 'T4_combineJacobians',      @t4_combineJacobians);
end

% -----------------------------------------------------------------------

function t1_shouldCombine()
cfg_off = struct();
assert(~revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg_off), ...
    'T1: shouldCombine must be false when no toggles set');

cfg_en = struct();
cfg_en.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg_en.measurements.carrier.ionosphereFreeRows.useInEkf = false;
assert(~revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg_en), ...
    'T1: shouldCombine must be false when enable=true but useInEkf=false');

cfg_full = struct();
cfg_full.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg_full.measurements.carrier.ionosphereFreeRows.useInEkf = true;
assert(revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg_full), ...
    'T1: shouldCombine must be true when both toggles active');
end

function t2_buildFromStack()
% Synthetic L1+L2 carrier rows (Mp=3, nx=7)
Mp = 3;
nx = 7;
Mp_total = 2 * Mp;

sigL1 = revgnss.SignalDefinition.get('L1');
sigL2 = revgnss.SignalDefinition.get('L2');
[alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
    sigL1.frequency_Hz, sigL2.frequency_Hz);

z_raw = [10; 11; 12; 20; 21; 22];   % L1: 10-12, L2: 20-22
h_raw = [ 9;  10;  11; 19; 20; 21];
H_L1  = ones(Mp, nx);
H_L2  = 2 * ones(Mp, nx);
H_raw = [H_L1; H_L2];

sigma_L1 = 2;  sigma_L2 = 3;
R_raw = blkdiag(sigma_L1^2 * eye(Mp), sigma_L2^2 * eye(Mp));

cpInfo.phi_m             = z_raw;
cpInfo.prefit_m          = z_raw - h_raw;
cpInfo.towerIdx          = [1;2;3;1;2;3];
cpInfo.antennaIdx        = [1;1;1;1;1;1];
cpInfo.signalIdx         = [1;1;1;2;2;2];
cpInfo.ambiguityStateIdx = [4;5;6;4;5;6];
cpInfo.trackKey          = {'k1';'k2';'k3';'k4';'k5';'k6'};

cfg = struct();
cfg.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;

[z_IF, h_IF, H_IF, R_IF, cpIF] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
    z_raw, h_raw, H_raw, R_raw, cpInfo, Mp, cfg);

% z_IF
z_exp = alpha * z_raw(1:Mp) + beta * z_raw(Mp+1:end);
assert(norm(z_IF - z_exp) < 1e-9, ...
    sprintf('T2: z_IF mismatch; max err=%.2e', max(abs(z_IF - z_exp))));

% h_IF
h_exp = alpha * h_raw(1:Mp) + beta * h_raw(Mp+1:end);
assert(norm(h_IF - h_exp) < 1e-9, ...
    sprintf('T2: h_IF mismatch; max err=%.2e', max(abs(h_IF - h_exp))));

% H_IF = alpha*H_L1 + beta*H_L2 (per row; geometry non-dispersive, alpha+beta=1)
H_exp = alpha * H_L1 + beta * H_L2;
assert(norm(H_IF - H_exp) < 1e-9, ...
    sprintf('T2: H_IF mismatch; max err=%.2e', max(max(abs(H_IF - H_exp)))));

% R_IF diagonal: alpha²*sigma_L1² + beta²*sigma_L2²
r_exp = alpha^2 * sigma_L1^2 + beta^2 * sigma_L2^2;
r_IF_diag = diag(R_IF);
assert(all(abs(r_IF_diag - r_exp) < 1e-9), ...
    sprintf('T2: R_IF diagonal mismatch; max err=%.2e', max(abs(r_IF_diag - r_exp))));

% cpInfo_IF shape
assert(numel(cpIF.towerIdx) == Mp,        'T2: cpInfo_IF.towerIdx must have Mp entries');
assert(numel(cpIF.ambiguityStateIdx) == Mp,'T2: ambiguityStateIdx must have Mp entries');
assert(cpIF.ionoFreeCombined == true,      'T2: ionoFreeCombined must be true');
assert(abs(cpIF.ifAlpha - alpha) < 1e-12,  'T2: ifAlpha must match');
assert(abs(cpIF.ifBeta  - beta)  < 1e-12,  'T2: ifBeta must match');

% Signal slots: all IF rows use signal slot 1
assert(all(cpIF.signalIdx == 1), 'T2: signalIdx must all be 1 for IF rows');
end

function t3_no_false_claims()
cfg = struct();
cfg.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
cfg.signals.twoFrequency.enable = true;
cfg.measurements.carrierMode    = 'ekfFloat';

sm = struct('totalCarrierIfRows', 15);
s = revgnss.CarrierIonoFreeEkfDiagnostics.assess(sm, cfg);

assert(~s.integerFixingImplemented,         'T3: integerFixingImplemented must be false');
assert(~s.lambdaImplemented,                'T3: lambdaImplemented must be false');
assert(~s.calibratedDcbProductsAvailable,   'T3: calibratedDcbProductsAvailable must be false');
assert(s.integerAmbiguityIsNonInteger,      'T3: integerAmbiguityIsNonInteger must be true');

forbidden = {'ppp','fixed','precise','operational','integer-ready','integer_ready','lambda-ready'};
for k = 1:numel(forbidden)
    assert(isempty(strfind(lower(s.classification), forbidden{k})), ...
        sprintf('T3: classification must not contain "%s"; got: %s', forbidden{k}, s.classification));
end
assert(strcmp(s.carrierIfIntegerReadyClassification, 'not-integer-ready-float-only'), ...
    sprintf('T3: expected not-integer-ready-float-only, got %s', ...
            s.carrierIfIntegerReadyClassification));

validClasses = {'disabled','requested-no-l2','requested-not-ekf-float', ...
    'requested-metadata-unavailable','active-carrier-if-ekf-float'};
assert(ismember(s.classification, validClasses), ...
    sprintf('T3: classification "%s" not in allowed set', s.classification));

% When disabled
cfg2 = struct();
s2 = revgnss.CarrierIonoFreeEkfDiagnostics.assess(struct(), cfg2);
assert(strcmp(s2.classification, 'disabled'), 'T3: disabled classification expected');

% When L2 missing
cfg3 = struct();
cfg3.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg3.measurements.carrier.ionosphereFreeRows.useInEkf = true;
s3 = revgnss.CarrierIonoFreeEkfDiagnostics.assess(struct(), cfg3);
assert(strcmp(s3.classification, 'requested-no-l2'), ...
    sprintf('T3: expected requested-no-l2, got %s', s3.classification));
end

function t4_combineJacobians()
nx = 7;
H_L1 = ones(1,nx);
H_L2 = 2*ones(1,nx);

sigL1 = revgnss.SignalDefinition.get('L1');
sigL2 = revgnss.SignalDefinition.get('L2');
[alpha, beta] = revgnss.IonoFreeCombination.coefficients( ...
    sigL1.frequency_Hz, sigL2.frequency_Hz);
H_expected = alpha*H_L1 + beta*H_L2;

H_IF = revgnss.CarrierIonoFreeRowBuilder.combineJacobians(H_L1, H_L2);
assert(norm(H_IF - H_expected) < 1e-9, ...
    sprintf('T4: combineJacobians mismatch; max err=%.2e', max(abs(H_IF - H_expected))));

% Dimension mismatch must throw
threw = false;
try
    revgnss.CarrierIonoFreeRowBuilder.combineJacobians(ones(1,5), ones(1,7));
catch
    threw = true;
end
assert(threw, 'T4: combineJacobians must throw on H dimension mismatch');

% Multi-row case: geometry non-dispersive → H_IF = H_geometry (alpha+beta=1)
Mp = 4;
H_geo = rand(Mp, nx);  % pure geometry Jacobian rows (same for L1 and L2)
H_IF_geo = revgnss.CarrierIonoFreeRowBuilder.combineJacobians(H_geo, H_geo);
% alpha+beta=1 and H_L1=H_L2=H_geo → H_IF = H_geo
assert(norm(H_IF_geo - H_geo) < 1e-9, ...
    'T4: H_IF must equal H_geometry when H_L1=H_L2 (non-dispersive geometry)');
end

% -----------------------------------------------------------------------

function results = addTest(results, name, fn)
try
    fn();
    results(end+1) = struct('name', name, 'passed', true, 'message', '');
catch ex
    results(end+1) = struct('name', name, 'passed', false, 'message', ex.message);
end
end
