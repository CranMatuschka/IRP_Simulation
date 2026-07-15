classdef SimulationDataStore < handle
    % SimulationDataStore  Single canonical output database for all simulation data.
    %
    % FlatSimulationDataStore v3 schema — one preallocated array per variable,
    % one value per epoch. All EKF computation is performed inside recordEpoch().
    %
    % Usage:
    %   store = data.SimulationDataStore(cfg, nEpochs);            % backward compat
    %   store = data.SimulationDataStore(cfg, nEpochs, stateMap, nTowers, nRx);
    %   store.recordEpoch(k, t_s, asset, ekf, z, h, H, R, NIS, ...
    %       errStruct, visibleTowerIds, elevations_rad, postfitResidual);
    %   d = store.getData();        % FlatSimulationDataStore v3 struct
    %   m = store.getMeta();        % schema metadata
    %   s = store.toCompactStruct(); % compact MAT v3 schema

    properties (GetAccess = public, SetAccess = private)
        nEpochs   (1,1) double = 0    % epochs actually written
    end

    properties (Access = private)
        nAlloc_   (1,1) double = 0
        nx_       (1,1) double = 0    % state dim (lazy, set on first write)
        initialized_  (1,1) logical = false
        frozen_       (1,1) logical = false   % Immutability guard (set by freeze())
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
        cn_NIS_
        cn_NIScod_
        cn_NIScar_
        cn_NISdop_
        cn_NEESp_
        cn_NEESv_
        cn_NEESc_
        cn_NEESa_

        % ---- Covariance / R summary
        cv_Rtrc_
        cv_Rmin_
        cv_Rmax_
        cv_Rmn_
        cv_Rnr_

        % ---- Geometry / Jacobian
        gm_mRk_
        gm_cS_
        gm_gRk_
        gm_gdop_
        gm_pdop_
        gm_tdop_
        gm_pclk_
        gm_ajN_
        gm_ajRk_
        gm_ajCd_

        % ---- Sigma summary and attitude
        sg_pSig_
        sg_aSig_
        sg_aCd_
        sg_aSep_
        sg_aAmb_

        % ---- Clock diagnostics
        ck_gauR_
        ck_gbR_
        ck_gdR_
        ck_sRk_
        ck_sCd_
        ck_oRkP_
        ck_oRkG_
        ck_oCdP_
        ck_oCdG_

        % ---- EKF innovation accounting
        s57_pN_
        s57_gN_
        s57_aN_
        s57_pD_
        s57_gD_
        s57_pR_
        s57_gR_
        s57_aR_
        s57_cR_
        s57_carR_
        s57_dR_

        % ---- Differential attitude
        da_act_
        da_nR_
        da_rR_
        da_aBl_
        da_lBl_
        da_rcBl_
        da_rjR_

        % ---- Slip / ZWD / tx bias / light time
        sl_nSl_
        sl_jmp_
        zw_nZwd_
        zw_est_
        tx_gR_
        tx_gRes_
        tx_nSt_
        lt_mn_
        lt_mx_

        % ---- Doppler info
        di_sagR_
        di_mRot_
        di_xRot_
        di_pCovA_
        di_pCovB_
        di_pCovS_
        di_pCovP_

        % ---- Per-source error RMS
        ps_cT_
        ps_tT_
        ps_iT_
        ps_hT_
        ps_mT_
        ps_cM_
        ps_tM_
        ps_iM_
        ps_hM_
        ps_mM_

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

        % ---- Stateful fields for recordEpoch() (FlatSimulationDataStore v3)
        stateMap_                                % EKF stateMap (set at construction)
        nReceivers_         (1,1) double  = 1
        clockObsBuf_                             % sliding window: H_phys, Rd_phys, H_gauge, Rd_gauge
        clockObsEnable_     (1,1) logical = false
        clockObsWinLen_     (1,1) double  = 20
        clockObsMinWin_     (1,1) double  = 5
        clockObsRankTol_
        heavyDiagInterval_s_ (1,1) double = 60
        heavyDiagEveryEpoch_ (1,1) logical = true
        lastHeavyDiagTime_s_ (1,1) double = -Inf
        storagePolicyMode_   char          = 'compact'
        lastRecordedTime_s_  (1,1) double  = NaN
        lastAttitudeAudit_   struct         = struct()
        lastAttitudeJacobianAudit_ struct   = struct()
        % Clock obs weak-state counts (scalar per epoch)
        ck_oWkP_             % [N x 1] clock obs weak states count physical
        ck_oWkG_             % [N x 1] clock obs weak states count gauged
        cfg_saved_                               % full cfg for audit calls
    end

    % =====================================================================
    methods (Access = public)

        function obj = SimulationDataStore(cfg, nEpochs, stateMap, nTowers, nReceivers)
            obj.cfg_       = cfg;
            obj.cfg_saved_ = cfg;
            obj.nAlloc_    = max(1, nEpochs);
            N              = obj.nAlloc_;
            if nargin >= 3 && ~isempty(stateMap); obj.stateMap_ = stateMap; end
            if nargin >= 4 && ~isempty(nTowers);  obj.nTowers_  = nTowers;  end
            if nargin >= 5 && ~isempty(nReceivers);obj.nReceivers_ = nReceivers; end
            obj.parseSnapshotCfg_(cfg);
            obj.parseClockObsCfg_(cfg);
            obj.parseHeavyDiagCfg_(cfg);
            obj.parseStoragePolicyCfg_(cfg);
            obj.clockObsBuf_ = struct('H_phys',{{}},'Rd_phys',{{}},'H_gauge',{{}},'Rd_gauge',{{}});

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

            obj.ck_oWkP_  = n1();
            obj.ck_oWkG_  = n1();

            obj.eff_      = makeEffStruct_(N);
            obj.snapshots_= struct('time_s',{},'epochIndex',{}, ...
                                   'P',{},'H',{},'R',{},'z',{},'h',{});
        end

        % -----------------------------------------------------------------
        function storeEntry_(obj, k, entry)
            if obj.frozen_; error('SimulationDataStore:frozen', 'Store is frozen after the simulation stage; post/report may only read.'); end
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

            % EKF innovation accounting
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
            if obj.frozen_; error('SimulationDataStore:frozen', 'Store is frozen after the simulation stage; post/report may only read.'); end
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
        function freeze(obj)
            % freeze  Make the store immutable after the simulation stage.
            % Post-processing and report may then only READ; any write method throws
            % SimulationDataStore:frozen. Idempotent.
            obj.frozen_ = true;
        end

        % -----------------------------------------------------------------
        function recordEpoch(obj, k, t_s, asset, ekf, z, h, H, R, NIS, ...
                errStruct, visibleTowerIds, elevations_rad, postfitResidual)
            if obj.frozen_; error('SimulationDataStore:frozen', 'Store is frozen after the simulation stage; post/report may only read.'); end
            % recordEpoch  Canonical per-epoch recording — the only write path.
            %
            % Contains all computation previously in Diagnostics.record().
            % Calls private storeEntry_(k, entry) when done.
            if nargin < 14; postfitResidual = []; end
            sm = ekf.stateMap;
            x  = ekf.x;
            c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            storeFullThisEpoch = obj.shouldStoreFullSnapshot_(t_s, k);

            entry.time_s = t_s;  %#ok<STRNU>

            % --- Truth state ---
            entry.truth.r_cm_ecef_m      = asset.r_ecef_m;
            entry.truth.v_cm_ecef_mps    = asset.v_ecef_mps;
            entry.truth.euler_rad        = asset.attitude_euler_rad;
            entry.truth.omega_body_radps = asset.angularRate_body_radps;
            entry.truth.rxClockBias_m    = asset.clock.getBiasMeters();
            entry.truth.rxClockBias_s    = asset.clock.getBiasSeconds();
            entry.truth.rxFracFreq       = asset.clock.getFractionalFrequency();
            entry.truth.rxClockDrift_mps = asset.clock.getDriftMetersPerSecond();

            % --- Estimate state ---
            reportEuler_rad = ekf.getReportEulerRad();
            entry.estimate.x                = x;
            entry.estimate.P                = [];
            entry.estimate.r_cm_ecef_m      = x(sm.r_idx);
            entry.estimate.v_cm_ecef_mps    = x(sm.v_idx);
            entry.estimate.euler_rad        = reportEuler_rad;
            entry.estimate.omega_body_radps = x(sm.omega_idx);
            entry.estimate.rxClockBias_m    = x(sm.b_rx_idx);
            entry.estimate.rxClockDrift_mps = x(sm.bdot_rx_idx);

            % --- Velocity error ---
            v_err = x(sm.v_idx) - asset.v_ecef_mps;
            entry.velocityErrorVec_mps = v_err;
            entry.velocityError_mps    = norm(v_err);

            % --- Measurements ---
            if ~isempty(z)
                entry.measurements.nRows = numel(z);
                if storeFullThisEpoch
                    entry.measurements.z                = z;
                    entry.measurements.h                = h;
                    entry.measurements.prefitInnovation = z - h;
                    entry.measurements.postfitResidual  = postfitResidual;
                else
                    entry.measurements.z = []; entry.measurements.h = [];
                    entry.measurements.prefitInnovation = [];
                    entry.measurements.postfitResidual  = [];
                end
                entry.measurements.visibleTowerIds = visibleTowerIds;
                entry.measurements.elevation_rad   = elevations_rad;
            else
                entry.measurements.nRows = 0;
                entry.measurements.z = []; entry.measurements.h = [];
                entry.measurements.prefitInnovation = [];
                entry.measurements.postfitResidual  = [];
                entry.measurements.visibleTowerIds  = [];
                entry.measurements.elevation_rad    = [];
            end

            % --- Error chain ---
            % A zero-visibility epoch (no towers in view -- inevitable for a fast
            % LEO overflying a regional tower network) yields a partial errStruct
            % without the per-measurement totals. Treat it like the empty-errStruct
            % coasting case below rather than crashing. GEO/MEO always keep towers in
            % view, so the field is always present there and this is byte-identical.
            if ~isempty(errStruct) && isfield(errStruct,'truthTotal_m')
                entry.errors.truthTotal_m = errStruct.truthTotal_m;
                entry.errors.modelTotal_m = errStruct.modelTotal_m;
                entry.errors.bySource     = errStruct.bySource;
                if isfield(errStruct,'towerClockTruth_m')
                    entry.towerClockTruth_m = errStruct.towerClockTruth_m;
                    entry.towerClockModel_m = errStruct.towerClockModel_m;
                    entry.towerClockCorrectionError_m = ...
                        errStruct.towerClockTruth_m - errStruct.towerClockModel_m;
                else
                    entry.towerClockTruth_m = []; entry.towerClockModel_m = [];
                    entry.towerClockCorrectionError_m = [];
                end
                if isfield(errStruct,'sagnacTruth_m')
                    ltVals_ = [];
                    if isfield(errStruct,'lightTimeModel_s')
                        ltVals_ = errStruct.lightTimeModel_s(isfinite(errStruct.lightTimeModel_s));
                    end
                    if isempty(ltVals_); ltVals_ = 0; end
                    entry.meanLightTime_s = mean(ltVals_);
                    entry.maxLightTime_s  = max(ltVals_);
                else
                    entry.meanLightTime_s = 0; entry.maxLightTime_s = 0;
                end
                labels_ = {'code','trop','iono','hwDelay','mp'};
                for j_ = 1:numel(labels_)
                    lbl_ = labels_{j_};
                    if isfield(errStruct.bySource,'truth_m') && isfield(errStruct.bySource.truth_m,lbl_)
                        t_k = errStruct.bySource.truth_m.(lbl_);
                        m_k = errStruct.bySource.model_m.(lbl_);
                        if ~isempty(t_k)
                            entry.perSourceTruthRMS.(lbl_) = sqrt(mean((t_k-m_k).^2));
                            entry.perSourceModelRMS.(lbl_) = sqrt(mean(m_k.^2));
                        else
                            entry.perSourceTruthRMS.(lbl_) = 0;
                            entry.perSourceModelRMS.(lbl_) = 0;
                        end
                    else
                        entry.perSourceTruthRMS.(lbl_) = 0;
                        entry.perSourceModelRMS.(lbl_) = 0;
                    end
                end
            else
                entry.errors.truthTotal_m = []; entry.errors.modelTotal_m = [];
                entry.errors.bySource = struct();
                entry.towerClockTruth_m = []; entry.towerClockModel_m = [];
                entry.towerClockCorrectionError_m = [];
                entry.meanLightTime_s = 0; entry.maxLightTime_s = 0;
                srcLabels_ = {'code','trop','iono','hwDelay','mp'};
                for j_ = 1:numel(srcLabels_)
                    lbl_ = srcLabels_{j_};
                    entry.perSourceTruthRMS.(lbl_) = 0;
                    entry.perSourceModelRMS.(lbl_) = 0;
                end
            end

            % --- H/R/NIS ---
            if storeFullThisEpoch; entry.H = H; entry.R = R;
            else; entry.H = []; entry.R = []; end
            entry.NIS    = NIS;
            entry.Rsize  = [0, 0]; entry.Rdiag = [];
            if ~isempty(R)
                entry.Rsize = [size(R,1), size(R,2)]; entry.Rdiag = diag(R);
            end

            % --- Scalar error metrics ---
            r_err = x(sm.r_idx) - asset.r_ecef_m;
            entry.positionError_m    = norm(r_err);
            entry.positionErrorVec_m = r_err;
            eul_err = revgnss.AttitudeKinematics.wrapEuler(reportEuler_rad - asset.attitude_euler_rad);
            entry.attitudeError_rad    = eul_err;
            entry.clockBiasError_m     = x(sm.b_rx_idx) - asset.clock.getBiasMeters();
            entry.clockDriftError_mps  = x(sm.bdot_rx_idx) - asset.clock.getDriftMetersPerSecond();
            entry.fracFreqError        = entry.clockDriftError_mps / c;
            entry.numVisibleTowers     = numel(visibleTowerIds);

            % --- Measurement row counts ---
            if ~isempty(errStruct) && isfield(errStruct,'nPseudorange')
                M_pr = errStruct.nPseudorange;
            else
                M_pr = numel(z);
            end
            entry.numPseudorangeMeasurements = M_pr;
            entry.numMeasurements            = M_pr;
            entry.numMeasurementRows         = numel(z);
            M_dop_rows = 0;
            if ~isempty(errStruct) && isfield(errStruct,'measType_perRow')
                M_dop_rows = sum(strcmp(errStruct.measType_perRow,'doppler'));
            elseif ~isempty(errStruct) && isfield(errStruct,'doppler') && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z)
                M_dop_rows = numel(errStruct.doppler.z);
            end
            entry.numDopplerRows = M_dop_rows;
            M_car_rows = 0;
            if ~isempty(errStruct) && isfield(errStruct,'measType_perRow')
                M_car_rows = sum(strcmp(errStruct.measType_perRow,'carrier'));
            end
            entry.numCarrierRows = M_car_rows;

            % --- Innovation / residual RMS ---
            if ~isempty(z) && M_pr > 0 && numel(z) >= M_pr
                innPR = z(1:M_pr) - h(1:M_pr);
                entry.prefitPseudorangeRMS_m = sqrt(mean(innPR.^2));
                entry.prefitInnovationRMS    = entry.prefitPseudorangeRMS_m;
                if M_dop_rows > 0 && numel(z) >= M_pr + M_dop_rows
                    innDop = z(M_pr+1:M_pr+M_dop_rows) - h(M_pr+1:M_pr+M_dop_rows);
                    entry.prefitDopplerRMS_mps = sqrt(mean(innDop.^2));
                else
                    entry.prefitDopplerRMS_mps = 0;
                end
            else
                entry.prefitPseudorangeRMS_m = 0;
                entry.prefitInnovationRMS    = 0;
                entry.prefitDopplerRMS_mps   = 0;
            end
            if ~isempty(postfitResidual) && numel(postfitResidual) >= M_pr && M_pr > 0
                resPR = postfitResidual(1:M_pr);
                entry.postfitPseudorangeRMS_m = sqrt(mean(resPR.^2));
                entry.postfitResidualRMS      = entry.postfitPseudorangeRMS_m;
                if M_dop_rows > 0 && numel(postfitResidual) >= M_pr + M_dop_rows
                    resDop = postfitResidual(M_pr+1:M_pr+M_dop_rows);
                    entry.postfitDopplerRMS_mps = sqrt(mean(resDop.^2));
                else
                    entry.postfitDopplerRMS_mps = 0;
                end
            else
                entry.postfitPseudorangeRMS_m = 0;
                entry.postfitResidualRMS      = 0;
                entry.postfitDopplerRMS_mps   = 0;
            end
            if ~isempty(errStruct) && isfield(errStruct,'doppler') && ...
                    isfield(errStruct.doppler,'prefit') && ~isempty(errStruct.doppler.prefit)
                entry.dopplerPrefitRMS_mps = sqrt(mean(errStruct.doppler.prefit.^2));
            else
                entry.dopplerPrefitRMS_mps = entry.prefitDopplerRMS_mps;
            end

            % --- Per-type NIS ---
            entry.NIS_code = 0; entry.NIS_doppler = 0; entry.NIS_carrier = 0;
            if ~isempty(z) && ~isempty(h) && ~isempty(R) && numel(z) == numel(h)
                inn_all = z - h;
                if ~isempty(errStruct) && isfield(errStruct,'measType_perRow') && ...
                        numel(errStruct.measType_perRow) == numel(z)
                    mtype_r = errStruct.measType_perRow;
                    prMask  = strcmp(mtype_r,'code') | strcmp(mtype_r,'ifCode');
                    dopMask = strcmp(mtype_r,'doppler');
                    carMask = strcmp(mtype_r,'carrier');
                    if any(prMask);  entry.NIS_code    = localNis_(inn_all(prMask),  R(prMask,prMask));   end
                    if any(dopMask); entry.NIS_doppler = localNis_(inn_all(dopMask), R(dopMask,dopMask)); end
                    if any(carMask); entry.NIS_carrier = localNis_(inn_all(carMask), R(carMask,carMask)); end
                elseif M_pr > 0 && numel(z) >= M_pr
                    entry.NIS_code = localNis_(inn_all(1:M_pr), R(1:M_pr,1:M_pr));
                end
            end

            % --- NEES ---
            entry.NEES_pos = NaN;
            try
                P_pos = ekf.P(sm.r_idx, sm.r_idx);
                if rcond(P_pos) > 1e-15; entry.NEES_pos = (r_err' * (P_pos \ r_err)) / 3; end
            catch; end
            entry.NEES_vel = NaN;
            try
                P_vel = ekf.P(sm.v_idx, sm.v_idx);
                if rcond(P_vel) > 1e-15; entry.NEES_vel = (v_err' * (P_vel \ v_err)) / 3; end
            catch; end
            entry.NEES_clk = NaN;
            try
                clk_err_ = [x(sm.b_rx_idx) - asset.clock.getBiasMeters(); ...
                             x(sm.bdot_rx_idx) - asset.clock.getDriftMetersPerSecond()];
                clk_idx_ = [sm.b_rx_idx; sm.bdot_rx_idx];
                P_clk_   = ekf.P(clk_idx_, clk_idx_);
                if rcond(P_clk_) > 1e-15; entry.NEES_clk = (clk_err_' * (P_clk_ \ clk_err_)) / 2; end
            catch; end
            entry.NEES_att = NaN;
            try
                % R-7 (v4): score the attitude NEES with the EKF's QUATERNION-AWARE
                % small-angle error (the error in P(euler_idx) space), not a raw
                % wrapped-Euler subtraction which lives in a different space and is
                % ill-defined near gimbal lock. Matches ReverseGNSSEKF.computeNEES.
                if ekf.estimateAttitude
                    att_err_ = ekf.attitudeSmallAngleError_(asset.attitude_euler_rad);
                    P_att_   = ekf.P(sm.euler_idx, sm.euler_idx);
                    if rcond(P_att_) > 1e-15; entry.NEES_att = (att_err_' * (P_att_ \ att_err_)) / 3; end
                end
            catch; end

            % --- Clock gauge diagnostics ---
            entry.clockGaugeRowsAdded        = 0;
            entry.clockGaugeBiasResidual_m   = NaN;
            entry.clockGaugeDriftResidual_mps= NaN;
            entry.clockSubspaceRank          = NaN;
            entry.clockSubspaceCondNum       = NaN;
            if ~isempty(errStruct) && isfield(errStruct,'gaugeInfo')
                gi = errStruct.gaugeInfo;
                if isfield(gi,'rowsAdded');        entry.clockGaugeRowsAdded = gi.rowsAdded;               end
                if isfield(gi,'biasResidual_m');   entry.clockGaugeBiasResidual_m = gi.biasResidual_m;     end
                if isfield(gi,'driftResidual_mps');entry.clockGaugeDriftResidual_mps = gi.driftResidual_mps;end
                if isfield(gi,'clockSubspaceRank');entry.clockSubspaceRank = gi.clockSubspaceRank;         end
                if isfield(gi,'clockSubspaceCondNum');entry.clockSubspaceCondNum = gi.clockSubspaceCondNum;end
            end

            % --- Tx code bias gauge ---
            entry.txCodeBiasGaugeRowsAdded  = 0;
            entry.txCodeBiasGaugeResidual_m = NaN;
            entry.nTxCodeBiasStates         = 0;
            if ~isempty(errStruct) && isfield(errStruct,'txGaugeInfo')
                tgi = errStruct.txGaugeInfo;
                if isfield(tgi,'rowsAdded');       entry.txCodeBiasGaugeRowsAdded  = tgi.rowsAdded;        end
                if isfield(tgi,'gaugeResidual_m'); entry.txCodeBiasGaugeResidual_m = tgi.gaugeResidual_m;  end
            end
            if ~isempty(ekf) && isprop(ekf,'nTxCodeBiasStates')
                entry.nTxCodeBiasStates = ekf.nTxCodeBiasStates;
            end

            % --- Separated EKF innovation accounting ---
            entry.physicalNIS57  = NaN; entry.gaugeNIS57     = NaN;
            entry.augmentedNIS57 = NaN; entry.physicalDof57  = 0;
            entry.gaugeDof57     = 0;   entry.physicalRms57  = NaN;
            entry.gaugeRms57     = NaN; entry.augRms57       = NaN;
            entry.codeRms57      = NaN; entry.carrierRms57   = NaN; entry.dopplerRms57 = NaN;
            if ~isempty(errStruct) && isfield(errStruct,'ekfAccounting57') && ...
                    isfield(errStruct.ekfAccounting57,'physicalNIS')
                a57 = errStruct.ekfAccounting57; r57 = errStruct.ekfAccountingRms57;
                entry.physicalNIS57  = a57.physicalNIS;  entry.gaugeNIS57    = a57.gaugeNIS;
                entry.augmentedNIS57 = a57.augmentedNIS; entry.physicalDof57 = a57.physicalDof;
                entry.gaugeDof57     = a57.gaugeDof;     entry.physicalRms57 = r57.physicalRms;
                entry.gaugeRms57     = r57.gaugeRms;     entry.augRms57      = r57.augmentedRms;
                entry.codeRms57      = r57.codeRms;      entry.carrierRms57  = r57.carrierRms;
                entry.dopplerRms57   = r57.dopplerRms;
            end

            % --- Carrier slip ---
            entry.carrierSlipNSlips      = 0;
            entry.carrierSlipTotalJump_m = 0;
            if ~isempty(errStruct) && isfield(errStruct,'slipInfo')
                si14 = errStruct.slipInfo;
                if isfield(si14,'nSlips'); entry.carrierSlipNSlips = si14.nSlips; end
                if isfield(si14,'jumpMags_m') && ~isempty(si14.jumpMags_m)
                    entry.carrierSlipTotalJump_m = sum(si14.jumpMags_m);
                end
            end

            % --- ZWD ---
            entry.zwdEstimated = false; entry.nZwdStates = 0;
            if ~isempty(ekf) && isprop(ekf,'estimateZwd') && ekf.estimateZwd
                entry.zwdEstimated = true; entry.nZwdStates = ekf.nZwdStates;
            end

            % --- Clock observability Gramian (sliding window) ---
            entry.clockObsRankPhysical = NaN; entry.clockObsRankGauged   = NaN;
            entry.clockObsCondPhysical = NaN; entry.clockObsCondGauged   = NaN;
            entry.clockObsWeakPhysical = NaN; entry.clockObsWeakGauged   = NaN;
            if obj.clockObsEnable_
                clkIdx10 = [sm.b_rx_idx; sm.bdot_rx_idx];
                if isfield(sm,'towerClockIdx')
                    tci10  = sm.towerClockIdx;
                    flat10 = reshape(tci10', [], 1);
                    clkIdx10 = [clkIdx10; flat10(flat10 > 0)];
                end
                clkIdx10 = clkIdx10(clkIdx10 > 0);
                if ~isempty(H) && ~isempty(R) && ~isempty(clkIdx10) && size(H,2) >= max(clkIdx10)
                    H_clk10 = H(:, clkIdx10); Rd10 = diag(R);
                else
                    H_clk10 = zeros(0, numel(clkIdx10)); Rd10 = zeros(0,1);
                end
                H_gauge10 = zeros(0, numel(clkIdx10)); Rd_g10 = zeros(0,1);
                if ~isempty(errStruct) && isfield(errStruct,'gaugeInfo')
                    gi10 = errStruct.gaugeInfo;
                    if isfield(gi10,'H_gauge') && ~isempty(gi10.H_gauge) && ...
                            ~isempty(clkIdx10) && size(gi10.H_gauge,2) >= max(clkIdx10)
                        H_gauge10 = gi10.H_gauge(:, clkIdx10);
                    end
                    if isfield(gi10,'R_gauge_diag') && ~isempty(gi10.R_gauge_diag)
                        Rd_g10 = gi10.R_gauge_diag;
                    end
                end
                buf10 = obj.clockObsBuf_;
                buf10.H_phys{end+1}   = H_clk10;  buf10.Rd_phys{end+1}  = Rd10;
                buf10.H_gauge{end+1}  = H_gauge10; buf10.Rd_gauge{end+1} = Rd_g10;
                wl10 = obj.clockObsWinLen_;
                if numel(buf10.H_phys) > wl10
                    buf10.H_phys  = buf10.H_phys(end-wl10+1:end);
                    buf10.Rd_phys = buf10.Rd_phys(end-wl10+1:end);
                    buf10.H_gauge = buf10.H_gauge(end-wl10+1:end);
                    buf10.Rd_gauge= buf10.Rd_gauge(end-wl10+1:end);
                end
                obj.clockObsBuf_ = buf10;
                if numel(buf10.H_phys) >= obj.clockObsMinWin_ && ...
                        ~isempty(clkIdx10) && mod(numel(clkIdx10),2) == 0
                    if isfinite(obj.lastRecordedTime_s_) && obj.nEpochs >= 1
                        dt10 = t_s - obj.lastRecordedTime_s_;
                    else
                        dt10 = 1;
                    end
                    if dt10 <= 0 || ~isfinite(dt10); dt10 = 1; end
                    try
                        obs10 = revgnss.ObservabilityDiagnostics.computeClockWindowObservability( ...
                            buf10.H_phys, buf10.Rd_phys, buf10.H_gauge, buf10.Rd_gauge, ...
                            dt10, sm, obj.clockObsRankTol_);
                        entry.clockObsRankPhysical = obs10.rankPhysical;
                        entry.clockObsRankGauged   = obs10.rankGauged;
                        entry.clockObsCondPhysical = obs10.conditionPhysical;
                        entry.clockObsCondGauged   = obs10.conditionGauged;
                        entry.clockObsWeakPhysical = obs10.weakStatesPhysical;
                        entry.clockObsWeakGauged   = obs10.weakStatesGauged;
                    catch; end
                end
            end

            % --- Heavy diagnostic gate ---
            heavyDiag_ = obj.heavyDiagEveryEpoch_ || ...
                strcmp(obj.storagePolicyMode_,'full') || ...
                (obj.nEpochs == 0) || ...
                (t_s - obj.lastHeavyDiagTime_s_ >= obj.heavyDiagInterval_s_);
            if heavyDiag_; obj.lastHeavyDiagTime_s_ = t_s; end

            % --- Jacobian / attitude diagnostics ---
            if ~isempty(H) && size(H,2) >= 9
                H_att = H(:, sm.euler_idx);
                entry.attitudeJacobianNorm = norm(H_att, 'fro');
                if heavyDiag_
                    sv_att  = svd(H_att);
                    tol_sv  = max(sv_att) * 1e-6;
                    attRank = sum(sv_att > tol_sv);
                    entry.attitudeRank   = attRank;
                    entry.attitudeCondNum= NaN;
                    if attRank >= 2
                        entry.attitudeCondNum = max(sv_att(1:attRank)) / min(sv_att(1:attRank));
                    end
                    % Attitude-ambiguity separability
                    entry.attitudeSeparable     = false;
                    entry.attitudeAmbCorrMaxAbs = NaN;
                    if isfield(sm,'ambiguityIdx3d')
                        ambFlat = nonzeros(sm.ambiguityIdx3d(:));
                        if ~isempty(ambFlat) && max(ambFlat) <= size(H,2)
                            Hb_all  = H(:, ambFlat); carRows = any(Hb_all ~= 0, 2);
                            if sum(carRows) > 0
                                Hac = H_att(carRows,:); Hbc = Hb_all(carRows,:);
                                tolR = 1e-6 * max(norm(Hac,'fro'), norm(Hbc,'fro'));
                                rB   = rank(Hbc, tolR); rAB = rank([Hac Hbc], tolR);
                                entry.attitudeSeparable = (rAB > rB);
                                nHac = norm(Hac,'fro');
                                if nHac > 1e-15
                                    nn  = max(vecnorm(Hbc), 1e-15);
                                    Ccc = abs(Hbc' * Hac) ./ nn' ./ max(vecnorm(Hac), 1e-15);
                                    entry.attitudeAmbCorrMaxAbs = max(Ccc(:));
                                end
                            end
                        end
                    end
                else
                    entry.attitudeRank          = NaN;
                    entry.attitudeCondNum       = NaN;
                    entry.attitudeSeparable     = false;
                    entry.attitudeAmbCorrMaxAbs = NaN;
                end
            else
                entry.attitudeJacobianNorm  = 0;
                entry.attitudeRank          = 0;
                entry.attitudeCondNum       = NaN;
                entry.attitudeSeparable     = false;
                entry.attitudeAmbCorrMaxAbs = NaN;
            end
            if heavyDiag_ && ~isempty(H)
                entry.measurementRank = rank(H);
            else
                entry.measurementRank = 0;
            end
            if heavyDiag_ && ~isempty(H) && ~isempty(R)
                S_mat_ = H * ekf.P * H' + R;
                entry.conditionNumberS = cond(S_mat_);
            else
                entry.conditionNumberS = NaN;
            end

            % --- Geometry / DOPs ---
            entry.geometryRank = NaN; entry.gdopLike = NaN;
            entry.pdopLike = NaN;    entry.tdopLike = NaN;
            entry.positionClockCondition = NaN;
            posClkIdx_ = [sm.r_idx(:); sm.b_rx_idx]';
            if heavyDiag_ && ~isempty(H) && ~isempty(R) && M_pr >= 4 && ...
                    numel(posClkIdx_) == 4 && size(H,2) >= max(posClkIdx_)
                H_pr_ = H(1:M_pr,:); R_pr_ = R(1:M_pr,1:M_pr);
                H_pc_ = H_pr_(:, posClkIdx_);
                entry.geometryRank = rank(H_pc_);
                if entry.geometryRank >= 4
                    try
                        N_geom_ = H_pc_' * (R_pr_ \ eye(M_pr)) * H_pc_;
                        Q_geom_ = N_geom_ \ eye(4);
                        entry.gdopLike               = sqrt(max(trace(Q_geom_),          0));
                        entry.pdopLike               = sqrt(max(trace(Q_geom_(1:3,1:3)), 0));
                        entry.tdopLike               = sqrt(max(Q_geom_(4,4),            0));
                        entry.positionClockCondition = cond(N_geom_);
                    catch; end
                end
            end

            % --- Per-effect contributions ---
            rms3m_   = @(t_,m_) struct('truthRMS_m',sqrt(mean(t_.^2)),'modelRMS_m',sqrt(mean(m_.^2)),'mismatchRMS_m',sqrt(mean((t_-m_).^2)));
            rms3mps_ = @(t_,m_) struct('truthRMS_mps',sqrt(mean(t_.^2)),'modelRMS_mps',sqrt(mean(m_.^2)),'mismatchRMS_mps',sqrt(mean((t_-m_).^2)));
            z3m_   = struct('truthRMS_m',0,'modelRMS_m',0,'mismatchRMS_m',0);
            z3mps_ = struct('truthRMS_mps',0,'modelRMS_mps',0,'mismatchRMS_mps',0);
            z3cyc_ = struct('truthRMS_cycles',0,'modelRMS_cycles',0,'mismatchRMS_cycles',0);
            cnt_ = struct('codeNoise',z3m_,'troposphere',z3m_,'ionosphere',z3m_, ...
                'hardwareDelay',z3m_,'multipath',z3m_,'scintillationCodeNoise',z3m_, ...
                'sagnac',z3m_,'shapiro',z3m_,'towerSurvey',z3m_,'receiverPCO',z3m_, ...
                'towerPCO',z3m_,'pcv',z3m_,'towerClock',z3m_,'correlatedCommonMode',z3m_, ...
                'correlatedSameTower',z3m_,'correlatedIndependent',z3m_,'total',z3m_, ...
                'dopplerRangeRate',z3mps_,'dopplerTowerClockDrift',z3mps_,'dopplerNoise',z3mps_, ...
                'carrierPhaseCycles',z3cyc_,'carrierPhaseMeters',z3m_);
            if ~isempty(errStruct)
                if isfield(errStruct,'bySource') && isfield(errStruct.bySource,'truth_m')
                    bst_ = errStruct.bySource.truth_m; bsm_ = errStruct.bySource.model_m;
                    srcMap_ = {'code','codeNoise';'trop','troposphere';'iono','ionosphere';'hwDelay','hardwareDelay';'mp','multipath'};
                    for si_ = 1:size(srcMap_,1)
                        src_ = srcMap_{si_,1}; fld_ = srcMap_{si_,2};
                        if isfield(bst_,src_) && ~isempty(bst_.(src_))
                            cnt_.(fld_) = rms3m_(bst_.(src_), bsm_.(src_));
                        end
                    end
                    if isfield(bst_,'scintillation') && ~isempty(bst_.scintillation)
                        scintMdl_ = zeros(size(bst_.scintillation));
                        if isfield(bsm_,'scintillation'); scintMdl_ = bsm_.scintillation; end
                        cnt_.scintillationCodeNoise = rms3m_(bst_.scintillation, scintMdl_);
                    end
                end
                if isfield(errStruct,'sagnacTruth_m') && ~isempty(errStruct.sagnacTruth_m)
                    cnt_.sagnac  = rms3m_(errStruct.sagnacTruth_m, errStruct.sagnacModel_m);
                    cnt_.shapiro = rms3m_(errStruct.shapiroTruth_m, errStruct.shapiroModel_m);
                    cnt_.pcv     = rms3m_(errStruct.pcvTruth_m, errStruct.pcvModel_m);
                end
                if isfield(errStruct,'towerSurveyTruth_m') && ~isempty(errStruct.towerSurveyTruth_m)
                    cnt_.towerSurvey = rms3m_(errStruct.towerSurveyTruth_m, errStruct.towerSurveyModel_m);
                end
                if isfield(errStruct,'receiverPCOTruth_m') && ~isempty(errStruct.receiverPCOTruth_m)
                    cnt_.receiverPCO = rms3m_(errStruct.receiverPCOTruth_m, errStruct.receiverPCOModel_m);
                end
                if isfield(errStruct,'towerPCOTruth_m') && ~isempty(errStruct.towerPCOTruth_m)
                    cnt_.towerPCO = rms3m_(errStruct.towerPCOTruth_m, errStruct.towerPCOModel_m);
                end
                if isfield(errStruct,'towerClockTruth_m') && ~isempty(errStruct.towerClockTruth_m)
                    cnt_.towerClock = rms3m_(-errStruct.towerClockTruth_m, -errStruct.towerClockModel_m);
                end
                if isfield(errStruct,'correlatedNoise')
                    cn_ = errStruct.correlatedNoise; Mv_ = numel(cn_.common_m);
                    if Mv_ > 0
                        zv_ = zeros(Mv_,1);
                        cnt_.correlatedCommonMode  = rms3m_(cn_.common_m, zv_);
                        cnt_.correlatedSameTower   = rms3m_(cn_.sameTower_m, zv_);
                        cnt_.correlatedIndependent = rms3m_(cn_.independent_m, zv_);
                    end
                end
                if isfield(errStruct,'sagnacTruth_m') && ~isempty(errStruct.truthTotal_m)
                    tt_ = errStruct.truthTotal_m + errStruct.sagnacTruth_m + ...
                          errStruct.shapiroTruth_m + errStruct.pcvTruth_m;
                    tm_ = errStruct.modelTotal_m + errStruct.sagnacModel_m + ...
                          errStruct.shapiroModel_m + errStruct.pcvModel_m;
                    if isfield(errStruct,'towerSurveyTruth_m')
                        tt_ = tt_ + errStruct.towerSurveyTruth_m;
                        tm_ = tm_ + errStruct.towerSurveyModel_m;
                    end
                    if isfield(errStruct,'receiverPCOTruth_m')
                        tt_ = tt_ + errStruct.receiverPCOTruth_m;
                        tm_ = tm_ + errStruct.receiverPCOModel_m;
                    end
                    if isfield(errStruct,'towerPCOTruth_m')
                        tt_ = tt_ + errStruct.towerPCOTruth_m;
                        tm_ = tm_ + errStruct.towerPCOModel_m;
                    end
                    if isfield(errStruct,'correlatedNoise')
                        cn2_ = errStruct.correlatedNoise;
                        tt_ = tt_ + cn2_.common_m + cn2_.sameTower_m + cn2_.independent_m;
                    end
                    cnt_.total = rms3m_(tt_, tm_);
                end
                if isfield(errStruct,'doppler') && isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z)
                    cnt_.dopplerRangeRate = rms3mps_(errStruct.doppler.z, errStruct.doppler.h);
                    if isfield(errStruct.doppler,'towerClockDriftTruth_mps') && ...
                            ~isempty(errStruct.doppler.towerClockDriftTruth_mps)
                        cnt_.dopplerTowerClockDrift = rms3mps_( ...
                            errStruct.doppler.towerClockDriftTruth_mps, ...
                            errStruct.doppler.towerClockDriftModel_mps);
                    end
                end
                if isfield(errStruct,'carrierPhase') && isfield(errStruct.carrierPhase,'phi_cycles') && ...
                        ~isempty(errStruct.carrierPhase.phi_cycles)
                    phi_ = errStruct.carrierPhase.phi_cycles;
                    lam_ = errStruct.carrierPhase.lambda_m;
                    cnt_.carrierPhaseCycles = struct('truthRMS_cycles',sqrt(mean(phi_.^2)), ...
                        'modelRMS_cycles',0,'mismatchRMS_cycles',sqrt(mean(phi_.^2)));
                    cnt_.carrierPhaseMeters = rms3m_(phi_ * lam_, zeros(size(phi_)));
                end
            end
            entry.contributions = cnt_;

            % --- Pdiag and sigma ---
            Pdiag_ = diag(ekf.P);
            entry.Pdiag              = Pdiag_;
            entry.estimate.Pdiag     = Pdiag_;
            entry.estimate.sigma     = sqrt(max(0, Pdiag_));
            if storeFullThisEpoch; entry.estimate.P = ekf.P; end
            entry.estimatedPositionSigma_m   = sqrt(sum(Pdiag_(sm.r_idx)));
            entry.estimatedAttitudeSigma_rad = sqrt(sum(Pdiag_(sm.euler_idx)));

            % --- Differential attitude ---
            if ~isempty(errStruct) && isfield(errStruct,'diffAttRows') && isstruct(errStruct.diffAttRows)
                da_ = errStruct.diffAttRows;
                entry.diffAttNRows    = da_.nRows;
                entry.diffAttResidRMS = da_.residualRMS_m;
                entry.diffAttActive   = da_.active;
                entry.diffAttActiveBaselines        = revgnss.Diagnostics.fieldOr_(da_,'activeBaselines',0);
                entry.diffAttLostBaselines          = revgnss.Diagnostics.fieldOr_(da_,'lostBaselines',0);
                entry.diffAttRecalibratedBaselines  = revgnss.Diagnostics.fieldOr_(da_,'recalibratedBaselines',0);
                entry.diffAttRejectedRows           = revgnss.Diagnostics.fieldOr_(da_,'rejectedRows',0);
            else
                entry.diffAttNRows = 0; entry.diffAttResidRMS = NaN;
                entry.diffAttActive = false; entry.diffAttActiveBaselines = 0;
                entry.diffAttLostBaselines = 0; entry.diffAttRecalibratedBaselines = 0;
                entry.diffAttRejectedRows  = 0;
            end

            % --- Attitude observability audit ---
            mTypeForAudit_ = {};
            if ~isempty(errStruct) && isfield(errStruct,'measType_perRow')
                mTypeForAudit_ = errStruct.measType_perRow;
            end
            cfg_ = obj.cfg_saved_;
            if ~isempty(cfg_) && isfield(cfg_,'diagnostics') && ...
                    isfield(cfg_.diagnostics,'attitudeObservability') && ...
                    isfield(cfg_.diagnostics.attitudeObservability,'enable') && ...
                    cfg_.diagnostics.attitudeObservability.enable
                try
                    obj.lastAttitudeAudit_ = revgnss.AttitudeObservability.audit( ...
                        H, sm, cfg_, mTypeForAudit_);
                catch; end
            end
            if ~isempty(cfg_) && isfield(cfg_,'diagnostics') && ...
                    isfield(cfg_.diagnostics,'attitudeJacobianAudit') && ...
                    isfield(cfg_.diagnostics.attitudeJacobianAudit,'enable') && ...
                    cfg_.diagnostics.attitudeJacobianAudit.enable
                try
                    obj.lastAttitudeJacobianAudit_ = revgnss.AttitudeJacobianAudit.audit( ...
                        H, sm, cfg_, mTypeForAudit_);
                catch; end
            end

            % --- Write to flat arrays ---
            obj.storeEntry_(k, entry);
            % Store weak states counts
            if isfield(entry,'clockObsWeakPhysical') && isnumeric(entry.clockObsWeakPhysical)
                obj.ck_oWkP_(k) = entry.clockObsWeakPhysical;
            end
            if isfield(entry,'clockObsWeakGauged') && isnumeric(entry.clockObsWeakGauged)
                obj.ck_oWkG_(k) = entry.clockObsWeakGauged;
            end
            obj.lastRecordedTime_s_ = t_s;
        end

        % -----------------------------------------------------------------
        function m = getMeta(obj)
            m.storageBackend  = 'SimulationDataStore';
            m.schemaVersion   = 3;
            m.schemaName      = 'FlatSimulationDataStore';
            m.nEpochs         = obj.nEpochs;
            m.nState          = obj.nx_;
            m.nTowers         = obj.nTowers_;
            m.nReceivers      = obj.nReceivers_;
        end

        % -----------------------------------------------------------------
        function tf = hasArrayData(obj)
            tf = true;
        end

        % -----------------------------------------------------------------
        function printStorageSummary(obj)
            fprintf('  Storage backend : SimulationDataStore\n');
            fprintf('  Schema          : FlatSimulationDataStore v3\n');
            fprintf('  Epochs written  : %d\n', obj.nEpochs);
            fprintf('  State dim       : %d\n', obj.nx_);
            fprintf('  nTowers         : %d\n', obj.nTowers_);
            fprintf('  nReceivers      : %d\n', obj.nReceivers_);
        end

        % -----------------------------------------------------------------
        %  GETTERS — all read directly from flat preallocated arrays
        % -----------------------------------------------------------------
        function t = getTimeVector(obj)
            t = obj.t_s_(1:obj.nEpochs);
        end

        function e = getPositionErrors(obj)
            e = obj.er_pn_(1:obj.nEpochs);
        end

        function e = getPositionErrorVecs(obj)
            e = obj.er_pv_(:,1:obj.nEpochs);
        end

        function r = getTruthPositionVecs(obj)
            r = obj.tr_r_(:,1:obj.nEpochs);
        end

        function v = getTruthVelocityVecs(obj)
            v = obj.tr_v_(:,1:obj.nEpochs);
        end

        function e = getClockBiasErrors(obj)
            e = obj.er_cb_(1:obj.nEpochs);
        end

        function e = getClockDriftErrors(obj)
            e = obj.er_cd_(1:obj.nEpochs);
        end

        function e = getFractionalFrequencyErrors(obj)
            e = obj.er_ff_(1:obj.nEpochs);
        end

        function n = getNIS(obj)
            n = obj.cn_NIS_(1:obj.nEpochs);
        end

        function nu = getPrefitInnovationRMS(obj)
            nu = obj.rs_pfa_(1:obj.nEpochs);
        end

        function res = getPostfitResidualRMS(obj)
            res = obj.rs_poa_(1:obj.nEpochs);
        end

        function nv = getNumVisibleTowers(obj)
            nv = obj.mc_nv_(1:obj.nEpochs);
        end

        function nm = getNumMeasurements(obj)
            nm = obj.mc_nc_(1:obj.nEpochs);
        end

        function nr = getNumMeasurementRows(obj)
            nr = obj.mc_nr_(1:obj.nEpochs);
        end

        function v = getGDOPLike(obj)
            v = obj.gm_gdop_(1:obj.nEpochs);
        end

        function v = getPDOPLike(obj)
            v = obj.gm_pdop_(1:obj.nEpochs);
        end

        function v = getTDOPLike(obj)
            v = obj.gm_tdop_(1:obj.nEpochs);
        end

        function v = getGeometryRank(obj)
            v = obj.gm_gRk_(1:obj.nEpochs);
        end

        function v = getAttitudeRank(obj)
            v = obj.gm_ajRk_(1:obj.nEpochs);
        end

        function v = getAttitudeCondNum(obj)
            v = obj.gm_ajCd_(1:obj.nEpochs);
        end

        function v = getEstimatedAttitudeSigma_rad(obj)
            v = obj.sg_aSig_(1:obj.nEpochs);
        end

        function v = getAttitudeSeparable(obj)
            v = obj.sg_aSep_(1:obj.nEpochs);
        end

        function v = getAttitudeAmbCorrMaxAbs(obj)
            v = obj.sg_aAmb_(1:obj.nEpochs);
        end

        function v = getAttitudeJacobianNorm(obj)
            v = obj.gm_ajN_(1:obj.nEpochs);
        end

        function e = getAttitudeErrorVecs(obj)
            e = obj.er_ar_(:,1:obj.nEpochs);
        end

        function v = getClockObsRankPhysical(obj)
            v = obj.ck_oRkP_(1:obj.nEpochs);
        end

        function v = getClockObsRankGauged(obj)
            v = obj.ck_oRkG_(1:obj.nEpochs);
        end

        function v = getClockObsCondPhysical(obj)
            v = obj.ck_oCdP_(1:obj.nEpochs);
        end

        function v = getClockObsCondGauged(obj)
            v = obj.ck_oCdG_(1:obj.nEpochs);
        end

        function v = getClockObsWeakStatesPhysical(obj)
            v = obj.ck_oWkP_(1:obj.nEpochs);
        end

        function v = getClockObsWeakStatesGauged(obj)
            v = obj.ck_oWkG_(1:obj.nEpochs);
        end

        function v = getClockGaugeRowsAdded(obj)
            v = obj.ck_gauR_(1:obj.nEpochs);
        end

        function v = getClockGaugeBiasResiduals(obj)
            v = obj.ck_gbR_(1:obj.nEpochs);
        end

        function v = getClockGaugeDriftResiduals(obj)
            v = obj.ck_gdR_(1:obj.nEpochs);
        end

        function v = getNTxCodeBiasStates(obj)
            v = obj.tx_nSt_(1:obj.nEpochs);
        end

        function v = getTxCodeBiasGaugeResiduals(obj)
            v = obj.tx_gRes_(1:obj.nEpochs);
        end

        function v = getTxCodeBiasGaugeRowsAdded(obj)
            v = obj.tx_gR_(1:obj.nEpochs);
        end

        function v = getDiffAttActive(obj)
            v = obj.da_act_(1:obj.nEpochs);
        end

        function v = getDiffAttNRows(obj)
            v = obj.da_nR_(1:obj.nEpochs);
        end

        function v = getDiffAttResidRMS(obj)
            v = obj.da_rR_(1:obj.nEpochs);
        end

        function v = getDiffAttActiveBaselines(obj)
            v = obj.da_aBl_(1:obj.nEpochs);
        end

        function v = getDiffAttLostBaselines(obj)
            v = obj.da_lBl_(1:obj.nEpochs);
        end

        function v = getDiffAttRecalibratedBaselines(obj)
            v = obj.da_rcBl_(1:obj.nEpochs);
        end

        function v = getDiffAttRejectedRows(obj)
            v = obj.da_rjR_(1:obj.nEpochs);
        end

        function [mn, mx] = getMeanMaxLightTime_s(obj)
            mn = obj.lt_mn_(1:obj.nEpochs);
            mx = obj.lt_mx_(1:obj.nEpochs);
        end

        function d = getDopplerInfo(obj)
            d = obj.getData().dopplerInfo;
        end

        function eu = getFinalTruthEuler_rad(obj)
            eu = obj.lastTruthEuler_rad_;
        end

        function eu = getFinalEstimateEuler_rad(obj)
            eu = obj.lastEstEuler_rad_;
        end

        function Pd = getPdiag(obj)
            if obj.nx_ > 0
                Pd = obj.es_Pd_(:,1:obj.nEpochs);
            else
                Pd = [];
            end
        end

        function C = getContributionSeries(obj)
            C = trimEff_(obj.eff_, obj.nEpochs);
        end

        function M = getTowerClockBiasMatrix(obj)
            if ~isempty(obj.tw_tru_)
                M = obj.tw_tru_(:,1:obj.nEpochs);
            else
                M = [];
            end
        end

        function perSrc = getPerSourceErrorRMS(obj)
            N = obj.nEpochs;
            perSrc.code    = obj.ps_cT_(1:N);
            perSrc.trop    = obj.ps_tT_(1:N);
            perSrc.iono    = obj.ps_iT_(1:N);
            perSrc.hwDelay = obj.ps_hT_(1:N);
            perSrc.mp      = obj.ps_mT_(1:N);
        end

        function v = getPrefitPseudorangeRMS(obj)
            v = obj.rs_pfc_(1:obj.nEpochs);
        end

        function v = getPostfitPseudorangeRMS(obj)
            v = obj.rs_poc_(1:obj.nEpochs);
        end

        function v = getPrefitDopplerRMS(obj)
            v = obj.rs_pfd_(1:obj.nEpochs);
        end

        function v = getPostfitDopplerRMS(obj)
            v = obj.rs_pod_(1:obj.nEpochs);
        end

        function v = getNEES(obj)
            v = obj.cn_NEESp_(1:obj.nEpochs);
        end

        function v = getVelocityNEES(obj)
            v = obj.cn_NEESv_(1:obj.nEpochs);
        end

        function v = getClockNEES(obj)
            v = obj.cn_NEESc_(1:obj.nEpochs);
        end

        function v = getAttitudeNEES(obj)
            v = obj.cn_NEESa_(1:obj.nEpochs);
        end

        function C = getNISByType(obj)
            C.code    = obj.cn_NIScod_(1:obj.nEpochs);
            C.doppler = obj.cn_NISdop_(1:obj.nEpochs);
            C.carrier = obj.cn_NIScar_(1:obj.nEpochs);
        end

        function v = getRxClockBiasTrue(obj)
            v = obj.tr_cbs_(1:obj.nEpochs);
        end

        function s = getLastAttitudeAudit(obj)
            s = obj.lastAttitudeAudit_;
        end

        function s = getLastAttitudeJacobianAudit(obj)
            s = obj.lastAttitudeJacobianAudit_;
        end

        function [sumNIS, dof, passes] = accumulatedNISTest(obj, nSigma)
            if nargin < 2; nSigma = 3; end
            nisVec = obj.getNIS(); mVec = obj.getNumMeasurementRows();
            valid  = isfinite(nisVec) & isfinite(mVec) & mVec > 0;
            sumNIS = sum(nisVec(valid)); dof = sum(mVec(valid));
            if dof > 0; passes = abs(sumNIS - dof) < nSigma * sqrt(2 * dof);
            else; passes = false; end
        end

        function s = getInnovationAccountingSummary57(obj)
            s = struct('available',false, ...
                'meanPhysicalNIS',NaN,'meanGaugeNIS',NaN,'meanAugmentedNIS',NaN, ...
                'meanPhysicalDof',NaN,'meanGaugeDof',NaN, ...
                'meanPhysicalRms',NaN,'meanGaugeRms',NaN,'meanAugRms',NaN, ...
                'meanCodeRms',NaN,'meanCarrierRms',NaN,'meanDopplerRms',NaN, ...
                'physicalConsistencyUsesGaugeRows',false);
            if obj.nEpochs < 1; return; end
            try
                N = obj.nEpochs;
                s.available          = any(isfinite(obj.s57_pN_(1:N)));
                s.meanPhysicalNIS    = mean(obj.s57_pN_(1:N), 'omitnan');
                s.meanGaugeNIS       = mean(obj.s57_gN_(1:N), 'omitnan');
                s.meanAugmentedNIS   = mean(obj.s57_aN_(1:N), 'omitnan');
                s.meanPhysicalDof    = mean(obj.s57_pD_(1:N), 'omitnan');
                s.meanGaugeDof       = mean(obj.s57_gD_(1:N), 'omitnan');
                s.meanPhysicalRms    = mean(obj.s57_pR_(1:N), 'omitnan');
                s.meanGaugeRms       = mean(obj.s57_gR_(1:N), 'omitnan');
                s.meanAugRms         = mean(obj.s57_aR_(1:N), 'omitnan');
                s.meanCodeRms        = mean(obj.s57_cR_(1:N), 'omitnan');
                s.meanCarrierRms     = mean(obj.s57_carR_(1:N), 'omitnan');
                s.meanDopplerRms     = mean(obj.s57_dR_(1:N), 'omitnan');
            catch; end
        end

        % -----------------------------------------------------------------
        function recordOrbitCache(obj, oc)
            if obj.frozen_; error('SimulationDataStore:frozen', 'Store is frozen after the simulation stage; post/report may only read.'); end
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
            d.truth.v_mps             = d.truth.v_cm_ecef_mps; % analysis script alias
            d.truth.r_m               = d.truth.r_cm_ecef_m;   % analysis script alias
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
            d.estimate.v_mps          = d.estimate.v_cm_ecef_mps; % analysis script alias
            d.estimate.r_m            = d.estimate.r_cm_ecef_m;   % analysis script alias
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

            % EKF innovation accounting
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

            % ---- Flat schema v3 top-level aliases ----
            d.schemaVersion  = 3;
            d.schemaName     = 'FlatSimulationDataStore';
            d.err_pos_norm_m        = d.error.positionNorm_m;
            d.err_pos_vec_m         = d.error.positionVec_m;
            d.err_clock_bias_m      = d.error.clockBias_m;
            d.err_clock_drift_mps   = d.error.clockDrift_mps;
            d.est_x                 = d.estimate.x;
            d.est_Pdiag             = d.estimate.Pdiag;
            d.meas_n_rows           = d.meas.nRows;
            d.consistency_NIS       = d.consistency.NIS;
            d.res_prefit_all_rms    = d.residual.prefitAllRMS;
            d.geom_gdop_like        = d.geom.gdopLike;
            d.geom_pdop_like        = d.geom.pdopLike;
            d.geom_tdop_like        = d.geom.tdopLike;
            d.att_jac_norm          = d.geom.attitudeJacobianNorm;
            d.att_rank              = d.geom.attitudeRank;
            d.att_sigma_rad         = d.attitude.attitudeSigma_rad;
            d.clk_obs_rank_phys     = d.clock.obsRankPhysical;
            d.clk_obs_rank_gauge    = d.clock.obsRankGauged;
            d.clk_obs_weak_phys     = obj.ck_oWkP_(1:N);
            d.clk_obs_weak_gauge    = obj.ck_oWkG_(1:N);
            d.clk_gauge_rows        = d.clock.gaugeRows;
            d.tx_gauge_rows         = d.txBias.gaugeRows;
            d.diff_att_active       = d.diffAtt.active;
            d.diff_att_n_rows       = d.diffAtt.nRows;
            d.slip_n_slips          = d.slip.nSlips;
            d.lt_mean_s             = d.lightTime.mean_s;
        end

        % -----------------------------------------------------------------
        function s = toCompactStruct(obj)
            s.version = 3;
            s.schema  = 'FlatSimulationDataStoreCompact';
            s.meta    = obj.getMeta();
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

        function parseClockObsCfg_(obj, cfg)
            try
                if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'clockObservability')
                    co = cfg.diagnostics.clockObservability;
                    if isfield(co,'enable');             obj.clockObsEnable_ = logical(co.enable);         end
                    if isfield(co,'windowLengthEpochs'); obj.clockObsWinLen_ = co.windowLengthEpochs;     end
                    if isfield(co,'minWindowEpochs');    obj.clockObsMinWin_ = co.minWindowEpochs;        end
                    if isfield(co,'rankTolerance');      obj.clockObsRankTol_ = co.rankTolerance;         end
                end
            catch; end
        end

        function parseHeavyDiagCfg_(obj, cfg)
            try
                if isfield(cfg,'data')
                    d = cfg.data;
                    if isfield(d,'heavyDiagnosticsInterval_s')
                        obj.heavyDiagInterval_s_ = d.heavyDiagnosticsInterval_s;
                    end
                    if isfield(d,'computeHeavyDiagnosticsEveryEpoch')
                        obj.heavyDiagEveryEpoch_ = logical(d.computeHeavyDiagnosticsEveryEpoch);
                    end
                elseif isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'storage')
                    st = cfg.diagnostics.storage;
                    if isfield(st,'heavyDiagInterval_s')
                        obj.heavyDiagInterval_s_ = st.heavyDiagInterval_s;
                    end
                    if isfield(st,'heavyDiagEveryEpoch')
                        obj.heavyDiagEveryEpoch_ = logical(st.heavyDiagEveryEpoch);
                    end
                end
            catch; end
        end

        function parseStoragePolicyCfg_(obj, cfg)
            try
                if isfield(cfg,'data') && isfield(cfg.data,'storeFullMatricesEveryEpoch') && ...
                        cfg.data.storeFullMatricesEveryEpoch
                    obj.storagePolicyMode_ = 'full';
                elseif isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'storage')
                    st = cfg.diagnostics.storage;
                    if isfield(st,'mode') && ischar(st.mode)
                        obj.storagePolicyMode_ = st.mode;
                    end
                end
            catch; end
        end

        function tf = shouldStoreFullSnapshot_(obj, t_s, ~)
            tf = strcmp(obj.storagePolicyMode_,'full');
            if ~tf && obj.snapshotEnable_
                isFirst  = (obj.snapshotCount_ == 0);
                elapsed  = t_s - obj.lastSnapshotTime_s_;
                underMax = (obj.snapshotCount_ < obj.snapshotMax_);
                tf = underMax && (isFirst || elapsed >= obj.snapshotInterval_s_);
                if tf
                    obj.snapshotCount_      = obj.snapshotCount_ + 1;
                    obj.lastSnapshotTime_s_ = t_s;
                end
            end
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

function nis = localNis_(innov, Rsub)
    nis = 0;
    if isempty(innov) || isempty(Rsub); return; end
    innov = innov(:);
    Rsub = (Rsub + Rsub') / 2;
    try
        if rcond(Rsub) > 1e-15
            nis = innov' * (Rsub \ innov);
        else
            nis = innov' * (pinv(Rsub) * innov);
        end
    catch
        rd = max(diag(Rsub), 1e-20);
        nis = sum(innov.^2 ./ rd);
    end
end
