# Draft: Agent Model Defaults

## Requirements (confirmed)
- add default model configuration for Atlas, Hephaestus, Prometheus (Plan Builder), and Sisyphus (Ultraworker)
- make the highest-consumption Sisyphus use kimi k2.5
- use gpt5.4 for expert-level, lower-volume but higher-precision roles
- split subagents so half use mimov2 pro and half use kimi k2

## Technical Decisions
- Interpretation: this request targets repository-level agent/model configuration, not prompt or behavior changes unless the config structure requires co-locating them.
- Planning target: identify the real config source of truth before deciding file-level edits.
- Evidence-based decision: no committed runtime agent/model config exists yet in this repo; implementation will likely need to introduce a new source of truth rather than edit an existing one.
- User decision: plan for a new committed main configuration file as the source of truth.
- User decision: apply the subagent 50/50 requirement by role buckets, not exact numeric symmetry; odd counts may differ by one.

## Research Findings
- `.opencode/package.json` only installs OpenCode tooling; it does not define agents or models.
- `.opencode/.gitignore` indicates `.opencode` local setup may be intentionally untracked, so committed repo state currently has no machine-readable agent/model source of truth.
- `.opencode/node_modules/@opencode-ai/sdk/dist/v2/gen/types.gen.d.ts` shows the likely config schema: top-level `model`, `small_model`, `default_agent`, `agent`, `provider`, and per-command `agent`/`model`.
- Atlas / Hephaestus / Prometheus / Sisyphus appear only in this draft, not in committed runtime config.
- `gpt-5.4` and `kimi-k2.5` are clear model IDs; `Kimi K2` should be normalized to a concrete K2 variant; `mimov2 pro` likely needs normalization to `mimo-v2-pro`.
- Local `.opencode` authored files contain no reusable provider-prefixed model strings and no `default_agent` / `agent` / `provider` config; exact K2 and MiMo IDs cannot be inferred from current repo-local config.

## Open Questions
- Which concrete Kimi K2 variant is already used by local OpenCode config, if any?
- Whether a local JSON config already encodes the canonical provider/model strings for K2 and MiMo.

## Scope Boundaries
- INCLUDE: default model mapping for orchestrators and subagents
- EXCLUDE: changing agent responsibilities, prompts, or non-model routing unless required by the config schema
