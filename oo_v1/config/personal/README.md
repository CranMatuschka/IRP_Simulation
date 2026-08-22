# `config/personal/` — your own scenarios

Scenario overlays you build for yourself. Everything here except this README is
**untracked**: it is a scratch space, one per person, not a shared source folder.

## Making one

```bash
matlab -batch "addpath('tools/config_editor'); buildConfigEditor"
```

That writes `tools/config_editor/config_editor.html`. Open it by double-clicking — it
needs no server and no network. Pick a base scenario, change what you care about, save the
result here.

Re-run `buildConfigEditor` after anyone edits `config/masterConfig.m`. The editor carries a
snapshot of the config surface, and `tests/test_config_editor_schema.m` fails when that
snapshot and the working tree have parted.

## Running one

Files here are found by bare name, exactly like a ladder rung:

```matlab
checkPersonalConfig('myRun.json')     % do this first
run_oo_v1('myRun.json', 3600)
```

`checkPersonalConfig` is not a formality. The editor knows the base file's own keys, but
the realism grade and the atmosphere profile derive further values at resolve time, and
several knobs are overwritten by `finalizeConfig` no matter what a scenario asks for. The
checker resolves the file for real and names every leaf you set that did not survive. A
scenario that silently loses a setting still runs, still finishes, and still reports the
setting as active, which is the failure this whole folder is built to avoid.

The arc length is an argument to `run_oo_v1`, not a key in the file. One scenario can be
swept over durations without being edited.

## Subfolders are fine

`config/personal/attitude/myRun.json` is found by bare name too. `scenarioFileIndex` adds
this folder and its immediate subfolders to the lookup path.

## What this folder is not

It is not in the gate set. `test_scenario_override_invariance` and
`test_config_mode_enum_validation` iterate the tracked scenarios only, so an unfinished
file here cannot fail the shared suite.

It is also not traceable. If a run from this folder is ever quoted in a result, promote
its JSON into `config/ladder/<axis>/` and commit it, or the number has no reproducible
configuration behind it.
