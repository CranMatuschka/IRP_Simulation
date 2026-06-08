classdef BuilderFieldCopier
    methods (Static)
        function out = copyNamedFields(out, src, names)
            for name = string(names(:)).'
                fieldName = char(name);
                if isstruct(src) && isfield(src, fieldName)
                    out.(fieldName) = src.(fieldName);
                end
            end
        end

        function names = atmosphereHistoryFieldNames()
            names = [
                "atmosphere_truth_delay_by_receiver_tower_m"
                "atmosphere_truth_troposphere_by_receiver_tower_m"
                "atmosphere_truth_ionosphere_by_receiver_tower_m"
                "atmosphere_truth_ionosphere_ipp_lat_deg_by_receiver_tower"
                "atmosphere_truth_ionosphere_ipp_lon_deg_by_receiver_tower"
                "atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower"
                "atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower"
                "atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower"
                "atmosphere_truth_ionosphere_frequency_Hz_by_receiver_tower"
                "atmosphere_truth_troposphere_pressure_hPa_by_receiver_tower"
                "atmosphere_truth_troposphere_temperature_K_by_receiver_tower"
                "atmosphere_truth_troposphere_relative_humidity_fraction_by_receiver_tower"
                "atmosphere_truth_troposphere_water_vapor_pressure_hPa_by_receiver_tower"
                "atmosphere_truth_troposphere_zhd_m_by_receiver_tower"
                "atmosphere_truth_troposphere_zwd_m_by_receiver_tower"
                "atmosphere_truth_troposphere_mapping_hydrostatic_by_receiver_tower"
                "atmosphere_truth_troposphere_mapping_wet_by_receiver_tower"
                "atmosphere_truth_troposphere_slant_hydrostatic_m_by_receiver_tower"
                "atmosphere_truth_troposphere_slant_wet_m_by_receiver_tower"
                "atmosphere_truth_troposphere_residual_by_tower_m"
                "atmosphere_truth_ionosphere_residual_by_tower_m"
                "atmosphere_truth_troposphere_total_by_receiver_tower_m"
                "atmosphere_truth_ionosphere_total_by_receiver_tower_m"
                "atmosphere_truth_residual_by_tower_m"
                "atmosphere_truth_total_by_receiver_tower_m"
                "atmosphere_model_delay_by_receiver_tower_m"
                "atmosphere_model_troposphere_by_receiver_tower_m"
                "atmosphere_model_ionosphere_by_receiver_tower_m"
                "atmosphere_model_ionosphere_ipp_lat_deg_by_receiver_tower"
                "atmosphere_model_ionosphere_ipp_lon_deg_by_receiver_tower"
                "atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower"
                "atmosphere_model_ionosphere_stec_TECU_by_receiver_tower"
                "atmosphere_model_ionosphere_mapping_factor_by_receiver_tower"
                "atmosphere_model_ionosphere_frequency_Hz_by_receiver_tower"
                "atmosphere_model_troposphere_pressure_hPa_by_receiver_tower"
                "atmosphere_model_troposphere_temperature_K_by_receiver_tower"
                "atmosphere_model_troposphere_relative_humidity_fraction_by_receiver_tower"
                "atmosphere_model_troposphere_water_vapor_pressure_hPa_by_receiver_tower"
                "atmosphere_model_troposphere_zhd_m_by_receiver_tower"
                "atmosphere_model_troposphere_zwd_m_by_receiver_tower"
                "atmosphere_model_troposphere_mapping_hydrostatic_by_receiver_tower"
                "atmosphere_model_troposphere_mapping_wet_by_receiver_tower"
                "atmosphere_model_troposphere_slant_hydrostatic_m_by_receiver_tower"
                "atmosphere_model_troposphere_slant_wet_m_by_receiver_tower"];
        end
    end
end
