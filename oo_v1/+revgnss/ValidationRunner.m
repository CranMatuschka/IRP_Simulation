classdef ValidationRunner
    % ValidationRunner  Targeted random smoke-test selection and execution.
    %
    % Stage 24 runs 2-5 randomly selected tests, not the full test suite.
    % Selection is deterministic for a given seed.  Default seed = 24.
    %
    % Environment overrides:
    %   OO_V1_RANDOM_TEST_SEED   — integer seed (default 24)
    %   OO_V1_RANDOM_TEST_COUNT  — count clamped to [2, 5] (default 4)
    %
    % Usage:
    %   files   = revgnss.ValidationRunner.selectTests(testDir);
    %   results = revgnss.ValidationRunner.runSelected(files, rootDir);

    methods (Static)

        function seed = defaultSeed()
            % defaultSeed  Return seed from env var or default (24).
            seed = 24;
            v = getenv('OO_V1_RANDOM_TEST_SEED');
            if ~isempty(v)
                n = str2double(v);
                if ~isnan(n) && isfinite(n); seed = round(n); end
            end
        end

        function n = defaultCount()
            % defaultCount  Return test count from env var or default (4).
            n = 4;
            v = getenv('OO_V1_RANDOM_TEST_COUNT');
            if ~isempty(v)
                x = str2double(v);
                if ~isnan(x) && isfinite(x); n = max(2, min(5, round(x))); end
            end
        end

        function files = selectTests(testDir, seed, count)
            % selectTests  Deterministically select test_*.m files.
            %   Returns a cell array of filenames (with .m extension).
            if nargin < 2 || isempty(seed);  seed  = revgnss.ValidationRunner.defaultSeed(); end
            if nargin < 3 || isempty(count); count = revgnss.ValidationRunner.defaultCount(); end

            tmp = dir(fullfile(testDir, 'test_*.m'));
            if isempty(tmp)
                files = {};
                warning('ValidationRunner:noTests', 'No test_*.m found in %s', testDir);
                return
            end
            allFiles = sort({tmp.name});
            n = min(count, numel(allFiles));
            s = RandStream('mt19937ar', 'Seed', seed);
            perm = randperm(s, numel(allFiles));
            idx  = sort(perm(1:n));
            files = allFiles(idx);
        end

        function results = runSelected(files, rootDir)
            % runSelected  Run each test file; return struct array with pass/fail.
            %   Each test script is evaluated in the base workspace via evalin
            %   so the test's variable assignments cannot corrupt this function.
            if nargin < 2; rootDir = '.'; end
            addpath(rootDir);
            addpath(fullfile(rootDir, 'tests'));
            results = struct('name', {}, 'passed', {}, 'message', {});
            for k = 1:numel(files)
                fname = files{k};
                if numel(fname) > 2 && strcmp(fname(end-1:end), '.m')
                    name = fname(1:end-2);
                else
                    name = fname;
                end
                [ok, msg] = revgnss.ValidationRunner.runOne_(name);
                results(end+1).name    = name; %#ok<AGROW>
                results(end).passed    = ok;
                results(end).message   = msg;
            end
        end

        function [nPass, nTotal] = countResults(results)
            % countResults  Count passing/total from runSelected output.
            nTotal = numel(results);
            nPass  = sum([results.passed]);
        end

        function printSummary(results)
            % printSummary  Print pass/fail table to console.
            fprintf('\n--- Selected test results ---\n');
            for k = 1:numel(results)
                if results(k).passed
                    fprintf('  PASS  %s\n', results(k).name);
                else
                    fprintf('  FAIL  %s\n    %s\n', results(k).name, results(k).message);
                end
            end
            [np, nt] = revgnss.ValidationRunner.countResults(results);
            fprintf('--- %d / %d passed ---\n\n', np, nt);
        end

    end

    methods (Static, Access = private)

        function [ok, msg] = runOne_(name)
            ok = true; msg = '';
            try
                evalin('base', name);
            catch e
                ok = false;
                msg = e.message;
                if numel(msg) > 300; msg = msg(1:300); end
            end
        end

    end
end
