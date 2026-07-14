function cfg = realisticAtmosphereConfig(cfg)
%REALISTICATMOSPHERECONFIG  Overlay the physically-realistic atmosphere on a base cfg.
%   cfg = realisticAtmosphereConfig(masterConfig())
%
%   Switches the troposphere and ionosphere from the matched synthetic 'simpleMapped'
%   models (whose truth-model residual cancels to zero) onto the physically-grounded
%   stochastic-truth / imperfect-model pair introduced in the atmosphere-realism work:
%
%     Troposphere  -> localWeatherGM: Saastamoinen/Davis ZHD + a first-order Gauss-Markov
%                     wet-delay TRUTH mapped by Niell (NMF); the MODEL corrects ZHD exactly
%                     and estimates the wet delay with the per-tower ZWD EKF state, so the
%                     residual is m_w(e)*(ZWD_truth - ZWD_est), ~cm at zenith growing ~1/sin(e).
%     Ionosphere   -> tecGaussMarkov: a diurnal VTEC + stochastic-TEC TRUTH (thin-shell
%                     obliquity, uplink topside fraction) corrected by the single-frequency
%                     Klobuchar broadcast MODEL (~50% RMS removal). Higher-order term on.
%
%   The divergence is STRUCTURAL (independent RNG streams, estimator lag, functional-form
%   mismatch) with a single master enable per source -- no oracle read of the truth draw,
%   no arbitrary noise inflation. This is a SEPARATE builder: masterConfig's default
%   (matched simpleMapped) and the Stage-85 golden are untouched.
%
%   References: Saastamoinen 1972 / Davis 1985; Niell 1996; Klobuchar 1987; Bassiri & Hajj
%   1993; Kaplan & Hegarty; Misra & Enge.

    % ---------------- Troposphere ----------------
    cfg.errors.troposphere.enable        = true;
    cfg.errors.troposphere.truth.enable  = true;   % set explicitly (expandEnableToggles already ran)
    cfg.errors.troposphere.model.enable  = true;
    cfg.errors.troposphere.modelType     = 'localWeatherGM';
    cfg.errors.troposphere.dayOfYear     = 180;                 % mid-year (drives Niell season)
    cfg.errors.troposphere.truth.mappingType = 'niell';         % NMF hydrostatic/wet truth
    cfg.errors.troposphere.model.mappingType = 'niell';         % matched mapping; residual is the wet delay
    cfg.errors.troposphere.stochastic.enable         = true;
    cfg.errors.troposphere.stochastic.process        = 'gaussMarkov';
    cfg.errors.troposphere.stochastic.tau_s          = 10800;   % 3 h wet-delay correlation time
    cfg.errors.troposphere.stochastic.sigmaWet_ss_m  = 0.04;    % ~4 cm steady-state wet fluctuation
    cfg.errors.troposphere.stochastic.modelResidual.enable = false;  % model wet delay via the EKF, not a GM copy

    % The MODEL wet correction is the per-tower ZWD EKF state (PPP-grade): it observes only
    % the measurements and lags/biases the truth, so the surviving residual is physical.
    cfg.estimation.troposphereMode = 'perTowerZwd';

    % ---------------- Ionosphere ----------------
    cfg.errors.ionosphere.enable       = true;
    cfg.errors.ionosphere.truth.enable = true;
    cfg.errors.ionosphere.model.enable = true;
    cfg.errors.ionosphere.modelType    = 'tecGaussMarkov';
    % Diurnal VTEC truth (night floor + 14:00 daytime bump)
    cfg.errors.ionosphere.truth.diurnal.enable          = true;
    cfg.errors.ionosphere.truth.diurnal.vtecDay_TECU     = 30;   % mid-latitude, solar-moderate
    cfg.errors.ionosphere.truth.diurnal.vtecNight_TECU   = 6;
    cfg.errors.ionosphere.truth.diurnal.peakLocalTime_h  = 14;
    % Uplink column fraction (1.0 = GEO / full column; set <1 or use .topside for a LEO)
    cfg.errors.ionosphere.topsideFraction = 1.0;
    % Stochastic TEC fluctuation (a few TECU over minutes)
    cfg.errors.ionosphere.stochastic.enable             = true;
    cfg.errors.ionosphere.stochastic.process            = 'gaussMarkov';
    cfg.errors.ionosphere.stochastic.tau_s              = 600;
    cfg.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m = 0.3;   % ~2 TECU at L1
    % Single-frequency broadcast correction (imperfect climatology, ~50% RMS removal).
    % The Klobuchar amplitude/DC are DERIVED from the same diurnal VTEC the truth uses
    % (that is precisely what the broadcast alpha/beta coefficients approximate), scaled
    % by a <1 accuracy factor for the climatology's imperfection. This replaces the old
    % hand-set 16 ns/5 ns, which over-corrected: its 5 ns night floor (1.5 m) sat ~1.5x
    % above the 6 TECU truth floor (3.25 ns / 0.97 m), so the "correction" made the
    % single-frequency residual LARGER than the raw ionosphere. Deriving from VTEC keeps
    % the model honest but self-consistent; the residual is the (1-accuracy) climatology
    % error plus the stochastic TEC and half-cosine shape mismatch Klobuchar cannot forecast.
    cfg.errors.ionosphere.model.correction = 'klobuchar';
    K_L1_m_per_TECU = 40.308e16 / (1575.42e6)^2;             % ~0.1624 m per TECU at L1
    nsPerTECU       = K_L1_m_per_TECU / 2.99792458e8 * 1e9;   % ~0.5417 ns per TECU at L1
    klobAccuracy    = 0.75;                                   % broadcast climatology skill (~50-65% RMS removal)
    vDay_TECU       = cfg.errors.ionosphere.truth.diurnal.vtecDay_TECU;
    vNight_TECU     = cfg.errors.ionosphere.truth.diurnal.vtecNight_TECU;
    cfg.errors.ionosphere.model.klobuchar = struct( ...
        'amplitude_ns', (vDay_TECU - vNight_TECU) * nsPerTECU * klobAccuracy, ...
        'period_h',     24, ...
        'dc_ns',        vNight_TECU * nsPerTECU * klobAccuracy);
    % Second/third-order residual that survives the ionosphere-free combination
    cfg.errors.ionosphere.higherOrder.enable = true;

    % Thin-shell obliquity (not the flat-Earth secant) for the ionospheric mapping
    cfg.effects.ionosphere.mappingModel  = 'thinShell';
    cfg.effects.ionosphere.shellHeight_m = 350e3;

    % ---------------- Scintillation ----------------
    % Amplitude fading -> extra code/carrier measurement noise (into R) via the Conker
    % et al. (2003) 1/sqrt(1-2*S4^2) factor; phase scintillation -> a time-correlated
    % truth-side carrier-phase jitter the estimator cannot predict (into the innovation).
    cfg.errors.ionosphere.scintillation.enable  = true;
    cfg.errors.ionosphere.scintillation.model   = 'conker';   % amplitude fading -> R
    cfg.errors.ionosphere.scintillation.S4zen   = 0.3;         % moderate zenith S4
    cfg.errors.ionosphere.scintillation.tau_s   = 30;          % amplitude GM correlation time
    cfg.errors.ionosphere.scintillation.phaseScint.enable      = true;   % phase jitter -> truth carrier
    cfg.errors.ionosphere.scintillation.phaseScint.sigmaPhi_rad = 0.2;   % ~6 mm at L1 (disturbed)
    cfg.errors.ionosphere.scintillation.phaseScint.tau_s        = 1.5;   % s (time-correlated, not white)
end
