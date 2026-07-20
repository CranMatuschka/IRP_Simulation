function [ok, report] = swarm_fingerprint_diff(a, b)
% swarm_fingerprint_diff  Exact element-wise comparison of two swarm digests.
%
% [ok, report] = swarm_fingerprint_diff(a, b) returns ok=true iff every field of the
% two digests (from swarm_fingerprint) is bit-identical. report is a struct of per-field
% max|Δ| for the numeric arrays. Used as the swarm bit-identity gate for Phase 3b.

    report = struct();
    ok = true;

    if a.nx ~= b.nx
        ok = false; report.nx = sprintf('%d vs %d', a.nx, b.nx);
        fprintf('  nx        %-14s DIFF\n', report.nx);
        return;   % shapes differ -> everything else meaningless
    end

    arrFields = {'finalX','finalPdiag','histX','histPdiag','histNIS','histPosErr', ...
                 'secFinalPos','secFinalVel','secFinalClock'};
    for k = 1:numel(arrFields)
        f = arrFields{k};
        va = getfield_(a, f); vb = getfield_(b, f);
        if ~isequal(size(va), size(vb))
            ok = false; report.(f) = sprintf('size %s vs %s', mat2str(size(va)), mat2str(size(vb)));
            fprintf('  %-11s %-20s DIFF\n', f, report.(f));
            continue;
        end
        d = 0;
        if ~isempty(va); d = max(abs(va(:) - vb(:))); end
        report.(f) = d;
        eq = (d == 0);
        ok = ok && eq;
        st = 'OK'; if ~eq; st = 'DIFF'; end
        fprintf('  %-11s max|d|=%.3e   %s\n', f, d, st);
    end

    scalarFields = {'traceP','normX','sumX'};
    for k = 1:numel(scalarFields)
        f = scalarFields{k};
        d = abs(a.(f) - b.(f));
        report.(f) = d;
        eq = (d == 0);
        ok = ok && eq;
        st = 'OK'; if ~eq; st = 'DIFF'; end
        fprintf('  %-11s |d|=%.3e   %s\n', f, d, st);
    end

    if ok
        fprintf('SWARM FINGERPRINT: BIT-IDENTICAL (traceP=%.10f)\n', b.traceP);
    else
        fprintf('SWARM FINGERPRINT: DIFFERS -- NOT byte-identical\n');
    end
end

function v = getfield_(s, f)
    v = [];
    if isfield(s, f); v = s.(f); end
end
