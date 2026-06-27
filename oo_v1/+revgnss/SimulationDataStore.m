classdef SimulationDataStore < handle
    % SimulationDataStore  Preallocated array backend for simulation diagnostics.
    %
    % Replaces per-epoch struct-array growth (O(N^2) for heterogeneous data)
    % with fixed-length preallocated numeric arrays (O(N) total, O(1) per write).
    %
    % Usage:
    %   store = revgnss.SimulationDataStore(cfg, nEpochs);
    %   store.storeEntry(k, entry);          % k = 1-based epoch index
    %   store.storeSnapshot(t_s, k, P, H, R, z, h);
    %   store.recordOrbitCache(orbitCacheStruct);
    %   d = store.getData();                 % returns struct of arrays
    %   s = store.toCompactStruct();         % compact MAT v2 schema

    properties (GetAccess = public, SetAccess = private)
        nEpochs   (1,1) double = 0    % epochs actually written
    end

    properties (Access = private)
        nAlloc_   (1,1) double = 0
        nx_       (1,1) double = 0    % state dim (lazy, set on first write)
        initialized_  (1,1) logical = false
        cfg_

        % ---- Time
        t_s_

        % ---- Truth state
        tr_r_     % [3 x N] position ECEF m
        tr_v_     % [3 x N] velocity ECEF mps
        tr_eu_    % [3 x N] Euler rad
        tr_om_    % [3 x N] omega rad/s
        tr_cbm_   % [N x 1] rx clock bias m
        tr_cbs_   % [N x 1] rx clock bias s
        tr_cdm_   % [N x 1] rx clock drift mps
        tr_ff_    % [N x 1] fractional freq

        % ---- Estimate state (fixed-size part)
        es_r_     % [3 x N]
        es_v_     % [3 x N]
        es_eu_    % [3 x N]
        es_om_    % [3 x N]
        es_cbm_   % [N x 1]
        es_cdm_   % [N x 1]
        % state-dim dependent (lazy):
        es_x_     % [nx x N]
        es_Pd_    % [nx x N]
        es_sig_   % [nx x N]

        % ---- Errors
        er_pv_    % [3 x N] position error m
        er_pn_    % [N x 1] position norm m
        er_vv_    % [3 x N] velocity error mps
        er_vn_    % [N x 1] velocity norm mps
        er_ar_    % [3 x N] attitude error rad
        er_ad_    % [3 x N] attitude error deg
        er_an_    % [N x 1] attitude norm deg
        er_ov_    % [3 x N] angular rate error rad/s
        er_on_    % [N x 1] angular rate norm rad/s
        er_cb_    % [N x 1] clock bias error m
        er_cd_    % [N x 1] clock drift error mps
        er_ff_    % [N x 1] fractional freq error

        % ---- Measurement counts
        mc_nr_    % [N x 1] total rows
        mc_nc_    % [N x 1] code rows
        mc_ncar_  % [N x 1] carrier rows
        mc_nd_    % [N x 1] doppler rows
        mc_nv_    % [N x 1] visible towers

        % ---- Residuals
        rs_pfa_   % [N x 1] prefit all RMS
        rs_poa_   % [N x 1] postfit all RMS
        rs_pfc_   % [N x 1] prefit code RMS m
        rs_poc_   % [N x 1] postfit code RMS m
        rs_pfcar_ % [N x 1] prefit carrier RMS m
        rs_pocar_ % [N x 1] postfit carrier RMS m
        rs_pfd_   % [N x 1] prefit doppler RMS mps
        rs_pod_   % [N x 1] postfit doppler RMS mps
        rs_pfmax_ % [N x 1] prefit max abs
        rs_pomax_ % [N x 1] postfit max abs

        % ---- Consistency (NIS/NEES)
        cn_NIS_    cn_NIScod_   cn_NIScar_   cn_NISdop_
        cn_NEESp_  cn_NEESv_    cn_NEESc_    cn_NEESa_

        % ---- Covariance / R summary
        cv_Rtrc_  cv_Rmin_  cv_Rmax_  cv_Rmn_  cv_Rnr_

        % ---- Geometry / Jacobian
        gm_mRk_  gm_cS_  gm_gRk_  gm_gdop_  gm_pdop_  gm_tdop_
        gm_pclk_ gm_ajN_ gm_ajRk_ gm_ajCd_

        % ---- Sigma summary and attitude
        sg_pSig_  sg_aSig_  sg_aCd_
        sg_aSep_  sg_aAmb_   % logical, scalar

        % ---- Clock diagnostics
        ck_gauR_  ck_gbR_  ck_gdR_  ck_sRk_  ck_sCd_
        ck_oRkP_  ck_oRkG_  ck_oCdP_  ck_oCdG_

        % ---- Stage 57
        s57_pN_  s57_gN_  s57_aN_  s57_pD_  s57_gD_
        s57_pR_  s57_gR_  s57_aR_  s57_cR_  s57_carR_  s57_dR_

        % ---- Differential attitude
        da_act_   da_nR_   da_rR_
        da_aBl_   da_lBl_  da_rcBl_ da_rjR_

        % ---- Slip / ZWD / tx bias / light time
        sl_nSl_   sl_jmp_
        zw_nZwd_  zw_est_
        tx_gR_    tx_gRes_ tx_nSt_
        lt_mn_    lt_mx_

        % ---- Doppler info
        di_sagR_  di_mRot_  di_xRot_
        di_pCovA_ di_pCovB_ di_pCovS_ di_pCovP_

        % ---- Per-source error RMS
        ps_cT_  ps_tT_  ps_iT_  ps_hT_  ps_mT_
        ps_cM_  ps_tM_  ps_iM_  ps_hM_  ps_mM_

        % ---- Effect contributions (struct of [N x 1])
        eff_

        % ---- Tower clocks (lazy [nTowers x N])
        nTowers_  (1,1) double = 0
        tw_tru_
        tw_mod_
        tw_err_

        % ---- Euler at last epoch (for ReportRunner summary)
        lastTruthEuler_rad_   double = []
        lastEstEuler_rad_     double = []

        % ---- Orbit cache metadata
        orbitCacheEnabled_  (1,1) logical = false
        orbitCacheMode_     char          = ''
        orbitCacheEpochs_   (1,1) double  = 0
        orbitCacheSource_   char          = ''

        % ---- Full-matrix snapshots
        snapshots_
        snapshotCount_      (1,1) double  = 0
        lastSnapshotTime_s_ (1,1) double  = -Inf
        snapshotEnable_     (1,1) logical = false
        snapshotInterval_s_ (1,1) double  = 600
        snapshotMax_        (1,1) double  = 200
        snapshotFirstLast_  (1,1) logical = true
    end

    % =====================================================================
    methods (Access = public)

        function obj = SimulationDataStore(cfg, nEpochs)
            obj.cfg_    = cfg;
            obj.nAlloc_ = max(1, nEpochs);
            N           = obj.nAlloc_;
            obj.parseSnapshotCfg_(cfg);

            n3 = @() nan(3, N);
            n1 = @() nan(N, 1);
            b1 = @() false(N, 1);

            obj.t_s_   = n1();

            obj.tr_r_  = n3(); obj.tr_v_  = n3();
            obj.tr_eu_ = n3(); obj.tr_om_ = n3();
            obj.tr_cbm_= n1(); obj.tr_cbs_= n1();
            obj.tr_cdm_= n1(); obj.tr_ff_ = n1();

            obj.es_r_  = n3(); obj.es_v_  = n3();
            obj.es_eu_ = n3(); obj.es_om_ = n3();
            obj.es_cbm_= n1(); obj.es_cdm_= n1();

            obj.er_pv_ = n3(); obj.er_pn_ = n1();
            obj.er_vv_ = n3(); obj.er_vn_ = n1();
            obj.er_ar_ = n3(); obj.er_ad_ = n3();
            obj.er_an_ = n1(); obj.er_ov_ = n3();
            obj.er_on_ = n1(); obj.er_cb_ = n1();
            obj.er_cd_ = n1(); obj.er_ff_ = n1();

            obj.mc_nr_  = n1(); obj.mc_nc_  = n1();
            obj.mc_ncar_= n1(); obj.mc_nd_  = n1();
            obj.mc_nv_  = n1();

            obj.rs_pfa_  = n1(); obj.rs_poa_  = n1();
            obj.rs_pfc_  = n1(); obj.rs_poc_  = n1();
            obj.rs_pfcar_= n1(); obj.rs_pocar_= n1();
            obj.rs_pfd_  = n1(); obj.rs_pod_  = n1();
            obj.rs_pfmax_= n1(); obj.rs_pomax_= n1();

            obj.cn_NIS_   = n1(); obj.cn_NIScod_= n1();
            obj.cn_NIScar_= n1(); obj.cn_NISdop_= n1();
            obj.cn_NEESp_ = n1(); obj.cn_NEESv_ = n1();
            obj.cn_NEESc_ = n1(); obj.cn_NEESa_ = n1();

            obj.cv_Rtrc_= n1(); obj.cv_Rmin_= n1();
            obj.cv_Rmax_= n1(); obj.cv_Rmn_ = n1(); obj.cv_Rnr_ = n1();

            obj.gm_mRk_  = n1(); obj.gm_cS_  = n1();
            obj.gm_gRk_  = n1(); obj.gm_gdop_= n1();
            obj.gm_pdop_ = n1(); obj.gm_tdop_= n1();
            obj.gm_pclk_ = n1(); obj.gm_ajN_ = n1();
            obj.gm_ajRk_ = n1(); obj.gm_ajCd_= n1();

            obj.sg_pSig_= n1(); obj.sg_aSig_= n1();
            obj.sg_aCd_ = n1(); obj.sg_aSep_= b1();
            obj.sg_aAmb_= n1();

            obj.ck_gauR_= n1(); obj.ck_gbR_ = n1();
            obj.ck_gdR_ = n1(); obj.ck_sRk_ = n1();
            obj.ck_sCd_ = n1(); obj.ck_oRkP_= n1();
            obj.ck_oRkG_= n1(); obj.ck_oCdP_= n1();
            obj.ck_oCdG_= n1();

            obj.s57_pN_  = n1(); obj.s57_gN_  = n1();
            obj.s57_aN_  = n1(); obj.s57_pD_  = n1();
            obj.s57_gD_  = n1(); obj.s57_pR_  = n1();
            obj.s57_gR_  = n1(); obj.s57_aR_  = n1();
            obj.s57_cR_  = n1(); obj.s57_carR_= n1();
            obj.s57_dR_  = n1();

            obj.da_act_  = b1(); obj.da_nR_   = n1();
            obj.da_rR_   = n1(); obj.da_aBl_  = n1();
            obj.da_lBl_  = n1(); obj.da_rcBl_ = n1();
            obj.da_rjR_  = n1();

            obj.sl_nSl_  = n1(); obj.sl_jmp_  = n1();
            obj.zw_nZwd_ = n1(); obj.zw_est_  = b1();
            obj.tx_gR_   = n1(); obj.tx_gRes_ = n1(); obj.tx_nSt_ = n1();
            obj.lt_mn_   = n1(); obj.lt_mx_   = n1();

            obj.di_sagR_ = n1(); obj.di_mRot_ = n1(); obj.di_xRot_ = n1();
            obj.di_pCovA_= b1(); obj.di_pCovB_= n1();
            obj.di_pCovS_= n1(); obj.di_pCovP_= b1();

            obj.ps_cT_= n1(); obj.ps_tT_= n1(); obj.ps_iT_= n1();
            obj.ps_hT_= n1(); obj.ps_mT_= n1();
            obj.ps_cM_= n1(); obj.ps_tM_= n1(); obj.ps_iM_= n1();
            obj.ps_hM_= n1(); obj.ps_mM_= n1();

            obj.eff_      = makeEffStruct_(N);
            obj.snapshots_= struct('time_s',{},'epochIndex',{}, ...
                                   'P',{},'H',{},'R',{},'z',{},'h',{});
        end

        % -----------------------------------------------------------------
        function storeEntry(obj, k, entry)
            if k < 1 || k > obj.nAlloc_; return; end
            if ~obj.initialized_; obj.lazyInit_(entry); end
            obj.nEpochs = max(obj.nEpochs, k);

            obj.t_s_(k) = g_(entry,'time_s',NaN);

            % Truth
            obj.tr_r_(:,k)  = gv_(entry,{'truth','r_cm_ecef_m'},nan(3,1));
            if any(isnan(obj.tr_r_(:,k)))
                obj.tr_r_(:,k) = gv_(entry,{'truth','r_ecef_m'},nan(3,1));
            end
            obj.tr_v_(:,k)  = gv_(entry,{'truth','v_cm_ecef_mps'},nan(3,1));
            if any(isnan(obj.tr_v_(:,k)))
                obj.tr_v_(:,k) = gv_(entry,{'truth','v_ecef_mps'},nan(3,1));
            end
            obj.tr_eu_(:,k) = gv_(entry,{'truth','euler_rad'},nan(3,1));
            obj.tr_om_(:,k) = gv_(entry,{'truth','omega_body_radps'},nan(3,1));
            obj.tr_cbm_(k)  = gn_(entry,'truth','rxClockBias_m',NaN);
            obj.tr_cbs_(k)  = gn_(entry,'truth','rxClockBias_s',NaN);
            obj.tr_cdm_(k)  = gn_(entry,'truth','rxClockDrift_mps',NaN);
            obj.tr_ff_(k)   = gn_(entry,'truth','rxFracFreq',NaN);
            eu_tr = gv_(entry,{'truth','euler_rad'},[]);
            if ~isempty(eu_tr); obj.lastTruthEuler_rad_ = eu_tr(:); end

            % Estimate
            obj.es_r_(:,k)  = gv_(entry,{'estimate','r_cm_ecef_m'},nan(3,1));
            if any(isnan(obj.es_r_(:,k)))
                obj.es_r_(:,k) = gv_(entry,{'estimate','r_ecef_m'},nan(3,1));
            end
            obj.es_v_(:,k)  = gv_(entry,{'estimate','v_cm_ecef_mps'},nan(3,1));
            if any(isnan(obj.es_v_(:,k)))
                obj.es_v_(:,k) = gv_(entry,{'estimate','v_ecef_mps'},nan(3,1));
            end
            obj.es_eu_(:,k) = gv_(entry,{'estimate','euler_rad'},nan(3,1));
            obj.es_om_(:,k) = gv_(entry,{'estimate','omega_body_radps'},nan(3,1));
            obj.es_cbm_(k)  = gn_(entry,'estimate','rxClockBias_m',NaN);
            obj.es_cdm_(k)  = gn_(entry,'estimate','rxClockDrift_mps',NaN);
            eu_es = gv_(entry,{'estimate','euler_rad'},[]);
            if ~isempty(eu_es); obj.lastEstEuler_rad_ = eu_es(:); end

            % State-dim arrays (lazy init on first write)
            if obj.nx_ > 0
                xvec = gv_(entry,{'estimate','x'},[]);
                if ~isempty(xvec) && numel(xvec) == obj.nx_
                    obj.es_x_(:,k) = xvec(:);
                end
                Pd = g_(entry,'Pdiag',[]);
                if isempty(Pd); Pd = gn_(entry,'estimate','Pdiag',[]); end
                if ~isempty(Pd) && numel(Pd) == obj.nx_
                    obj.es_Pd_(:,k) = Pd(:);
                    sig = gn_(entry,'estimate','sigma',[]);
                    if isempty(sig) || numel(sig) ~= obj.nx_
                        sig = sqrt(max(0,Pd(:)));
                    end
                    obj.es_sig_(:,k) = sig(:);
                end
            end

            % Errors
            pv = g_(entry,'positionErrorVec_m',nan(3,1));
            if isempty(pv); pv = nan(3,1); end; obj.er_pv_(:,k) = pv(:);
            obj.er_pn_(k) = g_(entry,'positionError_m',NaN);
            vv = g_(entry,'velocityErrorVec_mps',nan(3,1));
            if isempty(vv); vv = nan(3,1); end; obj.er_vv_(:,k) = vv(:);
            obj.er_vn_(k) = g_(entry,'velocityError_mps',NaN);
            ar = g_(entry,'attitudeError_rad',nan(3,1));
            if isempty(ar); ar = nan(3,1); end; obj.er_ar_(:,k) = ar(:);
            ad = g_(entry,'attitudeError_deg',nan(3,1));
            if isempty(ad); ad = ar(:)*(180/pi); end; obj.er_ad_(:,k) = ad(:);
            obj.er_an_(k) = g_(entry,'attitudeNormError_deg',NaN);
            if isnan(obj.er_an_(k)); obj.er_an_(k) = norm(ad); end
            ov = g_(entry,'angularRateError_radps',nan(3,1));
            if isempty(ov); ov = nan(3,1); end; obj.er_ov_(:,k) = ov(:);
            obj.er_on_(k) = g_(entry,'angularRateNormError_radps',NaN);
            obj.er_cb_(k) = g_(entry,'clockBiasError_m',NaN);
            obj.er_cd_(k) = g_(entry,'clockDriftError_mps',NaN);
            obj.er_ff_(k) = g_(entry,'fracFreqError',NaN);

            % Measurement counts
            obj.mc_nr_(k)   = g_(entry,'numMeasurementRows',NaN);
            obj.mc_nc_(k)   = g_(entry,'numPseudorangeMeasurements',NaN);
            obj.mc_ncar_(k) = g_(entry,'numCarrierRows',NaN);
            obj.mc_nd_(k)   = g_(entry,'numDopplerRows',NaN);
            obj.mc_nv_(k)   = g_(entry,'numVisibleTowers',NaN);

            % Residuals
            obj.rs_pfa_(k)   = g_(entry,'prefitInnovationRMS',NaN);
            obj.rs_poa_(k)   = g_(entry,'postfitResidualRMS',NaN);
            obj.rs_pfc_(k)   = g_(entry,'prefitPseudorangeRMS_m',NaN);
            obj.rs_poc_(k)   = g_(entry,'postfitPseudorangeRMS_m',NaN);
            obj.rs_pfcar_(k) = g_(entry,'prefitCarrierRMS_m',NaN);
            obj.rs_pocar_(k) = g_(entry,'postfitCarrierRMS_m',NaN);
            obj.rs_pfd_(k)   = g_(entry,'prefitDopplerRMS_mps',NaN);
            obj.rs_pod_(k)   = g_(entry,'postfitDopplerRMS_mps',NaN);
            obj.rs_pfmax_(k) = g_(entry,'prefitMaxAbs',NaN);
            obj.rs_pomax_(k) = g_(entry,'postfitMaxAbs',NaN);

            % Consistency
            obj.cn_NIS_(k)    = g_(entry,'NIS',NaN);
            obj.cn_NIScod_(k) = g_(entry,'NIS_code',NaN);
            obj.cn_NIScar_(k) = g_(entry,'NIS_carrier',NaN);
            obj.cn_NISdop_(k) = g_(entry,'NIS_doppler',NaN);
            obj.cn_NEESp_(k)  = g_(entry,'NEES_pos',NaN);
            obj.cn_NEESv_(k)  = g_(entry,'NEES_vel',NaN);
            obj.cn_NEESc_(k)  = g_(entry,'NEES_clk',NaN);
            obj.cn_NEESa_(k)  = g_(entry,'NEES_att',NaN);

            % R summaries from Rdiag
            Rd = g_(entry,'Rdiag',[]);
            if ~isempty(Rd) && isnumeric(Rd)
                Rd = Rd(isfinite(Rd) & Rd > 0);
                if ~isempty(Rd)
                    obj.cv_Rtrc_(k) = sum(Rd);
                    obj.cv_Rmin_(k) = min(Rd);
                    obj.cv_Rmax_(k) = max(Rd);
                    obj.cv_Rmn_(k)  = mean(Rd);
                end
            end
            Rs = g_(entry,'Rsize',[]);
            if ~isempty(Rs); obj.cv_Rnr_(k) = Rs(1); end

            % Geometry
            obj.gm_mRk_(k)  = g_(entry,'measurementRank',NaN);
            obj.gm_cS_(k)   = g_(entry,'conditionNumberS',NaN);
            obj.gm_gRk_(k)  = g_(entry,'geometryRank',NaN);
            obj.gm_gdop_(k) = g_(entry,'gdopLike',NaN);
            obj.gm_pdop_(k) = g_(entry,'pdopLike',NaN);
            obj.gm_tdop_(k) = g_(entry,'tdopLike',NaN);
            obj.gm_pclk_(k) = g_(entry,'positionClockCondition',NaN);
            obj.gm_ajN_(k)  = g_(entry,'attitudeJacobianNorm',NaN);
            obj.gm_ajRk_(k) = g_(entry,'attitudeRank',NaN);
            obj.gm_ajCd_(k) = g_(entry,'attitudeCondNum',NaN);

            % Sigma / attitude
            obj.sg_pSig_(k) = g_(entry,'estimatedPositionSigma_m',NaN);
            obj.sg_aSig_(k) = g_(entry,'estimatedAttitudeSigma_rad',NaN);
            obj.sg_aCd_(k)  = g_(entry,'attitudeCondNum',NaN);
            obj.sg_aSep_(k) = logical(g_(entry,'attitudeSeparable',false));
            obj.sg_aAmb_(k) = g_(entry,'attitudeAmbCorrMaxAbs',NaN);

            % Clock
            obj.ck_gauR_(k) = g_(entry,'clockGaugeRowsAdded',NaN);
            obj.ck_gbR_(k)  = g_(entry,'clockGaugeBiasResidual_m',NaN);
            obj.ck_gdR_(k)  = g_(entry,'clockGaugeDriftResidual_mps',NaN);
            obj.ck_sRk_(k)  = g_(entry,'clockSubspaceRank',NaN);
            obj.ck_sCd_(k)  = g_(entry,'clockSubspaceCondNum',NaN);
            obj.ck_oRkP_(k) = g_(entry,'clockObsRankPhysical',NaN);
            obj.ck_oRkG_(k) = g_(entry,'clockObsRankGauged',NaN);
            obj.ck_oCdP_(k) = g_(entry,'clockObsCondPhysical',NaN);
            obj.ck_oCdG_(k) = g_(entry,'clockObsCondGauged',NaN);

            % Stage 57
            obj.s57_pN_(k)   = g_(entry,'physicalNIS57',NaN);
            obj.s57_gN_(k)   = g_(entry,'gaugeNIS57',NaN);
            obj.s57_aN_(k)   = g_(entry,'augmentedNIS57',NaN);
            obj.s57_pD_(k)   = g_(entry,'physicalDof57',NaN);
            obj.s57_gD_(k)   = g_(entry,'gaugeDof57',NaN);
            obj.s57_pR_(k)   = g_(entry,'physicalRms57',NaN);
            obj.s57_gR_(k)   = g_(entry,'gaugeRms57',NaN);
            obj.s57_aR_(k)   = g_(entry,'augRms57',NaN);
            obj.s57_cR_(k)   = g_(entry,'codeRms57',NaN);
            obj.s57_carR_(k) = g_(entry,'carrierRms57',NaN);
            obj.s57_dR_(k)   = g_(entry,'dopplerRms57',NaN);

            % Differential attitude
            obj.da_act_(k)  = logical(g_(entry,'diffAttActive',false));
            obj.da_nR_(k)   = g_(entry,'diffAttNRows',NaN);
            obj.da_rR_(k)   = g_(entry,'diffAttResidRMS',NaN);
            obj.da_aBl_(k)  = g_(entry,'diffAttActiveBaselines',NaN);
            obj.da_lBl_(k)  = g_(entry,'diffAttLostBaselines',NaN);
            obj.da_rcBl_(k) = g_(entry,'diffAttRecalibratedBaselines',NaN);
            obj.da_rjR_(k)  = g_(entry,'diffAttRejectedRows',NaN);

            % Slip / ZWD / tx / light time
            obj.sl_nSl_(k)  = g_(entry,'carrierSlipNSlips',NaN);
            obj.sl_jmp_(k)  = g_(entry,'carrierSlipTotalJump_m',NaN);
            obj.zw_nZwd_(k) = g_(entry,'nZwdStates',NaN);
            obj.zw_est_(k)  = logical(g_(entry,'zwdEstimated',false));
            obj.tx_gR_(k)   = g_(entry,'txCodeBiasGaugeRowsAdded',NaN);
            obj.tx_gRes_(k) = g_(entry,'txCodeBiasGaugeResidual_m',NaN);
            obj.tx_nSt_(k)  = g_(entry,'nTxCodeBiasStates',NaN);
            obj.lt_mn_(k)   = g_(entry,'meanLightTime_s',NaN);
            obj.lt_mx_(k)   = g_(entry,'maxLightTime_s',NaN);

            % Doppler info struct
            di = g_(entry,'dopplerInfo',struct());
            if isstruct(di)
                obj.di_sagR_(k)  = g_(di,'sagnacRateMax_mps',NaN);
                obj.di_mRot_(k)  = g_(di,'meanTowerRotSpeed_mps',NaN);
                obj.di_xRot_(k)  = g_(di,'maxTowerRotSpeed_mps',NaN);
                obj.di_pCovA_(k) = logical(g_(di,'dopplerProductCovApplied',false));
                obj.di_pCovB_(k) = g_(di,'dopplerProductCovBlocks',NaN);
                obj.di_pCovS_(k) = g_(di,'dopplerProductCovMaxSigma_mps',NaN);
                obj.di_pCovP_(k) = logical(g_(di,'dopplerProductCovSPD',false));
            end

            % Per-source RMS
            psT = g_(entry,'perSourceTruthRMS',struct());
            obj.ps_cT_(k) = g_(psT,'code',NaN);
            obj.ps_tT_(k) = g_(psT,'trop',NaN);
            obj.ps_iT_(k) = g_(psT,'iono',NaN);
            obj.ps_hT_(k) = g_(psT,'hwDelay',NaN);
            obj.ps_mT_(k) = g_(psT,'mp',NaN);
            psM = g_(entry,'perSourceModelRMS',struct());
            obj.ps_cM_(k) = g_(psM,'code',NaN);
            obj.ps_tM_(k) = g_(psM,'trop',NaN);
            obj.ps_iM_(k) = g_(psM,'iono',NaN);
            obj.ps_hM_(k) = g_(psM,'hwDelay',NaN);
            obj.ps_mM_(k) = g_(psM,'mp',NaN);

            % Contributions
            cnt = g_(entry,'contributions',struct());
            if isstruct(cnt)
                storeContrib_(obj.eff_, k, cnt);
            end

            % Tower clocks (lazy init)
            twT = g_(entry,'towerClockTruth_m',[]);
            twM = g_(entry,'towerClockModel_m',[]);
            if ~isempty(twT) && isnumeric(twT)
                nT = numel(twT);
                if isempty(obj.tw_tru_)
                    obj.nTowers_ = nT;
                    obj.tw_tru_  = nan(nT, obj.nAlloc_);
                    obj.tw_mod_  = nan(nT, obj.nAlloc_);
                    obj.tw_err_  = nan(nT, obj.nAlloc_);
                end
                nMn = min(nT, obj.nTowers_);
                obj.tw_tru_(1:nMn,k) = twT(1:nMn);
                if ~isempty(twM) && isnumeric(twM) && numel(twM) >= nMn
                    obj.tw_mod_(1:nMn,k) = twM(1:nMn);
                    obj.tw_err_(1:nMn,k) = twT(1:nMn) - twM(1:nMn);
                end
            end
        end

        % -----------------------------------------------------------------
        function storeSnapshot(obj, t_s, k, P, H, R, z, h)
            if ~obj.snapshotEnable_; return; end
            if obj.snapshotCount_ >= obj.snapshotMax_; return; end
            isFirst = (obj.snapshotCount_ == 0);
            elapsed = t_s - obj.lastSnapshotTime_s_;
            if ~isFirst && elapsed < obj.snapshotInterval_s_; return; end
            obj.snapshotCount_ = obj.snapshotCount_ + 1;
            obj.snapshots_(end+1) = struct('time_s',t_s,'epochIndex',k, ...
                'P',P,'H',H,'R',R,'z',z,'h',h);
            obj.lastSnapshotTime_s_ = t_s;
        end

        % -----------------------------------------------------------------
        function recordOrbitCache(obj, oc)
            if ~isstruct(oc); return; end
            obj.orbitCacheEnabled_ = logical(g_(oc,'enabled',false));
            obj.orbitCacheMode_    = char(g_(oc,'mode',''));
            obj.orbitCacheEpochs_  = double(g_(oc,'cacheEpochs',0));
            if obj.orbitCacheEpochs_ == 0 && isfield(oc,'t_s')
                obj.orbitCacheEpochs_ = numel(oc.t_s);
            end
            obj.orbitCacheSource_  = char(g_(oc,'source',''));
        end

        % -----------------------------------------------------------------
        function finalize(obj); end  % placeholder; arrays already fixed-size

        % -----------------------------------------------------------------
        function d = getData(obj)
            N  = obj.nEpochs;
            d  = struct();

            d.t_s = obj.t_s_(1:N);

            % Truth
            d.truth.r_cm_ecef_m       = obj.tr_r_(:,1:N);
            d.truth.v_cm_ecef_mps     = obj.tr_v_(:,1:N);
            d.truth.euler_rad         = obj.tr_eu_(:,1:N);
            d.truth.omega_body_radps  = obj.tr_om_(:,1:N);
            d.truth.rxClockBias_m     = obj.tr_cbm_(1:N);
            d.truth.rxClockBias_s     = obj.tr_cbs_(1:N);
            d.truth.rxClockDrift_mps  = obj.tr_cdm_(1:N);
            d.truth.rxFracFreq        = obj.tr_ff_(1:N);
            d.truth.r_ecef_m          = d.truth.r_cm_ecef_m;   % compat alias
            d.truth.v_ecef_mps        = d.truth.v_cm_ecef_mps; % compat alias
            d.truth.rxClock_m         = d.truth.rxClockBias_m;
            d.truth.rxClockDrift_mps  = d.truth.rxClockDrift_mps;
            % For ReportRunner euler summary
            d.truth.lastEuler_rad     = obj.lastTruthEuler_rad_;

            % Estimate
            d.estimate.r_cm_ecef_m    = obj.es_r_(:,1:N);
            d.estimate.v_cm_ecef_mps  = obj.es_v_(:,1:N);
            d.estimate.euler_rad      = obj.es_eu_(:,1:N);
            d.estimate.omega_body_radps= obj.es_om_(:,1:N);
            d.estimate.rxClockBias_m  = obj.es_cbm_(1:N);
            d.estimate.rxClockDrift_mps= obj.es_cdm_(1:N);
            d.estimate.r_ecef_m       = d.estimate.r_cm_ecef_m;  % compat alias
            d.estimate.v_ecef_mps     = d.estimate.v_cm_ecef_mps;
            d.estimate.rxClock_m      = d.estimate.rxClockBias_m;
            d.estimate.lastEuler_rad  = obj.lastEstEuler_rad_;
            if obj.nx_ > 0
                d.estimate.x    = obj.es_x_(:,1:N);
                d.estimate.Pdiag= obj.es_Pd_(:,1:N);
                d.estimate.sigma= obj.es_sig_(:,1:N);
                d.Pdiag         = d.estimate.Pdiag;    % top-level alias
            else
                d.estimate.x=[]; d.estimate.Pdiag=[]; d.estimate.sigma=[]; d.Pdiag=[];
            end
            d.x = d.estimate.r_cm_ecef_m;  % position alias for analysis script

            % Errors
            d.error.positionVec_m     = obj.er_pv_(:,1:N);
            d.error.positionNorm_m    = obj.er_pn_(1:N);
            d.error.velocityVec_mps   = obj.er_vv_(:,1:N);
            d.error.velocityNorm_mps  = obj.er_vn_(1:N);
            d.error.attitude_rad      = obj.er_ar_(:,1:N);
            d.error.attitude_deg      = obj.er_ad_(:,1:N);
            d.error.attitudeNorm_deg  = obj.er_an_(1:N);
            d.error.angularRate_radps = obj.er_ov_(:,1:N);
            d.error.angularRateNorm_radps= obj.er_on_(1:N);
            d.error.clockBias_m       = obj.er_cb_(1:N);
            d.error.clockDrift_mps    = obj.er_cd_(1:N);
            d.error.fracFreq          = obj.er_ff_(1:N);

            % Measurement counts (dual naming for compat)
            d.meas.nRows           = obj.mc_nr_(1:N);
            d.meas.nCodeRows       = obj.mc_nc_(1:N);
            d.meas.nCarrierRows    = obj.mc_ncar_(1:N);
            d.meas.nDopplerRows    = obj.mc_nd_(1:N);
            d.meas.nVisibleTowers  = obj.mc_nv_(1:N);
            d.meas.numRows         = d.meas.nRows;         % analysis alias
            d.meas.numCodeRows     = d.meas.nCodeRows;
            d.meas.numCarrierRows  = d.meas.nCarrierRows;
            d.meas.numDopplerRows  = d.meas.nDopplerRows;

            % Residuals (dual naming for compat)
            d.residual.prefitAllRMS        = obj.rs_pfa_(1:N);
            d.residual.postfitAllRMS       = obj.rs_poa_(1:N);
            d.residual.prefitCodeRMS_m     = obj.rs_pfc_(1:N);
            d.residual.postfitCodeRMS_m    = obj.rs_poc_(1:N);
            d.residual.prefitCarrierRMS_m  = obj.rs_pfcar_(1:N);
            d.residual.postfitCarrierRMS_m = obj.rs_pocar_(1:N);
            d.residual.prefitDopplerRMS_mps= obj.rs_pfd_(1:N);
            d.residual.postfitDopplerRMS_mps=obj.rs_pod_(1:N);
            d.residual.prefitMaxAbs        = obj.rs_pfmax_(1:N);
            d.residual.postfitMaxAbs       = obj.rs_pomax_(1:N);
            d.residual.codeRms_m           = obj.rs_pfc_(1:N);    % analysis alias
            d.residual.carrierRms_m        = obj.rs_pfcar_(1:N);
            d.residual.dopplerRms_m        = obj.rs_pfd_(1:N);

            % Consistency
            d.consistency.NIS         = obj.cn_NIS_(1:N);
            d.consistency.NIS_code    = obj.cn_NIScod_(1:N);
            d.consistency.NIS_carrier = obj.cn_NIScar_(1:N);
            d.consistency.NIS_doppler = obj.cn_NISdop_(1:N);
            d.consistency.NEES_pos    = obj.cn_NEESp_(1:N);
            d.consistency.NEES_vel    = obj.cn_NEESv_(1:N);
            d.consistency.NEES_clk   = obj.cn_NEESc_(1:N);
            d.consistency.NEES_att   = obj.cn_NEESa_(1:N);

            % Covariance
            d.cov.Rtrace    = obj.cv_Rtrc_(1:N);
            d.cov.RminDiag  = obj.cv_Rmin_(1:N);
            d.cov.RmaxDiag  = obj.cv_Rmax_(1:N);
            d.cov.RdiagMean = obj.cv_Rmn_(1:N);
            d.cov.Rrows     = obj.cv_Rnr_(1:N);

            % Geometry
            d.geom.measurementRank       = obj.gm_mRk_(1:N);
            d.geom.conditionNumberS      = obj.gm_cS_(1:N);
            d.geom.geometryRank          = obj.gm_gRk_(1:N);
            d.geom.gdopLike              = obj.gm_gdop_(1:N);
            d.geom.pdopLike              = obj.gm_pdop_(1:N);
            d.geom.tdopLike              = obj.gm_tdop_(1:N);
            d.geom.positionClockCondition= obj.gm_pclk_(1:N);
            d.geom.attitudeJacobianNorm  = obj.gm_ajN_(1:N);
            d.geom.attitudeRank          = obj.gm_ajRk_(1:N);
            d.geom.attitudeCondNum       = obj.gm_ajCd_(1:N);

            % Attitude summary
            d.attitude.positionSigma_m   = obj.sg_pSig_(1:N);
            d.attitude.attitudeSigma_rad = obj.sg_aSig_(1:N);
            d.attitude.condNum           = obj.sg_aCd_(1:N);
            d.attitude.separable         = obj.sg_aSep_(1:N);
            d.attitude.ambCorrMaxAbs     = obj.sg_aAmb_(1:N);

            % Clock
            d.clock.gaugeRows        = obj.ck_gauR_(1:N);
            d.clock.gaugeBiasRes_m   = obj.ck_gbR_(1:N);
            d.clock.gaugeDriftRes_mps= obj.ck_gdR_(1:N);
            d.clock.subspaceRank     = obj.ck_sRk_(1:N);
            d.clock.subspaceCond     = obj.ck_sCd_(1:N);
            d.clock.obsRankPhysical  = obj.ck_oRkP_(1:N);
            d.clock.obsRankGauged    = obj.ck_oRkG_(1:N);
            d.clock.obsCondPhysical  = obj.ck_oCdP_(1:N);
            d.clock.obsCondGauged    = obj.ck_oCdG_(1:N);

            % Stage 57
            d.stage57.physicalNIS    = obj.s57_pN_(1:N);
            d.stage57.gaugeNIS       = obj.s57_gN_(1:N);
            d.stage57.augmentedNIS   = obj.s57_aN_(1:N);
            d.stage57.physicalDof    = obj.s57_pD_(1:N);
            d.stage57.gaugeDof       = obj.s57_gD_(1:N);
            d.stage57.physicalRms    = obj.s57_pR_(1:N);
            d.stage57.gaugeRms       = obj.s57_gR_(1:N);
            d.stage57.augmentedRms   = obj.s57_aR_(1:N);
            d.stage57.codeRms        = obj.s57_cR_(1:N);
            d.stage57.carrierRms     = obj.s57_carR_(1:N);
            d.stage57.dopplerRms     = obj.s57_dR_(1:N);

            % Differential attitude
            d.diffAtt.active          = obj.da_act_(1:N);
            d.diffAtt.nRows           = obj.da_nR_(1:N);
            d.diffAtt.residRMS        = obj.da_rR_(1:N);
            d.diffAtt.activeBaselines = obj.da_aBl_(1:N);
            d.diffAtt.lostBaselines   = obj.da_lBl_(1:N);
            d.diffAtt.recalBaselines  = obj.da_rcBl_(1:N);
            d.diffAtt.rejectedRows    = obj.da_rjR_(1:N);

            % Slip / ZWD / tx / light time
            d.slip.nSlips    = obj.sl_nSl_(1:N);
            d.slip.jumpMag_m = obj.sl_jmp_(1:N);
            d.carrierSlip.count = obj.sl_nSl_(1:N);  % analysis alias

            d.zwd.nStates  = obj.zw_nZwd_(1:N);
            d.zwd.estimated= obj.zw_est_(1:N);
            d.txBias.gaugeRows  = obj.tx_gR_(1:N);
            d.txBias.gaugeRes_m = obj.tx_gRes_(1:N);
            d.txBias.nStates    = obj.tx_nSt_(1:N);
            d.lightTime.mean_s  = obj.lt_mn_(1:N);
            d.lightTime.max_s   = obj.lt_mx_(1:N);

            % Doppler info (struct of arrays, matching legacy [struct array] field names)
            d.dopplerInfo.sagnacRateMax_mps        = obj.di_sagR_(1:N);
            d.dopplerInfo.meanTowerRotSpeed_mps     = obj.di_mRot_(1:N);
            d.dopplerInfo.maxTowerRotSpeed_mps      = obj.di_xRot_(1:N);
            d.dopplerInfo.dopplerProductCovApplied  = obj.di_pCovA_(1:N);
            d.dopplerInfo.dopplerProductCovBlocks   = obj.di_pCovB_(1:N);
            d.dopplerInfo.dopplerProductCovMaxSigma_mps= obj.di_pCovS_(1:N);
            d.dopplerInfo.dopplerProductCovSPD      = obj.di_pCovP_(1:N);

            % Per-source error RMS
            d.perSource.code    = obj.ps_cT_(1:N);
            d.perSource.trop    = obj.ps_tT_(1:N);
            d.perSource.iono    = obj.ps_iT_(1:N);
            d.perSource.hwDelay = obj.ps_hT_(1:N);
            d.perSource.mp      = obj.ps_mT_(1:N);
            d.perSource.codeModel    = obj.ps_cM_(1:N);
            d.perSource.tropModel    = obj.ps_tM_(1:N);
            d.perSource.ionoModel    = obj.ps_iM_(1:N);
            d.perSource.hwDelayModel = obj.ps_hM_(1:N);
            d.perSource.mpModel      = obj.ps_mM_(1:N);

            % Contributions (struct of struct of [N x 1])
            d.contributions = trimEff_(obj.eff_, N);

            % Tower clocks
            if ~isempty(obj.tw_tru_)
                d.towerClock.truth_m           = obj.tw_tru_(:,1:N);
                d.towerClock.model_m           = obj.tw_mod_(:,1:N);
                d.towerClock.correctionError_m = obj.tw_err_(:,1:N);
            end

            % Orbit cache metadata
            d.orbit.cacheEnabled = obj.orbitCacheEnabled_;
            d.orbit.cacheMode    = obj.orbitCacheMode_;
            d.orbit.cacheEpochs  = obj.orbitCacheEpochs_;
            d.orbit.cacheSource  = obj.orbitCacheSource_;

            % Ambiguity placeholders (for analysis compat)
            d.ambiguity.resetCount = nan(N,1);
            d.ambiguity.accepted   = nan(N,1);
            d.ambiguity.rejected   = nan(N,1);

            % Snapshots
            d.snapshots     = obj.snapshots_;
            d.snapshotCount = obj.snapshotCount_;
        end

        % -----------------------------------------------------------------
        function s = toCompactStruct(obj)
            s.version = 2;
            s.schema  = 'SimulationDataStoreCompact';
            s.data    = obj.getData();
        end

        % -----------------------------------------------------------------
        function n = getSnapshotCount(obj)
            n = obj.snapshotCount_;
        end

    end % public methods

    % =====================================================================
    methods (Access = private)

        function lazyInit_(obj, entry)
            obj.initialized_ = true;
            xvec = gv_(entry,{'estimate','x'},[]);
            if isempty(xvec); xvec = g_(entry,'stateVector',[]); end
            if ~isempty(xvec) && numel(xvec) > 0
                nx = numel(xvec);
                obj.nx_     = nx;
                obj.es_x_   = nan(nx, obj.nAlloc_);
                obj.es_Pd_  = nan(nx, obj.nAlloc_);
                obj.es_sig_ = nan(nx, obj.nAlloc_);
            end
        end

        function parseSnapshotCfg_(obj, cfg)
            obj.snapshotEnable_ = false;
            try
                st = cfg.diagnostics.storage;
                % Accept both 'fullSnapshot' (new) and 'snapshot' (legacy key)
                sn = [];
                if isfield(st,'fullSnapshot'); sn = st.fullSnapshot;
                elseif isfield(st,'snapshot');  sn = st.snapshot; end
                if isempty(sn); return; end
                if isfield(sn,'enable');        obj.snapshotEnable_    = logical(sn.enable);    end
                if isfield(sn,'interval_s');    obj.snapshotInterval_s_= sn.interval_s;        end
                if isfield(sn,'maxSnapshots');  obj.snapshotMax_       = sn.maxSnapshots;      end
                if isfield(sn,'storeFirstLast');obj.snapshotFirstLast_ = logical(sn.storeFirstLast); end
            catch; end
        end

    end % private methods

