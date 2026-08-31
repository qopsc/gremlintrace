#!/usr/bin/env bash
# Shared helpers for bootstrap.bats

read_recorded_argv() {
  mapfile -t RECORDED_ARGV <"${BOOTSTRAP_STUB_LOG}"
}

assert_argv_equals() {
  local -a expected=("$@")
  read_recorded_argv
  if [[ "${#RECORDED_ARGV[@]}" -ne "${#expected[@]}" ]]; then
    echo "argv length mismatch: got ${#RECORDED_ARGV[@]} want ${#expected[@]}" >&2
    printf '  got:  %q\n' "${RECORDED_ARGV[@]}" >&2
    printf '  want: %q\n' "${expected[@]}" >&2
    return 1
  fi
  local i
  for i in "${!expected[@]}"; do
    if [[ "${RECORDED_ARGV[$i]}" != "${expected[$i]}" ]]; then
      echo "argv[$i] mismatch: got ${RECORDED_ARGV[$i]@Q} want ${expected[$i]@Q}" >&2
      return 1
    fi
  done
}
