# preflight

Hard-fail host validation before install. Always writes `/etc/qops/preflight.json` (even on failure) and exits non-zero when any check fails.

## Preflight JSON schema (`/etc/qops/preflight.json`)

| Field | Type | Description |
|---|---|---|
| `version` | integer | Schema version (`preflight_schema_version`, currently `1`). |
| `timestamp` | string | UTC ISO-8601 time the report was written. |
| `passed` | boolean | `true` only when every check passed. |
| `checks` | array | One object per check (see below). |
| `failures` | array of strings | Copy of each failed check's `message` (all failures at once). |

Each element of `checks`:

| Field | Type | Description |
|---|---|---|
| `id` | string | Stable machine id (e.g. `kvm`, `resources`, `dns`). |
| `name` | string | Human label. |
| `passed` | boolean | Result for this check. |
| `message` | string | Actionable summary; failures explain what to fix. |
| `details` | object | Check-specific structured data (may be `{}`). |

## Tunables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `preflight_min_vcpus` | `8` | Minimum logical CPUs. |
| `preflight_min_ram_mb` | `32768` | Minimum RAM (MiB). |
| `preflight_min_disk_gb` | `200` | Minimum free space on the data path (GiB). |
| `preflight_min_glibc_version` | `2.36` | Minimum glibc for the orchestrator. |
| `preflight_min_kernel_version` | `6.1` | Minimum running kernel. |
| `preflight_host_public_ip` | `qops_public_ipv4` | Required globally routable IPv4 used by the sandbox isolation probe. |
| `preflight_lan_ip` | `qops_lan_ipv4` | Required distinct private/LAN IPv4 used by the sandbox isolation probe. |
| `preflight_webhook_external_probe_cmd` | `doctor_webhook_external_probe_cmd` | Required command that probes webhook health from outside this host. |
| `preflight_meminfo` | `/proc/meminfo` | Memory information path; a missing path is reported as a resource failure. |

The data path is `e2b_data_device` when set, otherwise `preflight_orchestrator_root` (`/orchestrator`).

Implemented in **Task 5** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
