#!/usr/bin/env python3
"""Offline Compose port-merge evaluator (Docker Compose v2.24+ `!override`).

Limits (not a full `docker compose config` substitute):
- Merges only `services.*.ports` (and copies `restart`/`volumes`/`extra_hosts`
  from the override when present). Does not expand `include`/`extends`/profiles.
- Interpolates `${VAR}` and `${VAR:-default}` from --env-file plus a small
  built-in default map matching upstream kodus-installer.
- Port uniqueness follows the Compose spec key {ip, target, published, protocol}
  with missing ip treated as 0.0.0.0 and missing protocol as tcp.
- Recognises YAML tags `!override` (replace the sequence) and `!reset` (empty).
  `!override` on `ports` requires Compose Specification 3.24 / Docker Compose
  v2.24.0. Without the tag, a 127.0.0.1 mapping is *added* beside upstream's
  0.0.0.0 mapping.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml

INTERPOLATION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")
DEFAULT_ENV = {
    "WEB_PORT": "3000",
    "API_WEBHOOKS_PORT": "3332",
    "API_MCP_MANAGER_PORT": "3101",
    "WEBHOOKS_PORT": "3332",
}


class TaggedList(list):
    yaml_tag = ""


def _construct_tagged_seq(loader: yaml.Loader, node: yaml.Node) -> TaggedList:
    value = loader.construct_sequence(node)
    tagged = TaggedList(value)
    tagged.yaml_tag = node.tag
    return tagged


class ComposeLoader(yaml.SafeLoader):
    pass


ComposeLoader.add_constructor("!override", _construct_tagged_seq)
ComposeLoader.add_constructor("!reset", _construct_tagged_seq)


def load_compose(path: Path) -> dict:
    return yaml.load(path.read_text(encoding="utf-8"), Loader=ComposeLoader) or {}


def interpolate(value: Any, env: dict[str, str]) -> Any:
    if isinstance(value, str):
        def repl(match: re.Match[str]) -> str:
            key, default = match.group(1), match.group(2)
            if key in env:
                return env[key]
            return default if default is not None else match.group(0)

        return INTERPOLATION.sub(repl, value)
    if isinstance(value, list):
        kind = type(value)
        out = kind(interpolate(item, env) for item in value)
        if isinstance(value, TaggedList):
            out.yaml_tag = value.yaml_tag
        return out
    if isinstance(value, dict):
        return {k: interpolate(v, env) for k, v in value.items()}
    return value


def load_env_file(path: Path | None) -> dict[str, str]:
    env = dict(DEFAULT_ENV)
    if path is None or not path.is_file():
        return env
    assign = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = assign.match(line)
        if not match:
            continue
        value = match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        env[match.group(1)] = value
    return env


def parse_port_mapping(item: Any) -> dict[str, str | None]:
    protocol = "tcp"
    host_ip = ""
    published: str | None = None
    target: str | None = None
    if isinstance(item, dict):
        target = None if item.get("target") is None else str(item.get("target"))
        published = None if item.get("published") is None else str(item.get("published"))
        host_ip = str(item.get("host_ip") or item.get("published_ip") or "")
        protocol = str(item.get("protocol") or "tcp")
        return {
            "host_ip": host_ip,
            "published": published,
            "target": target,
            "protocol": protocol,
            "raw": str(item),
        }
    text = str(item).strip()
    if "/" in text:
        text, protocol = text.rsplit("/", 1)
    parts = text.split(":")
    if len(parts) == 1:
        target = parts[0]
    elif len(parts) == 2:
        published, target = parts
    elif len(parts) == 3:
        host_ip, published, target = parts
    else:
        host_ip, published, target = parts[0], parts[1], ":".join(parts[2:])
    return {
        "host_ip": host_ip,
        "published": published,
        "target": target,
        "protocol": protocol,
        "raw": str(item),
    }


def port_key(mapping: dict[str, str | None]) -> tuple[str, str, str, str]:
    ip = mapping.get("host_ip") or "0.0.0.0"
    published = mapping.get("published") or ""
    target = mapping.get("target") or ""
    protocol = mapping.get("protocol") or "tcp"
    return (ip, published, target, protocol)


def effective_host_ip(mapping: dict[str, str | None]) -> str:
    return mapping.get("host_ip") or "0.0.0.0"


def ports_tag(ports: Any) -> str:
    return getattr(ports, "yaml_tag", "") or ""


def merge_ports(base_ports: list, override_ports: Any) -> list[dict[str, str | None]]:
    tag = ports_tag(override_ports)
    if tag == "!reset":
        return []
    if tag == "!override":
        return [parse_port_mapping(item) for item in (override_ports or [])]
    merged: dict[tuple[str, str, str, str], dict[str, str | None]] = {}
    for item in base_ports or []:
        parsed = parse_port_mapping(item)
        merged[port_key(parsed)] = parsed
    for item in override_ports or []:
        parsed = parse_port_mapping(item)
        merged[port_key(parsed)] = parsed
    return list(merged.values())


def merge_services(base: dict, override: dict, env: dict[str, str]) -> dict[str, dict]:
    base = interpolate(base, env)
    override = interpolate(override, env)
    result: dict[str, dict] = {}
    base_services = base.get("services") or {}
    override_services = override.get("services") or {}
    names = list(base_services.keys()) + [n for n in override_services if n not in base_services]
    for name in names:
        bsvc = dict(base_services.get(name) or {})
        osvc = override_services.get(name) or {}
        if "ports" in (bsvc or {}) or "ports" in (osvc or {}):
            bsvc["ports"] = merge_ports(bsvc.get("ports") or [], osvc.get("ports") if "ports" in osvc else [])
        for key in ("restart", "volumes", "extra_hosts", "environment"):
            if key in osvc:
                bsvc[key] = osvc[key]
        result[name] = bsvc
    return result


def published_ports(services: dict[str, dict]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for name, svc in services.items():
        for mapping in svc.get("ports") or []:
            parsed = mapping if isinstance(mapping, dict) and "target" in mapping else parse_port_mapping(mapping)
            out.append({"service": name, **parsed, "effective_ip": effective_host_ip(parsed)})
    return out


def bind_violations(services: dict[str, dict], require_ip: str) -> list[dict[str, Any]]:
    bad: list[dict[str, Any]] = []
    for item in published_ports(services):
        if item["effective_ip"] != require_ip:
            bad.append(item)
    return bad


def upstream_targets(base: dict, env: dict[str, str]) -> dict[str, set[str]]:
    base = interpolate(base, env)
    targets: dict[str, set[str]] = {}
    for name, svc in (base.get("services") or {}).items():
        ports = svc.get("ports") or []
        if not ports:
            continue
        targets[name] = set()
        for item in ports:
            parsed = parse_port_mapping(item)
            if parsed.get("target"):
                targets[name].add(str(parsed["target"]))
    return targets


def missing_upstream_targets(base: dict, merged: dict[str, dict], env: dict[str, str]) -> list[str]:
    missing: list[str] = []
    for name, targets in upstream_targets(base, env).items():
        have = {str(p.get("target")) for p in published_ports({name: merged.get(name, {})})}
        for target in sorted(targets):
            if target not in have:
                missing.append(f"{name}:{target}")
    return missing


def canonical_config(services: dict[str, dict]) -> str:
    payload = {}
    for name, svc in sorted(services.items()):
        payload[name] = {
            "ports": [
                {
                    "host_ip": effective_host_ip(p) if isinstance(p, dict) else effective_host_ip(parse_port_mapping(p)),
                    "published": (p.get("published") if isinstance(p, dict) else parse_port_mapping(p).get("published")),
                    "target": (p.get("target") if isinstance(p, dict) else parse_port_mapping(p).get("target")),
                    "protocol": (p.get("protocol") if isinstance(p, dict) else parse_port_mapping(p).get("protocol")),
                }
                for p in (svc.get("ports") or [])
            ],
            "restart": svc.get("restart"),
            "volumes": svc.get("volumes"),
            "environment": svc.get("environment"),
            "extra_hosts": svc.get("extra_hosts"),
        }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def digest(ref: str, env_text: str, canonical: str) -> str:
    h = hashlib.sha256()
    h.update(ref.encode("utf-8"))
    h.update(b"\n")
    h.update(env_text.encode("utf-8"))
    h.update(b"\n")
    h.update(canonical.encode("utf-8"))
    return h.hexdigest()


def cmd_check(args: argparse.Namespace) -> int:
    env = load_env_file(Path(args.env_file) if args.env_file else None)
    base = load_compose(Path(args.base))
    override = load_compose(Path(args.override))
    merged = merge_services(base, override, env)
    violations = bind_violations(merged, args.require_ip)
    missing = missing_upstream_targets(base, merged, env)
    report = {
        "ok": not violations and not missing,
        "violations": violations,
        "missing_upstream_targets": missing,
        "ports": published_ports(merged),
        "override_ports_tags": {
            name: ports_tag((override.get("services") or {}).get(name, {}).get("ports"))
            for name, svc in (override.get("services") or {}).items()
            if "ports" in (svc or {})
        },
    }
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


def cmd_digest(args: argparse.Namespace) -> int:
    env = load_env_file(Path(args.env_file) if args.env_file else None)
    env_text = Path(args.env_file).read_text(encoding="utf-8") if args.env_file and Path(args.env_file).is_file() else ""
    base = load_compose(Path(args.base))
    override = load_compose(Path(args.override))
    merged = merge_services(base, override, env)
    print(digest(args.ref, env_text, canonical_config(merged)))
    return 0


def cmd_merge(args: argparse.Namespace) -> int:
    env = load_env_file(Path(args.env_file) if args.env_file else None)
    merged = merge_services(load_compose(Path(args.base)), load_compose(Path(args.override)), env)
    print(json.dumps({"services": {n: {"ports": s.get("ports")} for n, s in merged.items()}}, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("check", "digest", "merge"):
        p = sub.add_parser(name)
        p.add_argument("--base", required=True)
        p.add_argument("--override", required=True)
        p.add_argument("--env-file", default="")
        if name == "check":
            p.add_argument("--require-ip", default="127.0.0.1")
        if name == "digest":
            p.add_argument("--ref", required=True)
    args = parser.parse_args()
    if args.cmd == "check":
        return cmd_check(args)
    if args.cmd == "digest":
        return cmd_digest(args)
    return cmd_merge(args)


if __name__ == "__main__":
    sys.exit(main())
