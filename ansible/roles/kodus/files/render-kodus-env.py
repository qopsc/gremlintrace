#!/usr/bin/env python3
"""Render Kodus .env from upstream .env.example plus managed overrides."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
UNSET_KEYS = frozenset({"E2B_PROXY_HOST"})
WEBHOOK_PATHS = {
    "API_GITHUB_CODE_MANAGEMENT_WEBHOOK": "/github/webhook",
    "API_GITLAB_CODE_MANAGEMENT_WEBHOOK": "/gitlab/webhook",
    "GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK": "/bitbucket/webhook",
    "GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK": "/azure-repos/webhook",
    "API_FORGEJO_CODE_MANAGEMENT_WEBHOOK": "/forgejo/webhook",
}


def parse_dotenv(text: str) -> list[tuple[str | None, str]]:
    rows: list[tuple[str | None, str]] = []
    for raw in text.splitlines(keepends=False):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("export "):
            rows.append((None, raw))
            continue
        match = ASSIGN.match(stripped)
        if not match:
            rows.append((None, raw))
            continue
        rows.append((match.group(1), match.group(2)))
    return rows


def parse_overlay(path: Path | None) -> dict[str, str]:
    if path is None or not path.is_file():
        return {}
    values: dict[str, str] = {}
    for key, value in parse_dotenv(path.read_text(encoding="utf-8")):
        if key:
            values[key] = value
    return values


def quote_if_needed(value: str) -> str:
    if value == "":
        return ""
    if any(ch in value for ch in (' ', "#", '"', "'", "\n")):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def managed_values(cfg: dict) -> dict[str, str]:
    domain = cfg["qops_domain"]
    webhooks_host = cfg.get("webhooks_host") or f"kodus-webhooks.{domain}"
    api_host = cfg.get("api_host") or f"kodus-api.{domain}"
    web_host = cfg.get("web_host") or f"kodus.{domain}"
    web_url = cfg.get("web_url") or f"https://{web_host}"
    values = {
        "SANDBOX_PROVIDER": cfg.get("sandbox_provider") or "e2b",
        "API_E2B_KEY": cfg.get("e2b_api_key") or "",
        "E2B_DOMAIN": cfg.get("e2b_domain") or f"e2b.{domain}",
        "API_E2B_TEMPLATE_ID": cfg.get("template_id") or "kodus-sandbox",
        "API_E2B_TEMPLATE_GRAPH_ID": cfg.get("template_graph_id") or "kodus-sandbox-graph",
        "API_LLM_PROVIDER_MODEL": cfg.get("llm_provider_model") or "auto",
        "WORKER_ROLE": cfg.get("worker_role") or "code-review",
        "API_RABBITMQ_ENABLED": "true",
        "API_CLOUD_MODE": "false" if not cfg.get("cloud_mode") else str(cfg["cloud_mode"]).lower(),
        "WEB_HOSTNAME_API": api_host,
        "WEB_PORT_API": str(cfg.get("web_port_api") or "443"),
        "NEXTAUTH_URL": web_url,
        "API_FRONTEND_URL": web_url,
        "API_USER_INVITE_BASE_URL": web_url,
        "API_MCP_MANAGER_REDIRECT_URI": f"{web_url}/setup/mcp/oauth",
        "API_KODUS_MCP_SERVER_URL": f"https://{api_host}/mcp",
        "IMAGE_TAG": cfg["image_tag"],
        "KODUS_TELEMETRY_DISABLED": "true" if cfg.get("telemetry_disabled") else "false",
    }
    openai_key = cfg.get("openai_api_key") or ""
    if openai_key:
        values["API_OPEN_AI_API_KEY"] = openai_key
    base_url = cfg.get("openai_force_base_url") or ""
    if base_url:
        values["API_OPENAI_FORCE_BASE_URL"] = base_url
    license_key = cfg.get("license_key") or ""
    if license_key:
        values["KODUS_LICENSE_KEY"] = license_key
    for var, path in WEBHOOK_PATHS.items():
        values[var] = f"https://{webhooks_host}{path}"
    if str(values["API_CLOUD_MODE"]).lower() not in {"true", "false"}:
        values["API_CLOUD_MODE"] = "false"
    return values


def render(example: str, cfg: dict, overlay: dict[str, str]) -> str:
    image_tag = str(cfg.get("image_tag") or "")
    if not image_tag or image_tag.lower() == "latest":
        raise SystemExit("IMAGE_TAG must be a pinned tag from versions.yml; refusing latest/empty")

    updates: dict[str, str] = {}
    for key, value in (cfg.get("env_overrides") or {}).items():
        updates[str(key)] = "" if value is None else str(value)
    updates.update(managed_values(cfg))
    updates.update(overlay)

    rows = parse_dotenv(example)
    seen: set[str] = set()
    out: list[str] = []
    for key, raw in rows:
        if key is None:
            out.append(raw)
            continue
        if key in UNSET_KEYS:
            seen.add(key)
            continue
        value = updates.get(key, raw)
        out.append(f"{key}={quote_if_needed(value) if key in updates else value}")
        seen.add(key)

    for key, value in updates.items():
        if key in seen or key in UNSET_KEYS:
            continue
        out.append(f"{key}={quote_if_needed(value)}")

    text = "\n".join(out)
    if not text.endswith("\n"):
        text += "\n"
    if "E2B_PROXY_HOST=" in text:
        raise SystemExit("E2B_PROXY_HOST must remain unset")
    return text


def atomic_write(path: Path, content: str, mode: int) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text(encoding="utf-8") == content:
        os.chmod(path, mode)
        return "unchanged"
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        os.chmod(path, mode)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return "changed"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--example", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--overlay", default="")
    parser.add_argument("--mode", default="0600")
    args = parser.parse_args()

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    example = Path(args.example).read_text(encoding="utf-8")
    overlay = parse_overlay(Path(args.overlay) if args.overlay else None)
    content = render(example, cfg, overlay)
    mode = int(args.mode, 8)
    result = atomic_write(Path(args.output), content, mode)
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
