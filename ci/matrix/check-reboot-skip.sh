#!/usr/bin/env bash
# Reboot persistence is not exercised on GitHub-hosted runners (no reboot API).
set -euo pipefail

MSG="Reboot → doctor.yml persistence is not simulated on GitHub-hosted runners. \
A full reboot gate requires a self-hosted or bare-metal leg (M2 Proxmox snapshots). \
Doctor preflight/unit checks on a warm host are the closest available substitute."

printf '%s\n' "${MSG}"
exit 0
