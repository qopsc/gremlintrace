# E2B sandbox templates

Host-side definitions and build script for the three aliases Kodus looks up by name:
`base`, `kodus-sandbox`, and `kodus-sandbox-graph`. Built with the E2B JS SDK
(`versions.yml:e2b_sdk_version`) against the **local** API
(`E2B_API_URL=http://127.0.0.1:8080`). TLS is deliberately off this path.

Kodus reads `API_E2B_TEMPLATE_ID` / `API_E2B_TEMPLATE_GRAPH_ID` as **aliases**,
never build IDs. If an alias is missing, the worker falls back to a parameterless
`Sandbox.create` and logs `falling back to default`. These aliases must exist.

## Templates

| Alias | vCPU | Memory | Definition |
|---|---|---|---|
| `base` | 2 | 512 MB | `Template().fromBaseImage()` (Kodus fallback) |
| `kodus-sandbox` | 2 | 1024 MB | `Template().fromBaseImage().aptInstall(['git','ripgrep'])` |
| `kodus-sandbox-graph` | 2 | 2560 MB | same definition as `kodus-sandbox`; more RAM for graph jobs |

CPU/RAM are fixed at template build time (`Sandbox.create` has no cpu/ram fields).
`base` CPU is the SDK default (`cpuCount` 2) made explicit; the spec only
mandates 512 MB for that alias.

There is **no** shadowsocks `runCmd`, **no** `copy(config.json)`, and **no**
`setStartCmd` / `waitForPort`. Sandboxes reach the internet directly. Kodus
installs `@kodus/kodus-graph` at runtime inside the sandbox; it is not pre-baked.

Alias names and resource specs live in `kodus-template.ts` (`TEMPLATE_SPECS`)
and are the single source consumed by `build-templates.ts` and the tests.

## Base image

Default: `e2bdev/base` via `Template.fromBaseImage()`. That SDK helper is
hard-wired to E2B's published base (`e2bdev/base:latest` inside the SDK). We do
**not** write `:latest` ourselves. This default is **intentionally unpinned**:
E2B does not publish a digest for `e2bdev/base` alongside `e2b.pin`, and the
Firecracker rootfs is rebuilt from whatever the template-manager pulls. Pin a
mirror when you need to:

```bash
export E2B_BASE_IMAGE=registry.example.com/e2bdev/base@sha256:<digest>
```

That switches the builder to `fromImage(<value>)` so a customer registry (or
digest) can dodge Docker Hub anonymous pull rate limits. Registry credentials
are not passed by this script; pre-auth the Docker daemon on the build host if
the mirror is private.

## How to run a real build

On the E2B host, after `e2b-api` and `e2b-orchestrator` are healthy, with Node
`versions.yml:node_version` and this directory's dependencies installed:

```bash
cd e2b/templates
npm ci
export E2B_API_KEY=e2b_…          # team key from /etc/qops/secrets.env
export E2B_API_URL=http://127.0.0.1:8080
npm run build-templates
```

`site.yml` must **not** pass `E2B_TEMPLATE_FORCE`; existing aliases are skipped
(`Template.exists`). `upgrade.yml` sets `E2B_TEMPLATE_FORCE=true` so every alias
is rebuilt (`skipCache: true`).

Unit tests (offline, mocked SDK):

```bash
npm test
npm run typecheck
```

From the repo root, `make test` / `make check` run this vitest suite after `npm ci`.

## Environment variable contract

Consumed by `build-templates.ts`. The later `e2b_templates` Ansible role must
use these exact names.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `E2B_API_KEY` | **yes** | — | E2B team API key (`e2b_…`). No silent fallback. |
| `E2B_API_URL` | **yes*** | — | API base URL. Local builds: `http://127.0.0.1:8080`. |
| `E2B_DOMAIN` | **yes*** | — | SDK domain (e.g. `e2b.example.com`). |
| `E2B_TEMPLATE_FORCE` | no | unset (false) | If `1` / `true` / `yes` (case-insensitive), rebuild even when the alias exists. |
| `E2B_BASE_IMAGE` | no | `e2bdev/base` | Override base image; uses `fromImage` when set to a non-default value. |

\*At least one of `E2B_API_URL` or `E2B_DOMAIN` is required. If both are
omitted the script **exits 2** and does not call the SDK.

