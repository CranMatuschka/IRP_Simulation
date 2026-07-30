function comparison = compareDefaultAndRealismConfigurations()
%COMPAREDEFAULTANDREALISMCONFIGURATIONS List resolved profile differences.

    [defaultConfig, defaultMetadata] = resolveSimulationConfig('default.json');
    [realismConfig, realismMetadata] = resolveSimulationConfig('realism.json');
    rawDifference = revgnss.ConfigTextDump.diff(defaultConfig, realismConfig);
    declaredDifference = revgnss.ConfigTextDump.diff( ...
        defaultMetadata.preResolutionConfig, ...
        realismMetadata.preResolutionConfig);

    comparison = struct();
    comparison.defaultSource = defaultMetadata.sourcePath;
    comparison.realismSource = realismMetadata.sourcePath;
    comparison.changed = cell2table(rawDifference.changed, ...
        'VariableNames', {'Path','DefaultValue','RealismValue'});
    comparison.addedByRealism = cell2table(rawDifference.added, ...
        'VariableNames', {'Path','RealismValue'});
    comparison.addedBeforeDerivation = cell2table(declaredDifference.added, ...
        'VariableNames', {'Path','RealismValue'});

    if nargout == 0
        fprintf('Resolved default-to-realism changes: %d\n', ...
            height(comparison.changed));
        disp(comparison.changed);
        if ~isempty(comparison.addedByRealism)
            fprintf('Derived fields present only after realism resolution: %d\n', ...
                height(comparison.addedByRealism));
            disp(comparison.addedByRealism);
        end
        clear comparison
    end
end
