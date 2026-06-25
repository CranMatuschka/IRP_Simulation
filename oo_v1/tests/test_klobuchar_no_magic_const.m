% test_klobuchar_no_magic_const  No magic constant 1.57 in Klobuchar source (T11).
%
% CHANGED: v3→v4 — Issue 15
% IS-GPS-200 uses 1.57 as approximation of pi/2 in Klobuchar.
% In code we prefer the symbolic pi/2 for clarity.
% This test greps all .m files for the bare magic constant 1.57 in
% conditional contexts (i.e. as a threshold value, not a coefficient).
%
% If Klobuchar is not implemented, the test passes trivially.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_klobuchar_no_magic_const (T11) ===\n');

ooDir = fullfile(thisDir, '..', '+revgnss');
mFiles = dir(fullfile(ooDir, '*.m'));

foundMagic = false;
for k = 1:numel(mFiles)
    fpath = fullfile(ooDir, mFiles(k).name);
    fid = fopen(fpath, 'r');
    li = 0;
    while true
        raw = fgetl(fid);
        if ~ischar(raw), break; end
        li = li + 1;
        ln = raw;
        % Match bare 1.57 as a comparison value (not part of e.g. 1.575 or 1.570)
        % Pattern: space/operator + 1.57 + space/operator/end
        if ~isempty(regexp(ln, '[<>~=]\s*1\.57\b|\b1\.57\s*[<>~=]', 'once'))
            % Skip if already in a comment explaining the ICD
            if ~isempty(strfind(ln, '%'))
                cmt = strfind(ln, '%');
                if cmt(1) < strfind(ln, '1.57')
                    continue  % it's in a comment — acceptable
                end
            end
            fprintf('  FOUND magic constant 1.57 in %s:%d: %s\n', ...
                mFiles(k).name, li, strtrim(ln));
            foundMagic = true;
        end
    end
    fclose(fid);
end

if foundMagic
    error('test_klobuchar_no_magic_const FAILED: magic constant 1.57 found (use pi/2 with ICD comment)');
else
    fprintf('  No bare magic constant 1.57 found in +revgnss/*.m\n');
    fprintf('  PASS\n');
end

fprintf('=== test_klobuchar_no_magic_const: PASS ===\n');
