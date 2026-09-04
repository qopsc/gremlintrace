#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VERSIONS_FILE="${REPO_ROOT}/versions.yml"
  E2B_PIN_FILE="${REPO_ROOT}/e2b/e2b.pin"
}

@test "versions.yml parses as YAML" {
  run python3 -c "
import sys
import yaml
with open('${VERSIONS_FILE}') as f:
    yaml.safe_load(f)
print('ok')
"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "versions.yml contains every required key" {
  run python3 -c "
import sys
import yaml
required = [
    'e2b_pin', 'e2b_dist_version', 'e2b_go_version',
    'firecracker_version', 'kernel_version', 'busybox_version', 'envd_version',
    'e2b_postgres_image', 'e2b_postgres_tag',
    'e2b_redis_image', 'e2b_redis_tag',
    'e2b_clickhouse_image', 'e2b_clickhouse_tag',
    'e2b_otel_collector_image', 'e2b_otel_collector_tag',
    'kodus_installer_ref', 'kodus_image_tag',
    'traefik_version', 'goose_version', 'node_version', 'kodus_graph_version',
]
with open('${VERSIONS_FILE}') as f:
    data = yaml.safe_load(f)
missing = [k for k in required if k not in data]
if missing:
    print('missing:', ','.join(missing))
    sys.exit(1)
print('all present')
"
  [ "$status" -eq 0 ]
  [ "$output" = "all present" ]
}

@test "kodus_image_tag is not latest" {
  run python3 -c "
import yaml
with open('${VERSIONS_FILE}') as f:
    tag = yaml.safe_load(f)['kodus_image_tag']
if str(tag).lower() == 'latest':
    raise SystemExit(1)
print(tag)
"
  [ "$status" -eq 0 ]
  [ "$output" != "latest" ]
}

@test "e2b.pin matches versions.yml e2b_pin" {
  run python3 -c "
import re
import yaml
from pathlib import Path
root = Path('${REPO_ROOT}')
pin_file = (root / 'e2b/e2b.pin').read_text().strip()
versions_pin = yaml.safe_load((root / 'versions.yml').read_text())['e2b_pin']
if pin_file != versions_pin:
    print(f'mismatch: pin={pin_file!r} versions={versions_pin!r}')
    raise SystemExit(1)
print('match')
"
  [ "$status" -eq 0 ]
  [ "$output" = "match" ]
}

@test "e2b_pin is 40 lowercase hex characters" {
  run python3 -c "
import re
import yaml
pin = yaml.safe_load(open('${VERSIONS_FILE}'))['e2b_pin']
if not re.fullmatch(r'[0-9a-f]{40}', pin):
    raise SystemExit(1)
print(pin)
"
  [ "$status" -eq 0 ]
}

@test "e2b_dist_version equals first 7 characters of e2b_pin" {
  run python3 -c "
import yaml
data = yaml.safe_load(open('${VERSIONS_FILE}'))
pin = data['e2b_pin']
dist = data['e2b_dist_version']
if dist != pin[:7]:
    print(f'mismatch: dist={dist!r} pin[:7]={pin[:7]!r}')
    raise SystemExit(1)
print(dist)
"
  [ "$status" -eq 0 ]
}
