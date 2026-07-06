function run_swarm_check(dur_s, tag)
% run_swarm_check  Run the swarm masterConfig for dur_s with full report + a KF
% consistency/convergence summary. Saves like the main runner (per-run folder).
%   run_swarm_check(600, 'reportcheck')
if nargin < 1 || isempty(dur_s); dur_s = 600; end
if nargin < 2 || isempty(tag);   tag   = 'swarmcheck'; end
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir); addpath(fullfile(thisDir,'config'));

cfg = masterConfig();                 % swarm default (nSpaceAssets>1)
cfg.simulation.duration_s = dur_s;
outRoot = fullfile(thisDir, 'output', ['Swarm_' tag]);
if ~isfolder(outRoot); mkdir(outRoot); end
cfg.report.reportFolder = outRoot;
cfg.report.stem = sprintf('swarm_%s_%ds', tag, round(dur_s));

out = revgnss.ReportRunner.runSingle(cfg);

% --- KF consistency / convergence summary (primary asset) -------------------
sim = out.sim; d = sim.simData; c = 299792458;
pe  = d.getPositionErrors(); cb = d.getClockBiasErrors(); nis = d.getNIS();
N = numel(pe); iS = max(1, N-round(0.2*N));
mNIS = mean(nis(iS:end),'omitnan');
% innovation whiteness: lag-1 autocorrelation of the NIS series (steady state)
xv = nis(iS:end); xv = xv(~isnan(xv)); xv = xv - mean(xv);
if numel(xv) > 3; ac1 = (xv(1:end-1)'*xv(2:end))/(xv'*xv); else; ac1 = NaN; end

fprintf('\n===== SWARM KF CHECK (%s, %d s) =====\n', tag, round(dur_s));
fprintf('nSpaceAssets=%d  baseline=%.0f m\n', cfg.scenario.nSpaceAssets, cfg.formation.baseline_m);
fprintf('primary pos last20 RMS = %.4f m\n', rms(pe(iS:end)));
fprintf('primary clock last20 RMS = %.4f m = %.1f ps\n', rms(cb(iS:end)), rms(cb(iS:end))/c*1e12);
fprintf('mean NIS(last20) = %.2f   innovation lag-1 autocorr = %.3f (want ~0)\n', mNIS, ac1);
% NEES (position+clock consistency): (x-xhat)' P^-1 (x-xhat) vs 4 DOF (expect ~4)
try
    ev = d.getPositionErrorVecs(); cbv = d.getClockBiasErrors(); Pd = d.getPdiag();
    ri = sim.ekf.stateMap.r_idx; bi = sim.ekf.stateMap.b_rx_idx;
    if size(Pd,2) ~= numel(pe); Pd = Pd'; end
    neePos = sum(ev.^2 ./ max(Pd(ri,:),eps), 1);
    neeClk = (cbv(:)').^2 ./ max(Pd(bi,:),eps);
    fprintf('mean NEES pos(last20)=%.2f (exp 3)  clock=%.2f (exp 1)\n', ...
        mean(neePos(iS:end),'omitnan'), mean(neeClk(iS:end),'omitnan'));
catch e; fprintf('NEES unavailable: %s\n', e.message); end
% Geodetic (lat/lon/height) error report — shows the vertical (Up) dominance that
% ISL breaks.
try
    ge = revgnss.GeodeticErrorReport.fromSim(sim);
    revgnss.GeodeticErrorReport.printSummary(ge);
catch e; fprintf('Geodetic report unavailable: %s\n', e.message); end
fprintf('PDF: %s\n', out.pdfPath);
fprintf('MAT: %s\n', out.matPath);
fprintf('=====================================\n');
end
