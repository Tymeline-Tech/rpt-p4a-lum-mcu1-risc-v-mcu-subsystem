#!/usr/bin/env bash
# Run cocotb for every core unit block that has RTL + TB present.
# Invoked by: make sim block=alu block=regfile block=control
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

KNOWN_UNIT_BLOCKS=(alu regfile control)
COVERAGE_XML="${COVERAGE_XML:-coverage.xml}"

ran=0
rm -f coverage*.xml

for b in "${KNOWN_UNIT_BLOCKS[@]}"; do
  rtl="rtl/core/${b}.sv"
  tb="tb/core/${b}_cocotb.py"
  if [[ -f "${rtl}" && -f "${tb}" ]]; then
    echo "sim: unit block=${b}"
    make sim-one "block=${b}"
    ran=$((ran + 1))
  else
    echo "sim: skip block=${b} (missing ${rtl} and/or ${tb})"
  fi
done

if [[ "${ran}" -eq 0 ]]; then
  echo "error: no unit blocks ready (need rtl/core/<b>.sv and tb/core/<b>_cocotb.py)" >&2
  exit 1
fi

if [[ ! -f "${COVERAGE_XML}" ]]; then
  echo "error: ${COVERAGE_XML} not produced" >&2
  exit 1
fi

n="$(ls coverage*.xml 2>/dev/null | wc -l)"
if [[ "${n}" -ne 1 ]]; then
  echo "error: expected exactly one coverage*.xml, found ${n}" >&2
  ls -la coverage*.xml >&2 || true
  exit 1
fi

touch MAKFILE_DEFINED SIM_TARGET_PASS
echo "sim: OK — ${ran} unit block(s); wrote ${COVERAGE_XML} MAKFILE_DEFINED SIM_TARGET_PASS"
