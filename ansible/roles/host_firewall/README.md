# host_firewall

Host nftables input policy for codereviewer. Manages only the `qops_filter` table; Docker and orchestrator tables are never flushed by this role or by its boot unit (`qops-nftables.service`, a oneshot without `ExecStop`). The distro `nftables.service` is deliberately **not** enabled: Ubuntu's `/etc/nftables.conf` starts with `flush ruleset` and that unit's stop action flushes everything. Operators must not enable it on a codereviewer host.

## Policy

| Traffic | Rule |
|---|---|
| Loopback | accept |
| Established/related | accept |
| `veth-*` | allow TCP dports 5010–5012 and 5016–5018 only, then **drop** all other veth traffic |
| ICMP / ICMPv6 | accept (after the veth drop; neighbour discovery and PMTU need it) |
| Other interfaces | allow TCP dports `host_firewall_ssh_ports` (default: `ansible_port`, else 22), 80, 443 |
| Default | drop |

`e2b_allow_sandbox_internal_cidrs` is **not** applied here. It becomes `ALLOW_SANDBOX_INTERNAL_CIDRS` in the orchestrator env (task `e2b_services`) for sandbox egress policy.

Reload deletes and recreates only `inet qops_filter`.

Implemented in **Task 5** (see `../../../docs/superpowers/specs/2026-08-28-kodus-e2b-selfhost-design.md`, Phase 2).
