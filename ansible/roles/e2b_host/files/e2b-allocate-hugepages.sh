#!/usr/bin/env bash
# Allocate hugetlbfs pages for E2B before Docker starts.
set -euo pipefail

PERCENTAGE="${E2B_HUGEPAGES_PERCENTAGE:?E2B_HUGEPAGES_PERCENTAGE is required}"

if ! [[ "${PERCENTAGE}" =~ ^[0-9]+$ ]] || (( PERCENTAGE < 0 || PERCENTAGE > 100 )); then
  echo "E2B_HUGEPAGES_PERCENTAGE must be an integer between 0 and 100 (got: ${PERCENTAGE})" >&2
  exit 1
fi

hugepage_size_kb="$(awk '/Hugepagesize:/ {print $2; exit}' /proc/meminfo)"
if ! [[ "${hugepage_size_kb}" =~ ^[0-9]+$ ]] || (( hugepage_size_kb == 0 )); then
  echo "unable to read Hugepagesize from /proc/meminfo" >&2
  exit 1
fi
hugepage_size_mib=$((hugepage_size_kb / 1024))

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

total_hugepages=$((hugepages_ram / hugepage_size_mib))
base_hugepages=$((total_hugepages * PERCENTAGE / 100))
base_hugepages="$(remove_decimal "${base_hugepages}")"
overcommit_hugepages=$((total_hugepages * (100 - PERCENTAGE) / 100))
overcommit_hugepages="$(remove_decimal "${overcommit_hugepages}")"

echo "${base_hugepages}" >/proc/sys/vm/nr_hugepages
echo "${overcommit_hugepages}" >/proc/sys/vm/nr_overcommit_hugepages

actual_base="$(cat /proc/sys/vm/nr_hugepages)"
actual_overcommit="$(cat /proc/sys/vm/nr_overcommit_hugepages)"

if (( actual_base < base_hugepages || actual_overcommit < overcommit_hugepages )); then
  echo "hugepage allocation shortfall: requested nr_hugepages=${base_hugepages} nr_overcommit_hugepages=${overcommit_hugepages} got nr_hugepages=${actual_base} nr_overcommit_hugepages=${actual_overcommit}" >&2
  exit 1
fi

printf 'allocated nr_hugepages=%s nr_overcommit_hugepages=%s (split %s/%s, page_size_mib=%s)\n' \
  "${actual_base}" "${actual_overcommit}" "${PERCENTAGE}" "$((100 - PERCENTAGE))" "${hugepage_size_mib}"
