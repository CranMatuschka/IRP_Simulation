classdef StochasticProcess
    % StochasticProcess  Discrete-time stochastic process stepping utilities.
    %
    % All methods take an explicit RandStream so that no bare randn is used.
    %
    % Methods:
    %   gaussMarkovStep      First-order Gauss-Markov process (exponential autocorrelation)
    %   randomWalkStep       Random walk (integrated white noise)
    %   white                Vector of white Gaussian noise samples

    methods (Static)

        function xNew = gaussMarkovStep(x, dt, tau_s, sigma_ss, stream)
            % gaussMarkovStep  Step a first-order Gauss-Markov process.
            %
            % Inputs:
            %   x          scalar or vector  current state
            %   dt         scalar            time step [s]
            %   tau_s      scalar            correlation time [s]  (>0)
            %   sigma_ss   scalar            steady-state standard deviation
            %   stream     RandStream        random number source
            %
            % Returns:
            %   xNew       same size as x    updated state
            %
            % Model:
            %   phi  = exp(-dt / tau_s)
            %   q    = sigma_ss^2 * (1 - phi^2)   (process noise variance)
            %   xNew = phi * x + sqrt(q) * randn(stream)
            %
            % Limiting cases:
            %   tau_s → 0   : white noise (q → sigma_ss^2)
            %   tau_s → Inf : random walk (phi → 1, q → 2*sigma_ss^2*dt/tau_s)

            if tau_s <= 0
                error('StochasticProcess:invalidTau', 'tau_s must be > 0');
            end
            phi  = exp(-dt / tau_s);
            q    = sigma_ss^2 * (1 - phi^2);
            sz   = size(x);
            xNew = phi * x + sqrt(max(q, 0)) * randn(stream, sz(1), sz(2));
        end

        function xNew = randomWalkStep(x, dt, sigma_per_sqrt_s, stream)
            % randomWalkStep  Step a random walk process.
            %
            % Inputs:
            %   x                  scalar or vector  current state
            %   dt                 scalar            time step [s]
            %   sigma_per_sqrt_s   scalar            diffusion coefficient [units/sqrt(s)]
            %   stream             RandStream        random number source
            %
            % Returns:
            %   xNew   same size as x
            %
            % Model:
            %   xNew = x + sigma_per_sqrt_s * sqrt(dt) * randn(stream)

            sz   = size(x);
            xNew = x + sigma_per_sqrt_s * sqrt(dt) * randn(stream, sz(1), sz(2));
        end

        function v = white(sigma, n, stream)
            % white  Draw n-element vector of white Gaussian noise.
            %
            % Inputs:
            %   sigma   scalar    standard deviation
            %   n       scalar    number of samples
            %   stream  RandStream random number source
            %
            % Returns:
            %   v   [n x 1]   noise vector

            v = sigma * randn(stream, n, 1);
        end

    end
end
