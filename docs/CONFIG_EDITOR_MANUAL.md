# Scenario Configuration Editor

> Building a run without reading all 1362 leaves of `masterConfig`.
> **Individual Research Project, Cranfield University** · MATLAB R2025b

| | |
|---|---|
| **Tool** | `tools/config_editor/` |
| **Generator** | `buildConfigEditor.m` writes `config_editor.html` |
| **Checker** | `checkPersonalConfig.m`, run in MATLAB before the scenario runs |
| **Staleness gate** | `tests/test_config_editor_schema.m` |
| **Output** | a scenario delta JSON, saved into `config/personal/` |

---

## Contents

| Section | What it covers |
|---|---|
| [1. What it is](#1-what-it-is) | the problem the tool solves |
| [2. Quick start](#2-quick-start) | four commands, start to finished run |
| [3. The page](#3-the-page) | every control in the sidebar and the main panel |
| [4. Reading a knob row](#4-reading-a-knob-row) | tags, prose, controls, base values |
| [5. The warnings](#5-the-warnings) | derived, removed, conditional, pair member |
| [6. Master toggles](#6-master-toggles) | the twelve effects, and the mistake they prevent |
| [7. What gets written](#7-what-gets-written) | the shape of the delta file |
| [8. What the editor cannot know](#8-what-the-editor-cannot-know) | why `checkPersonalConfig` is not optional |
| [9. Keeping it current](#9-keeping-it-current) | regeneration and the test that enforces it |
| [10. Troubleshooting](#10-troubleshooting) | symptoms and fixes |

---

## 1. What it is

`config/masterConfig.m` carries **1362 configuration leaves**. That is not a list anyone can
work through, and a scenario JSON written by hand against it fails in three ways that all look
like success.

| Failure | What happens |
|---|---|
| A typo in a path | `deepMergeConfig` rejects it, so this one is caught loudly |
| A knob that resolution derives | The file merges cleanly, the run completes, and the report prints a setting the run never used |
| Half of a truth and model pair | The master toggle stops driving the effect, so switching it off switches nothing off |

The config editor is a single self-contained HTML page that knows which leaves are live, which
are derived, which have a checked set of legal values, and which of them any shipped scenario
has ever set. It writes a **delta**, not a whole configuration, exactly like the shipped ladder
rungs. Open it by double-clicking. It needs no server, no network and no MATLAB session.

The page is generated rather than hand-written, because everything it displays is already owned
somewhere in the code base and duplicating any of it would create a second version to keep true.

| Source | What the editor takes from it |
|---|---|
| `masterConfig()` | the leaf inventory, the defaults and the types |
| `config/masterConfig.m` source text | the section headers and the prose shown against each knob |
| `configEnumRegistry(cfg)` | the checked legal value set for the dangerous string knobs |
| `derivedConfigPathRegistry()` | the paths a scenario must not write, with the reason for each |
| `scenarioFileIndex()` | the 177 base scenarios, and the evidence behind the detail levels |

---

## 2. Quick start

Generate the page. Do this once, and again after anyone edits `masterConfig`.

```bash
matlab -batch "addpath('tools/config_editor'); buildConfigEditor"
```

It reports what it wrote.

```
Config editor written: tools/config_editor/config_editor.html
  1362 knobs, 177 base scenarios, 679 kB
  essentials 70 | standard 379 | everything 1362
  masterConfig sha256 3f8d84d30cc19fea
```

Open `tools/config_editor/config_editor.html` by double-clicking it. Pick a base scenario, name
your run, change what you care about, then press **Save JSON** and put the file in
`config/personal/`.

Back in MATLAB, check it before you trust it, then run it.

```matlab
checkPersonalConfig('myRun.json')
run_oo_v1('myRun.json', 3600)
```

The arc length is `run_oo_v1`'s second argument, never a key in the file, so one scenario sweeps
over durations without being edited.

---

## 3. The page

The layout is a sticky sidebar of run-wide choices on the left and the knob accordion on the
right, with a collapsible file preview along the bottom.

### Base scenario

The `_extends` parent your delta sits on. The dropdown groups the 177 shipped scenarios by
folder, and opens on `golden_baseline.json`, which is the defensible reference and the parent of
154 of the 172 ladder rungs. A one-line summary of the selected base appears underneath.

Changing the base does not discard your edits. It re-evaluates them, because "changed" means
different from the base, so a knob whose value the new base already holds silently drops out of
the delta and stops being listed as a change.

### Scenario name

Writes `scenario.name` and `report.runVersion`, and gives the saved file its name. Characters
outside `A-Z a-z 0-9 . _ -` are replaced with an underscore when the file is written.

### Detail level

Three tiers, and the split between them is **measured rather than chosen**. The 172 shipped
scenarios write only about 390 distinct leaves between them, and a small core appears in most.
That distribution is this project's own accumulated answer to which knobs matter.

| Level | Knobs shown | Rule |
|---|---:|---|
| **Essentials** | 70 | written by at least 8 shipped scenarios, plus every master effect toggle |
| **Standard** | 379 | written by at least one shipped scenario |
| **Everything** | 1362 | present in `masterConfig` at all |

A knob you have changed stays visible whatever the level, so an edit never disappears behind a
tier boundary and turns into a line of the delta that nobody remembers writing.

### Search

Matches the path, the knob's own comment, the block prose above it and its `masterConfig`
section header. Searching forces every group open, so hits are never left behind a collapsed
header. Useful queries are the physical ones such as `multipath`, `scintillation`, `sigma`,
`elevation` or `tower`.

### Show only what I changed

Reduces the accordion to your own delta. This is the review pass to make before saving.

### The tally, the buttons and the stamp

| Control | What it does |
|---|---|
| **Tally** | how many knobs are changed, and how many of the 1362 are currently shown |
| **Save JSON** | writes the delta. Modern browsers open a save dialogue, others download it |
| **Copy JSON** | puts the delta on the clipboard. If the clipboard is unreachable it opens the preview instead |
| **Open an existing JSON** | loads a scenario back in for further editing |
| **Discard all changes** | clears the delta after a confirmation, keeping the base and the name |
| **Stamp** | the `masterConfig` hash the page was generated from, the knob and base counts, and the MATLAB release |

The stamp is the one to read when a page has been sitting in a branch or was handed over by
someone else, because a stale editor is otherwise indistinguishable from a current one.

Loading a file that names paths the current `masterConfig` no longer has drops those paths and
says which they were. That means either the file predates a rename or the page needs
regenerating.

### File preview

The drawer along the bottom shows the exact JSON that **Save** will write, updating as you edit.

---

## 4. Reading a knob row

Each row puts the identity and the documentation on the left, and the control on the right.

**On the left**, in order, sit the dotted path, a row of tags, the count of shipped scenarios
that set this knob, and the knob's own prose lifted from `masterConfig`. A knob no shipped
scenario has ever set says so, which is a useful warning in itself.

| Tag | Meaning |
|---|---|
| `changed` | your delta owns this leaf |
| `derived` | resolution always overwrites it, so the control is disabled |
| `removed` | the knob was deleted and setting it now raises |
| `conditional` | resolution overwrites it under stated conditions only |
| `master toggle` | one switch for a whole effect, covered in [§6](#6-master-toggles) |
| section name | the `masterConfig` section header the leaf lives under |

**On the right** sits a control chosen by type, with the inherited value printed underneath it
as either `masterConfig default` or `from <the base file that declares it>`.

| Type | Control | Notes |
|---|---|---|
| Boolean | checkbox | the label tracks it, showing `true` or `false` |
| Enum | closed dropdown | the values come from `configEnumRegistry`, which `validateMasterConfig` enforces |
| String with suggestions | dropdown plus `other...` | the list was parsed from a code comment, so it is offered as a suggestion and free text stays available |
| Number | text box | a non-numeric entry is refused and the previous value restored. Emptying the box resets to base |
| Array | JSON text box | typed as JSON, for example `[1, 2, 3]` or `[[1,0],[0,1]]`, because that is checkable where a bare comma list is not |
| Structure | none | a value the editor cannot represent. Write it into the JSON by hand if you need it |

The two grades of dropdown are kept apart deliberately. A registry-backed set is **checked**, so
the editor can close the list. A list merely parsed out of prose is not checked, and the prose is
sometimes an illustration rather than the full set, so presenting it as closed would make the
editor refuse legal values on nothing better than a comment's authority.

A changed row gains a **reset to base** button. Setting a knob back to the value the base already
holds removes it from the delta on its own, so the file never carries a line that changes nothing.

---

## 5. The warnings

Three of the four warnings come from `derivedConfigPathRegistry`, which records the paths whose
value does not survive resolution. Each entry names the derivation site, so the claim can be
rechecked when that code moves, and each offers the path to write instead where one exists.

| Severity | Shown as | What it means | Control |
|---|---|---|---|
| `blocked` | `derived` | `finalizeConfig` always overwrites this leaf. A scenario value is guaranteed dead | disabled |
| `error` | `removed` | the knob no longer exists and setting it raises | disabled |
| `warn` | `conditional` | the overwrite happens under stated conditions only | live |

`simulation.duration_s` is the clearest case. `run_oo_v1` injects the arc length as a caller
override after the JSON has merged, and caller overrides are the most specific layer of all, so a
scenario value is always beaten. The registry says so and points at the second argument instead.

The fourth warning is the truth and model pair member, which has its own section.

---

## 6. Master toggles

Twelve effects carry a single `.enable` that the resolver expands into an internal truth and
model pair. For these twelve, and only these, a scenario writes the **master alone**.

| Group | Master enables |
|---|---|
| Physics | `physics.sagnac`, `physics.lightTime`, `physics.doppler` |
| Relativity | `physics.relativity.shapiro`, `physics.relativity.clock` |
| Propagation errors | `errors.troposphere`, `errors.ionosphere`, `errors.hardwareDelay`, `errors.multipath` |
| Geometric effects | `effects.towerSurvey`, `effects.antennaPCO`, `effects.antennaPCV` |

Writing a pair member such as `errors.multipath.truth.enable` makes your file **own** that
member, which suppresses the master expansion and stops `errors.multipath.enable` from driving
it. The editor flags every pair member with exactly this warning, because six shipped ladder
rungs once disabled nothing at all this way. The run completed, the report printed the effect as
off, and the effect was on.

Set the master unless you deliberately want an asymmetric pair, where the truth side carries an
effect the model side does not. That asymmetry is a legitimate experiment and several golden
settings use it, but it should be a decision rather than an accident.

---

## 7. What gets written

A delta and nothing else. Every knob you did not touch is inherited through `_extends`, so the
file shows exactly what it changes and a later edit to the base propagates into it.

```json
{
  "_id": "personal scenario \"myRun\", built on golden_baseline.json with the config editor.",
  "_extends": "golden_baseline.json",
  "scenario": {
    "name": "myRun"
  },
  "report": {
    "runVersion": "myRun"
  },
  "estimator": {
    "elevationMask_rad": 0.2618
  },
  "errors": {
    "multipath": {
      "enable": false
    }
  }
}
```

`scenario.name` and `report.runVersion` are always emitted, because they label the output folder
and the report. Anything you set explicitly wins over them.

Files in `config/personal/` are found by bare name, exactly like a ladder rung, and immediate
subfolders work too. The folder is untracked scratch space, so nothing in it is in the gate set
and an unfinished file there cannot fail the shared suite. The other side of that is traceability.
A run from `config/personal/` quoted in a result has no reproducible configuration behind it, so
promote its JSON into `config/ladder/<axis>/` and commit it before the number is used.

---

## 8. What the editor cannot know

The page knows the base file's own keys. It does not know what `finalizeConfig` derives at
resolve time, and it has no MATLAB in the loop, so it cannot tell you what a knob actually
resolves to. `checkPersonalConfig` answers the three questions that need the real resolver.

```matlab
checkPersonalConfig('myRun.json')          % at the default 3600 s arc
checkPersonalConfig('myRun.json', 7200)    % at the arc you will actually run
report = checkPersonalConfig('myRun.json') % the same findings as a struct
```

1. **Does the file resolve at all.** `validateMasterConfig` rejects an unknown path and an
   illegal mode string. Both are reported verbatim, and a genuine resolution failure is rethrown,
   because there is nothing to inspect after one.
2. **Did every leaf you set survive resolution.** This is the one that matters. A knob that is
   derived elsewhere, or that a profile overwrites after the merge, accepts your value at merge
   time and discards it before the run. Nothing errors, the run completes, and the report prints
   the setting as active.
3. **Did you write anything the derived registry warns about**, or half of a truth and model pair.

The survival check is not invented for this tool. `resolveSimulationConfig` returns the
pre-finalisation config together with the list of leaves the file explicitly wrote, and comparing
the two sides at exactly those leaves shows what resolution changed underneath you. It is the
same check `tests/test_scenario_override_invariance` runs across the whole shipped ladder, applied
to one file and printed for a person rather than asserted.

Findings are scoped to the leaves **your own file** wrote, not the whole `_extends` chain.
Reporting the base's decisions as though they were yours listed five of the golden baseline's
deliberate asymmetric pairs as suspicious, and nobody reads a warning list that is mostly about a
file they did not touch.

The checker prints and returns. It does not throw on a dead leaf, because a dead leaf is
sometimes what you meant.

---

## 9. Keeping it current

`config_editor.html` carries a snapshot of the whole config surface and is committed, so that
someone can open it without running MATLAB first. That is exactly what lets it rot. A stale
editor offers knobs that have been renamed or removed, and presents its defaults with the same
confidence whether or not they are still true.

Regenerate after any `masterConfig` edit.

```bash
matlab -batch "addpath('tools/config_editor'); buildConfigEditor"
```

`tests/test_config_editor_schema.m` is the gate, and it checks six things.

1. The schema builds at all.
2. Every path the editor offers is a real leaf of `masterConfig`.
3. Its enum sets match `configEnumRegistry` value for value.
4. Every derived-registry path still exists, except the ones recorded as removed, which must not.
5. Its list of master enables matches the list `masterConfig` hands `expandEnableToggles`, so a
   thirteenth effect cannot be added without the editor learning about it.
6. The committed HTML was generated from the `masterConfig` now in the tree.

Check 6 compares the stamped hash rather than diffing the page, because a byte diff would also
fail on an unrelated `jsonencode` ordering change and would teach everyone to regenerate and
commit to silence it, which is how a gate stops meaning anything.

### Why the schema is inlined

A page opened over `file://` cannot fetch a sibling JSON, because Chrome treats every `file://`
document as an opaque origin. The natural split of page plus data would produce an editor that
works from a web server and shows an empty list when double-clicked, which is the only way anyone
is going to open it. So the schema is inlined into the page, which is what makes it 679 kB and
what makes it work.

To change the interface, edit `template.html` and regenerate. Never edit `config_editor.html`,
which is a build artefact.

---

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `test_config_editor_schema` fails on staleness | The page predates a `masterConfig` edit. Re-run `buildConfigEditor` |
| A knob is greyed out | It is derived or removed. The advice line names the path to write instead |
| Loading a file drops paths | The file predates a rename, or the page needs regenerating |
| `checkPersonalConfig` names a dead leaf | Resolution overwrote it. Set the upstream knob the registry names, or accept it if the dead leaf was intended |
| `checkPersonalConfig` reports it does not resolve | An unknown path is usually a typo or a renamed key. An `unknownModeValue` is a mode string no dispatch site recognises |
| The run ignores your duration | Duration is `run_oo_v1`'s second argument. A scenario value is always beaten |
| An effect stays on after you disabled it | You wrote a pair member instead of the master. See [§6](#6-master-toggles) |
| Your scenario is not found | It must sit in `config/personal/` or one of its immediate subfolders, and be referenced by bare name |

---

## See also

| Document | What it covers |
|---|---|
| [`README.md`](../README.md) | the repository overview, the run knobs and the scenario ladder |
| [`docs/VALIDATION_MANUAL.md`](VALIDATION_MANUAL.md) | the term-by-term scientific audit of every effect the knobs switch |
| [`docs/golden_baseline_provenance.md`](golden_baseline_provenance.md) | a citation for every numeric value in the default base scenario |
| [`config/personal/README.md`](../config/personal/README.md) | the scratch folder the editor writes into |
