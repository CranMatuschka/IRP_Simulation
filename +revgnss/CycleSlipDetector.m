classdef CycleSlipDetector
    % CycleSlipDetector  Pure stateless cycle-slip detection from residual history.
    %
    % Does NOT maintain state.  CarrierTrackManager owns per-track history.
    % All methods are Static so they are trivially testable.

    methods (Static)

        function [isSlip, slipMetric_m] = detectCompensated(observedJump_m, ...
                expectedModelJump_m, threshold_m, epochCount, minEpochsBeforeDetect)
            % detectCompensated  Model-step-compensated slip detection.
            %
            % Tests the residual jump AFTER removing the expected contribution from
            % known model/product correction changes.  Tower clock product epoch
            % boundary steps are deterministic and must not trigger ambiguity resets.
            %
            %   slipMetric = observedJump - expectedModelJump
            %   isSlip = |slipMetric| >= threshold  (after warmup)
            %
            % Inputs:
            %   observedJump_m       prefit_k - prefit_{k-1}  (signed, [m])
            %   expectedModelJump_m  towerClkModel_k - towerClkModel_{k-1} (signed, [m])
            %   threshold_m          slip threshold [m]
            %   epochCount           epochs tracked so far (including this one)
            %   minEpochsBeforeDetect  warmup epochs before detection active
            %
            % Outputs:
            %   isSlip        true if |slipMetric_m| >= threshold and epoch >= min
            %   slipMetric_m  compensated jump metric (signed; 0 before warmup)

            if epochCount < minEpochsBeforeDetect
                isSlip       = false;
                slipMetric_m = 0;
                return;
            end
            slipMetric_m = observedJump_m - expectedModelJump_m;
            isSlip       = abs(slipMetric_m) >= threshold_m;
        end

        function [isSlip, jumpMag_m] = detect(currentResidual_m, prevResidual_m, ...
                threshold_m, epochCount)
            % detect  Test a single carrier residual for a cycle slip.
            %
            % Inputs:
            %   currentResidual_m  Prefit residual (z - h) this epoch [m]
            %   prevResidual_m     Prefit residual previous epoch [m]
            %   threshold_m        Jump magnitude threshold [m] (e.g. 0.1 m)
            %   epochCount         Number of epochs this track has been tracked.
            %                      Detection is suppressed for epochCount <= 1
            %                      (no previous residual available).
            %
            % Outputs:
            %   isSlip     true if a slip is declared
            %   jumpMag_m  |currentResidual_m - prevResidual_m| (0 on first epoch)

            if epochCount <= 1
                isSlip    = false;
                jumpMag_m = 0;
                return
            end

            jumpMag_m = abs(currentResidual_m - prevResidual_m);
            isSlip    = jumpMag_m >= threshold_m;
        end

        function [isSlip, jumpMag_m] = detectWithMinEpochs(currentResidual_m, ...
                prevResidual_m, threshold_m, epochCount, minEpochsBeforeDetect)
            % detectWithMinEpochs  Like detect(), but suppresses until minEpochs.
            %
            % Allows a track to 'settle' before slip detection becomes active.

            if epochCount < minEpochsBeforeDetect
                isSlip    = false;
                jumpMag_m = 0;
                return
            end
            [isSlip, jumpMag_m] = revgnss.CycleSlipDetector.detect( ...
                currentResidual_m, prevResidual_m, threshold_m, epochCount);
        end

    end
end
