classdef De440Ephemeris
    % De440Ephemeris  JPL DE-440 Sun/Moon geocentric positions in EME2000.
    %
    % Prototype backend for the gated 'de440' truth ephemeris source (see
    % models.orbit.OrbitPerturbations and cfg.perturbations.sunMoon.ephemeris). It
    % answers a single quantified question from the Orekit cross-validation: the
    % Montenbruck & Gill analytic Sun/Moon leaves a ~0.6 m / 4 h luni-solar truth-
    % fidelity gap vs DE-440; swapping to DE-440 recovers it.
    %
    % Implementation: this backend reads DE-440 through the Orekit bridge (the jars +
    % orekit-data already installed at ~/orekit-bridge). It lazily loads the bridge on
    % first use and caches the Sun/Moon CelestialBody, the EME2000 frame and the J2000
    % epoch in PERSISTENT storage, so the per-call cost is a single Java getPosition.
    %
    % Requirements: a JVM (run via `matlab -batch` or the desktop -- NOT the -nojvm MCP
    % session) and the bridge installed. Missing either raises a clear error; callers
    % that want the default analytic path simply leave cfg...ephemeris = 'mg'.
    %
    % Frame/epoch: jd_tt is a Julian date on the TT scale; jd_tt = 2451545.0 is J2000.0
    % (AbsoluteDate.J2000_EPOCH). Positions are geocentric (Earth -> body) in EME2000,
    % matching OrbitPerturbations.sunPositionEci/moonPositionEci (M&G J2000 mean equator).
    %
    % A future native backend (a Chebyshev table precomputed over the run span) would
    % implement the same two methods and drop the runtime Java dependency.

    methods (Static)
        function r = sunEci(jd_tt)
            % sunEci  Geocentric Sun position [m], EME2000, at Julian date jd_tt (TT).
            r = models.orbit.De440Ephemeris.position_('sun', jd_tt);
        end

        function r = moonEci(jd_tt)
            % moonEci  Geocentric Moon position [m], EME2000, at Julian date jd_tt (TT).
            r = models.orbit.De440Ephemeris.position_('moon', jd_tt);
        end
    end

    methods (Static, Access = private)
        function r = position_(body, jd_tt)
            [sun, moon, frame, j2000] = models.orbit.De440Ephemeris.bridge_();
            date = j2000.shiftedBy((jd_tt - 2451545.0) * 86400);
            if strcmp(body, 'sun'); b = sun; else; b = moon; end
            p = b.getPosition(date, frame);
            r = [p.getX(); p.getY(); p.getZ()];
        end

        function [sun, moon, frame, j2000] = bridge_()
            % bridge_  Lazily load the Orekit bridge once and cache the Sun/Moon bodies,
            % the EME2000 frame and the J2000 epoch. Idempotent across calls (persistent)
            % and cooperative with a caller that has already loaded the jars / data.
            persistent SUN MOON FRAME J2000
            if ~isempty(SUN); sun = SUN; moon = MOON; frame = FRAME; j2000 = J2000; return; end

            if ~usejava('jvm')
                error('De440Ephemeris:noJvm', ...
                    ['DE-440 ephemeris needs a JVM: run via `matlab -batch` or the desktop, ' ...
                     'not the -nojvm session. Leave cfg...ephemeris = ''mg'' for the analytic path.']);
            end
            libDir  = fullfile(getenv('HOME'), 'orekit-bridge', 'lib');
            dataDir = fullfile(getenv('HOME'), 'orekit-bridge', 'data', 'orekit-data-main');
            if ~isfolder(libDir) || isempty(dir(fullfile(libDir, '*.jar'))) || ~isfolder(dataDir)
                error('De440Ephemeris:noBridge', ...
                    ['Orekit bridge not installed. Expected jars in %s and orekit-data in %s. ' ...
                     'Leave cfg...ephemeris = ''mg'' for the analytic path.'], libDir, dataDir);
            end

            jars   = dir(fullfile(libDir, '*.jar'));
            onPath = javaclasspath('-dynamic');
            for k = 1:numel(jars)
                jp = fullfile(libDir, jars(k).name);
                if ~any(strcmp(onPath, jp)); javaaddpath(jp); end
            end
            dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
            if dpm.getProviders().isEmpty()      % don't double-register if a caller already did
                dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));
            end

            SUN   = org.orekit.bodies.CelestialBodyFactory.getSun();
            MOON  = org.orekit.bodies.CelestialBodyFactory.getMoon();
            FRAME = org.orekit.frames.FramesFactory.getEME2000();
            J2000 = org.orekit.time.AbsoluteDate.J2000_EPOCH;
            sun = SUN; moon = MOON; frame = FRAME; j2000 = J2000;
        end
    end
end
