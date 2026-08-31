#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VERSIONS_FILE="${REPO_ROOT}/versions.yml"
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
