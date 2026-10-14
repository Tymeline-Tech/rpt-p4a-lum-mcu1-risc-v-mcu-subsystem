# LUM-MCU1 — repository foundation build contract
# Next stages add lint / sim / synth targets; this stage provides setup-check.

.PHONY: setup-check

# Verify foundational layout and emit gate artifacts at the repository root.
# Artifacts are produced by this run (never committed as placeholders).
setup-check:
	@test -d rtl || (echo "error: rtl/ directory missing" >&2; exit 1)
	@test -d tb || (echo "error: tb/ directory missing" >&2; exit 1)
	@test -d synth || (echo "error: synth/ directory missing" >&2; exit 1)
	@test -d docs || (echo "error: docs/ directory missing" >&2; exit 1)
	@test -f setup.sh || (echo "error: setup.sh missing" >&2; exit 1)
	@touch RTL_DIR_EXISTS
	@touch TB_DIR_EXISTS
	@touch SYNTH_DIR_EXISTS
	@touch DOCS_DIR_EXISTS
	@touch SETUP_SCRIPT_EXISTS
	@echo "setup-check: rtl/ tb/ synth/ docs/ and setup.sh present"