**Cloud rejection (not just presence).** The script parses `E2B_API_URL` with
`new URL()` (scheme must be `http` or `https`) and treats `E2B_DOMAIN` as a
hostname. After lowercasing and stripping a trailing DNS dot, a hostname is
**E2B Cloud** iff it is exactly `e2b.app` or a DNS child of that apex
(`host === 'e2b.app' || host.endsWith('.e2b.app')`). That rejects `e2b.app`,
`api.e2b.app`, and any subdomain of `e2b.app`. It does **not** reject
`https://evil.com/?x=e2b.app` (host is `evil.com`) or
`https://api.e2b.app.customer.net` (host is not a child of `e2b.app`). A Cloud
hostname, or a malformed / non-http(s) `E2B_API_URL`, **exits 2**, names the
offending variable and its value, states that the build was refused because it
would have targeted E2B Cloud (Cloud case), and calls neither `Template.exists`
nor `Template.build`.

**No escape hatch.** This installer builds templates only for the customer's
self-hosted cluster. There is no legitimate reason for this script to talk to
E2B Cloud, and an opt-in would be a footgun (inherited CI env, copied `.env`).
Point the variables at the local API instead: `E2B_API_URL=http://127.0.0.1:8080`.

Values are passed explicitly as `Template.build` / `Template.exists` options
(`apiKey`, `apiUrl`, and `domain` when set). When only `E2B_DOMAIN` is set, the
script synthesizes `apiUrl=https://api.<domain>` so a leftover process
`E2B_API_URL` cannot win (the SDK resolves
`opts.apiUrl || process.env.E2B_API_URL || https://api.${domain}`).

## JSON summary schema

After all work (and also on config errors, with an empty list), the script
writes **one JSON line** to stdout as the last stdout line. Build logs from
`onBuildLogs` may precede it on stdout; human status goes to stderr. Ansible
should parse **the last line of stdout**.

```json
{
  "templates": [
    { "alias": "base", "templateId": "<id>", "action": "built", "buildId": "<id>" },
    { "alias": "kodus-sandbox", "templateId": null, "action": "skipped", "buildId": null },
    { "alias": "kodus-sandbox-graph", "templateId": "<id>", "action": "built", "buildId": "<id>" }
  ]
}
```

**Schema change (review round 1):** each row now includes `templateId`. The
Local registry tags images as `templateId:buildId`, not `alias:buildId`. The
host pruner and any consumer of `/var/lib/e2b/templates-last-summary.json`
must read `templateId`.

| Field | Type | Notes |
|---|---|---|
| `templates` | array | Always the three spec aliases, in order (`base` first). |
| `templates[].alias` | string | `base` \| `kodus-sandbox` \| `kodus-sandbox-graph` |
| `templates[].templateId` | string or `null` | SDK `BuildInfo.templateId` when `action` is `built`; otherwise `null`. Used by the Local-registry pruner. |
| `templates[].action` | string | `built` \| `skipped` \| `failed` |
| `templates[].buildId` | string or `null` | SDK `BuildInfo.buildId` when `action` is `built`; otherwise `null`. Kodus does not consume this. |

### Exit codes

| Code | Constant | When |
|---|---|---|
| 0 | success | Every processed alias was `built` or `skipped` |
| 1 | build failed | An SDK `exists`/`build` call threw (`action: failed`) |
| 2 | config error | Missing `E2B_API_KEY`; missing both `E2B_API_URL` and `E2B_DOMAIN`; Cloud hostname (`e2b.app` or a child); malformed or non-http(s) `E2B_API_URL` |

Skipped aliases are **success** (exit 0). That is the `site.yml` idempotence
path.

## What is untested here

No Docker, KVM, or E2B cluster on the machine that wrote this. The following
is written but has **not** been run:

- `Template.build` / `Template.exists` against a real E2B API
- Pulling `e2bdev/base` (or a mirror) and the template-manager Firecracker conversion
- `onBuildLogs` streaming from a live build
- `E2B_TEMPLATE_FORCE` / `skipCache` behaviour against a real template store
- Private-registry auth for `E2B_BASE_IMAGE`
- The Ansible `e2b_templates` role (task 8) invoking this script
- Kodus creating a sandbox from these aliases

Verified on this machine: `npm ci` in `e2b/templates`, `vitest run` with the
mocked SDK, `tsc --noEmit`, and `make check` (which includes those plus bats /
yamllint / ansible-lint).
