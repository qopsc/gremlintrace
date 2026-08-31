#!/usr/bin/env bash
# Allocate hugetlbfs pages for E2B before Docker starts.
set -euo pipefail

PERCENTAGE="${E2B_HUGEPAGES_PERCENTAGE:?E2B_HUGEPAGES_PERCENTAGE is required}"
HUGEPAGE_SIZE_MIB=2

max() {
  if (($1 > $2)); then echo "$1"; else echo "$2"; fi
}

min() {
  if (($1 < $2)); then echo "$1"; else echo "$2"; fi
}

ensure_even() {
  if (($1 % 2 == 0)); then echo "$1"; else echo $(($1 - 1)); fi
}

remove_decimal() {
  printf '%s' "$1" | sed 's/\..*//'
}

available_ram="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
min_normal_ram=$((4 * 1024))
min_normal_percentage_ram=$((available_ram * 16 / 100))
max_normal_ram=$((42 * 1024))

reserved_normal_ram="$(max "${min_normal_ram}" "${min_normal_percentage_ram}")"
reserved_normal_ram="$(min "${reserved_normal_ram}" "${max_normal_ram}")"

hugepages_ram=$((available_ram - reserved_normal_ram))
hugepages_ram="$(remove_decimal "${hugepages_ram}")"
hugepages_ram="$(ensure_even "${hugepages_ram}")"

total_hugepages=$((hugepages_ram / HUGEPAGE_SIZE_MIB))
base_hugepages=$((total_hugepages * PERCENTAGE / 100))
base_hugepages="$(remove_decimal "${base_hugepages}")"
overcommit_hugepages=$((total_hugepages * (100 - PERCENTAGE) / 100))
overcommit_hugepages="$(remove_decimal "${overcommit_hugepages}")"

echo "${base_hugepages}" >/proc/sys/vm/nr_hugepages
echo "${overcommit_hugepages}" >/proc/sys/vm/nr_overcommit_hugepages

printf 'allocated nr_hugepages=%s nr_overcommit_hugepages=%s (split %s/%s)\n' \
  "${base_hugepages}" "${overcommit_hugepages}" "${PERCENTAGE}" "$((100 - PERCENTAGE))"
