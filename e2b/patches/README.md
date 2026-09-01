# E2B upstream patches

## `e2b.pin` mirror

`e2b/e2b.pin` duplicates `versions.yml:e2b_pin` so the build container can read a plain SHA without parsing YAML. **`versions.yml` is authoritative**; `tests/bats/versions.bats` asserts `e2b.pin` stays in sync.

Patches in this directory are applied with `git apply` in CI against the pinned upstream checkout (`e2b/e2b.pin` / `versions.yml:e2b_pin`), in **lexical filename order**.

## Naming convention

`NNNN-short-description.patch` (e.g. `0001-force-stop-marker.patch`).

## Policy

- Keep patches **minimal** — every patch must be rebased when `e2b_pin` bumps.
- Add patches only when upstream behaviour must change; the force-stop marker
  patch is required because upstream parses `FORCE_STOP` only at process start.
- Do not fork `e2b-dev/infra`; all source changes go here.

## Applied patches

### `0001-force-stop-marker.patch`

Upstream parses `FORCE_STOP` once at process start (`packages/orchestrator/pkg/cfg/model.go`). Shutdown uses the in-memory `config.ForceStop`. Writing the EnvironmentFile then `systemctl stop` does **not** change the running process.

This patch, at shutdown-signal receipt, treats marker file `/orchestrator/force-stop` as `ForceStop=true` (override the startup-parsed value). The env var still applies to processes started with it already set.

**Interface:** empty file, mode `0600`, root-owned, path `/orchestrator/force-stop`. `upgrade.yml` creates it before `systemctl stop` and removes it after a successful stop (or on the subsequent start) so a later ordinary stop still drains.

Live observation of a running orchestrator honoring the marker is **unverified**. The patch is required to `git apply` cleanly against the pinned commit; a stub test covers the decision table without compiling E2B.

## Later patch candidate

Upstream `packages/shared/pkg/featureflags/flags.go` defines:

```go
MaxSandboxesPerNode = NewIntFlag("max-sandboxes-per-node", 200)
MaxStartingInstancesPerNode = NewIntFlag("max-starting-instances-per-node", 3)
```

These are LaunchDarkly int flags with compile-time fallbacks. Upstream provides `OverrideBoolFlag` and `OverrideJSONFlag`, but **there is no `OverrideIntFlag`**, so making these limits environment-overridable requires adding an int override path in upstream code — not merely reading an env var in Ansible.

A later task may land this patch if Phase 0 shows `max-starting-instances-per-node=3` throttles burst reviews.
