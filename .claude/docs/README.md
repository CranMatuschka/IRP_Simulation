# `.claude/docs/` — prompts, not documentation

Documents in here are written **to an agent**: they assign a role, set scope, or
issue instructions in the imperative. They are inputs that make Claude do
something, not descriptions of how the simulation works.

The distinction matters because the two kinds age in opposite directions. A design
document is still true when nobody is reading it. A prompt that names a branch, a
starting commit or a repository layout goes stale the moment any of those move,
and then actively misleads whoever runs it next.

| file | what makes it a prompt |
|---|---|
| `CLAUDE_GNSS_MASTER_PROMPT.md` | "You are a GNSS scientist, Kalman-filter architect... Create a new branch from the latest main" |
| `TWSTFT_MULTI_ASSET_MASTER_PROMPT.md` | "You are a senior MATLAB scenario developer, GNSS scientist, time-transfer specialist..." |
| `TWSTFT_MULTI_ASSET_PHASE_PLAN.md` | "Do not jump directly to TWSTFT carrier... When implementing code, assign the next repository stage number" |
| `PHASE_A_STATE_SPARSE_CORE.md` | "Hard scope: Only edit files under oo_v1/. Do not implement PPP. Do not change the active scenario physics." |

The last two are instruction sets without a role line, which is why a search for
"You are a" alone does not find them. The test is not the second person, it is
whether the document tells the reader what to DO.

## What stayed in `docs/`, and why

Written FOR an agent to follow is not the same as written TO one.

- `CLARITY_REFACTOR_EXECUTION.md` — a runbook that records decisions with evidence
  ("Decisions that differ from the planning doc"), not instructions to issue.
- `handoff_phase_windup.md`, `handoff_joint_constrained_attitude.md` — these WERE
  prompt handlers and have since been overwritten with their outcomes: "STATUS:
  IMPLEMENTED AND MEASURED" and "The wiring task this document originally handed
  off is DONE. What follows is the record of what was built." Moving them would
  bury measured results in a prompt folder.
- `plans/`, the `scientific_correctness_review_v*` series, the audits and the
  design docs — findings and roadmaps. Their "Reviewer role:" lines describe the
  stance the analysis was written from, not a role being assigned to a reader.

## All four are STALE as written

None has been updated since `oo_v1` became the repository root on 2026-08-23. They
instruct an agent to work inside `oo_v1/`, which no longer exists;
`PHASE_A_STATE_SPARSE_CORE.md` says so explicitly ("Only edit files under
oo_v1/"), and `CLAUDE_GNSS_MASTER_PROMPT.md` opens by branching from `main`, which
at the time of writing is ~200 commits behind. Read them as a record of how the
work was framed, and fix the paths before handing any of them to an agent again.
