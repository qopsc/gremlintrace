# E2B upstream patches

## `e2b.pin` mirror

`e2b/e2b.pin` duplicates `versions.yml:e2b_pin` so the build container can read a plain SHA without parsing YAML. **`versions.yml` is authoritative**; `tests/bats/versions.bats` asserts `e2b.pin` stays in sync.

Patches in this directory are applied with `git apply` in CI against the pinned upstream checkout (`e2b/e2b.pin` / `versions.yml:e2b_pin`), in **lexical filename order**.

## Naming convention

`NNNN-short-description.patch` (e.g. `0001-env-override-max-sandboxes.patch`).

## Policy

- Keep patches **minimal** — every patch must be rebased when `e2b_pin` bumps.
- Add patches only when upstream behaviour must change; the force-stop marker
  patch is required because upstream parses `FORCE_STOP` only at process start.
- Do not fork `e2b-dev/infra`; all source changes go here.

## Future patch candidate

Upstream `packages/shared/pkg/featureflags/flags.go` defines:

```go
MaxSandboxesPerNode = NewIntFlag("max-sandboxes-per-node", 200)
MaxStartingInstancesPerNode = NewIntFlag("max-starting-instances-per-node", 3)
```

These are LaunchDarkly int flags with compile-time fallbacks. Upstream provides `OverrideBoolFlag` and `OverrideJSONFlag`, but **there is no `OverrideIntFlag`**, so making these limits environment-overridable requires adding an int override path in upstream code — not merely reading an env var in Ansible.

A later task may land this patch if Phase 0 shows `max-starting-instances-per-node=3` throttles burst reviews.
