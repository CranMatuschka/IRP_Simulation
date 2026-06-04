%STARTUP Configure MATLAB paths for the IRP_Simulation project.

thisFile = mfilename('fullpath');

if isempty(thisFile)
    projectRoot = string(pwd);
else
    projectRoot = string(fileparts(thisFile));
end

addpath(char(projectRoot));
ProjectPathManager.addProjectPaths();

clear thisFile projectRoot;