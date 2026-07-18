classdef RngSource
    % RngSource  Integer source-type codes for identity-keyed RNG streams.
    %
    % Each physically-independent noise source is assigned a distinct integer
    % so that models.noise.RngRegistry can derive a collision-free substream
    % index from (sourceType, node, antenna, signal[, epoch]).  Integer codes
    % (rather than hashing source-name strings) remove any string-hash
    % collision risk from the substream index.
    %
    % Codes must stay in [1, 31] (5-bit field in RngRegistry.substreamIndex_).

    properties (Constant)
        CODE           = 1    % elevation-dependent code noise (white)
        TROP_RESID     = 2    % troposphere seeded residual (white)
        IONO_RESID     = 3    % ionosphere seeded residual (white)
        HWDELAY_RESID  = 4    % hardware-delay residual (white)
        MP_WHITE       = 5    % legacy white/sinusoidal multipath
        MP_GM          = 6    % coloured (Gauss-Markov) multipath (persistent)
        ENV_TROP_TRUTH = 7    % EnvironmentModel troposphere GM, truth (persistent)
        ENV_TROP_MODEL = 8    % EnvironmentModel troposphere GM, model (persistent)
        ENV_IONO_TRUTH = 9    % EnvironmentModel ionosphere TEC GM, truth (persistent)
        ENV_SCINT      = 10   % EnvironmentModel scintillation amplitude GM (persistent)
        SCINT_TRUTH    = 11   % scintillation truth draw in CodeMeasurementBuilder (white)
        CODE_MULTISIG  = 12   % per-signal code noise (si>1) in CodeMeasurementBuilder (white)
        CARR_AMB       = 13   % carrier float-ambiguity init (persistent, one-shot)
        CARR_PHASE     = 14   % carrier phase noise (white)
        DOPPLER        = 15   % Doppler measurement noise (white)
        ATT_REF        = 16   % external attitude-reference perturbation (one-shot)
        PHASE_SCINT    = 17   % EnvironmentModel phase-scintillation GM, per tower (persistent)
        TWSTFT_TWOWAY  = 18   % tower<->spacecraft two-way time-transfer noise (white)
        ANT_PHASE_BIAS = 19   % unknown per-antenna carrier phase bias, truth-only (persistent)
        TOWER_SECONDARY = 20  % WP5 ground-tower -> secondary-asset code thermal noise (white)
    end
end
