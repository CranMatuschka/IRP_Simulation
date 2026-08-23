# `.claude/docs/` — prompts, not documentation

Documents in here are written **to an agent**, in the second person. They are inputs
that make Claude do something, not descriptions of how the simulation works.

The distinction is the whole reason this folder exists. `docs/` had accumulated both
kinds side by side, and they age in opposite directions: a design document is
still true when nobody is reading it, while a prompt that names a branch, a
starting commit or a repository layout goes stale the moment any of those move
and is then actively misleading.

| file | opens with |
|---|---|
| `CLAUDE_GNSS_MASTER_PROMPT.md` | "You are a GNSS scientist, Kalman-filter architect, and senior MATLAB OO developer..." |
| `TWSTFT_MULTI_ASSET_MASTER_PROMPT.md` | "You are a senior MATLAB scenario developer, GNSS scientist, time-transfer specialist..." |

## What belongs here

A file goes here if it addresses the reader as the thing doing the work. Roadmaps,
runbooks, plans and audits do NOT, even when they were written for an agent to
follow: `CLARITY_REFACTOR_EXECUTION.md` is a runbook, `PHASE_A_STATE_SPARSE_CORE.md`
states a goal, `plans/ISL_LAMBDA/00_OVERVIEW.md` is a planning document. All stayed
in `docs/`.

## Both files are stale as written

Neither has been updated since `oo_v1` became the repository root on 2026-08-23.
They instruct an agent to work inside `oo_v1/`, which no longer exists, and
`CLAUDE_GNSS_MASTER_PROMPT.md` opens by branching from `main` — which at the time
of writing is 200-odd commits behind. Read them as a record of how the work was
framed, and fix the paths before handing either to an agent again.