end % classdef

% =========================================================================
% Module-level helpers — no method dispatch overhead per call
% =========================================================================
function v = g_(s, fld, def)
    if isstruct(s) && isfield(s,fld); v = s.(fld); else; v = def; end
end

function v = gn_(s, f1, f2, def)
    if isstruct(s) && isfield(s,f1)
        s2 = s.(f1);
        if isstruct(s2) && isfield(s2,f2); v = s2.(f2); return; end
    end
    v = def;
end

function v = gv_(s, path, def)
    v = s;
    for pi = 1:numel(path)
        if isstruct(v) && isfield(v,path{pi}); v = v.(path{pi});
        else; v = def; return; end
    end
    if isempty(v); v = def; end
end

function ef = makeEffStruct_(N)
    n1  = @() nan(N,1);
    z3m = struct('truthRMS_m',n1(),'modelRMS_m',n1(),'mismatchRMS_m',n1());
    z3d = struct('truthRMS_mps',n1(),'modelRMS_mps',n1(),'mismatchRMS_mps',n1());
    z3c = struct('truthRMS_cycles',n1(),'modelRMS_cycles',n1(),'mismatchRMS_cycles',n1());
    ef.codeNoise             = z3m; ef.troposphere           = z3m;
    ef.ionosphere            = z3m; ef.hardwareDelay         = z3m;
    ef.multipath             = z3m; ef.scintillationCodeNoise= z3m;
    ef.sagnac                = z3m; ef.shapiro               = z3m;
    ef.towerSurvey           = z3m; ef.receiverPCO           = z3m;
    ef.towerPCO              = z3m; ef.pcv                   = z3m;
    ef.towerClock            = z3m; ef.correlatedCommonMode  = z3m;
    ef.correlatedSameTower   = z3m; ef.correlatedIndependent = z3m;
    ef.total                 = z3m;
    ef.dopplerRangeRate      = z3d; ef.dopplerTowerClockDrift= z3d;
    ef.dopplerNoise          = z3d;
    ef.carrierPhaseCycles    = z3c; ef.carrierPhaseMeters    = z3m;
end

function storeContrib_(eff, k, cnt)
    fns = fieldnames(cnt);
    for fi = 1:numel(fns)
        fn = fns{fi};
        if strcmp(fn,'bySignal') || ~isfield(eff,fn); continue; end
        src = cnt.(fn);
        if ~isstruct(src); continue; end
        sfns = fieldnames(src);
        for si = 1:numel(sfns)
            sf = sfns{si};
            if ~isfield(eff.(fn),sf); continue; end
            val = src.(sf);
            if isnumeric(val) && isscalar(val)
                eff.(fn).(sf)(k) = val;
            end
        end
    end
end

function d = trimEff_(eff, N)
    d  = struct();
    fn = fieldnames(eff);
    for fi = 1:numel(fn)
        sf = fieldnames(eff.(fn{fi}));
        for si = 1:numel(sf)
            d.(fn{fi}).(sf{si}) = eff.(fn{fi}).(sf{si})(1:N);
        end
    end
end
