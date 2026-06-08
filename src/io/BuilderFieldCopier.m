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

    end
end
