# ==============================================================================
# Makefile for the AXI4-Lite UVC self-test (scaffolded by uvm-tb).
#
# Usage:
#   make                 compile, elaborate, and run TEST in batch mode
#   make TEST=<uvm_test> run a different UVM test
#   make waves           run and dump a waveform database (waves.wdb)
#   make gui             run interactively in the XSIM GUI
#   make clean           remove simulation artifacts
#   make help            show this list of targets
#
# Common overrides (pass on the command line, e.g. `make run SEED=1`):
#   TEST, SEED, UVM_VERBOSITY, WAVES, PLUSARGS, VIVADO_PATH
#
# Available tests (TEST=...):
#   axi_lite_smoke_test        a little traffic, no backpressure
#   axi_lite_multiwidth_test   all five widths, random backpressure   [default]
#   axi_lite_backpressure_test every built-in ready model, one per link
#   axi_lite_no_ready_test     every READY held low, then released
#   axi_lite_sweep_test        walk every location of every window
#   axi_lite_error_resp_test   SLVERR and DECERR regions in the slave model
#   axi_lite_pipelined_test    several transactions in flight at once
#   axi_lite_reset_test        ARESETn pulsed mid-traffic
#   make regress               runs all of the above in turn
#
# The UVC itself is compiled through $(UVC_FILELIST) -- the same drop-in
# filelist another project would use -- so this build exercises the UVC's
# packaging, not just its source.
# ==============================================================================

SHELL           := /bin/bash

SIM             ?= xsim
TOP             ?= axi_lite_tb_top
TEST            ?= axi_lite_multiwidth_test
SEED            ?= random
UVM_VERBOSITY   ?= UVM_MEDIUM
FILELIST        ?= filelist.f
EXTRA_FILELIST  ?= extra_files.f

# Root of this repository, so the UVC is pulled in exactly the way a
# consuming project pulls it in. Override to compile against a UVC
# checked out elsewhere.
AXI_LITE_UVC_ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
export AXI_LITE_UVC_ROOT
UVC_FILELIST    ?= $(AXI_LITE_UVC_ROOT)/src/axi_lite_uvc.f
SNAPSHOT        ?= $(TOP)_snap
WAVES           ?= 0
PLUSARGS        ?=
SIM_LOG         ?= sim.log
WAVE_TCL        ?= wave.tcl

# Waveform database captured and reopened by `make waves`.
WAVE_DB         ?= waves.wdb

# Wave *configuration* -- the signal list, groups, radices and colours you
# arranged by hand in the XSIM window. Save it from the GUI (File > Save
# Waveform Configuration) as one of the names below and every later
# `make waves` reopens with it, so a customised layout is not lost every
# time the simulation is re-run. $(TOP).wcfg is what the GUI offers by
# default; waves.wcfg is accepted too. Override WAVE_CFG for any other name.
WAVE_CFG_CANDIDATES ?= $(TOP).wcfg waves.wcfg
WAVE_CFG        ?= $(firstword $(wildcard $(WAVE_CFG_CANDIDATES)))

# A UVM_FATAL/UVM_ERROR run still exits xsim with status 0 (it called
# $finish, not a crash), so `run`/`waves` below tee the simulation log and
# grep it for the top module's own "result : FAILED" banner line instead,
# so a failing test actually fails the `make` invocation too (for CI).
CHECK_PASS = ! grep -q '^ result  : FAILED$$' $(SIM_LOG)

# ------------------------------------------------------------------------------
# Per-simulator setup. Add another `else ifeq` block here to support more
# simulators (Questa, VCS, Xcelium, ...); everything below this block is
# written to be simulator-agnostic.
# ------------------------------------------------------------------------------
ifeq ($(SIM),xsim)
  # No fixed Vivado install was given at generate-time, so pick the
  # highest-sorting version directory under VIVADO_BASE, e.g.
  # /tools/Xilinx/Vivado/2023.2. Override either on the command line:
  #   make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ...
  VIVADO_BASE    ?= /tools/Xilinx/Vivado
  VIVADO_VERSION ?= $(notdir $(lastword $(sort $(wildcard $(VIVADO_BASE)/*))))
  VIVADO_PATH    ?= $(VIVADO_BASE)/$(VIVADO_VERSION)
  VIVADO_SETTINGS := $(VIVADO_PATH)/settings64.sh
  VIVADO_ENV      := source $(VIVADO_SETTINGS) >/dev/null &&

  XVLOG_BIN      ?= xvlog
  XELAB_BIN      ?= xelab
  XSIM_BIN       ?= xsim
  UVM_LIB        ?= uvm

  XVLOG_FLAGS    := -sv -L $(UVM_LIB)
  # --override_time{unit,precision} force one consistent timescale across
  # the whole design, since xelab errors out on a mix of modules with and
  # without an explicit `timescale (which the DUT may or may not declare).
  XELAB_FLAGS    := -L $(UVM_LIB) --timescale 1ns/1ps --override_timeunit --override_timeprecision
  ifeq ($(WAVES),1)
    XELAB_FLAGS  += -debug all
  else
    XELAB_FLAGS  += -debug typical
  endif
  RUN_FLAGS      := -sv_seed $(SEED) -testplusarg "UVM_TESTNAME=$(TEST)" -testplusarg "UVM_VERBOSITY=$(UVM_VERBOSITY)" $(PLUSARGS)
  REQUIRED_TOOLS := $(XVLOG_BIN) $(XELAB_BIN) $(XSIM_BIN)
else
  $(error Unsupported SIM=$(SIM). Supported simulators: xsim)
endif

REGRESS_TESTS ?= axi_lite_smoke_test axi_lite_multiwidth_test \
                 axi_lite_backpressure_test axi_lite_no_ready_test \
                 axi_lite_sweep_test axi_lite_error_resp_test \
                 axi_lite_pipelined_test axi_lite_reset_test

CHECK_TOP      ?= axi_lite_if_check_tb
CHECK_SNAPSHOT ?= $(CHECK_TOP)_snap

.PHONY: all compile elab run sim waves gui clean help check-tools regress check-protocol

# `make` on its own builds everything and runs the test to completion in
# batch mode, failing the invocation if the test failed.
all: run

check-tools:
	@if [ ! -f "$(VIVADO_SETTINGS)" ]; then \
		echo "error: Vivado settings script not found: $(VIVADO_SETTINGS)"; \
		echo "       Override VIVADO_PATH, e.g.:"; \
		echo "         make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ..."; \
		exit 1; \
	fi
	@$(VIVADO_ENV) ( for t in $(REQUIRED_TOOLS); do \
		command -v $$t >/dev/null 2>&1 || { echo "error: '$$t' not found even after sourcing $(VIVADO_SETTINGS)"; exit 1; }; \
	done )

compile: check-tools
	$(VIVADO_ENV) $(XVLOG_BIN) $(XVLOG_FLAGS) -f $(UVC_FILELIST) -f $(FILELIST) $(if $(wildcard $(EXTRA_FILELIST)),-f $(EXTRA_FILELIST))

elab: compile
	$(VIVADO_ENV) $(XELAB_BIN) $(XELAB_FLAGS) $(TOP) -s $(SNAPSHOT)

run sim: elab
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) -R | tee $(SIM_LOG); } && \
	$(CHECK_PASS)

# Open the waveforms in the Vivado window.
#
# $(WAVE_DB) is a real file target rather than a phony one, so make runs
# the recipe below only when the database is missing: the first `make
# waves` simulates and then opens, and every later one opens straight
# away. Delete $(WAVE_DB) (or `make clean`) to force a fresh capture --
# which is what you want after editing the design, since make cannot tell
# that an existing database is out of date.
$(WAVE_DB):
	@$(MAKE) --no-print-directory elab
	@echo "==> no $(WAVE_DB) yet; running $(TEST) to capture one"
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) -wdb $(WAVE_DB) -tclbatch $(WAVE_TCL) | tee $(SIM_LOG); } || true
	@if [ ! -f "$(WAVE_DB)" ]; then \
		echo "error: the simulation produced no $(WAVE_DB) -- see $(SIM_LOG)"; \
		exit 1; \
	fi

# A failing test still opens its waveforms -- that is the point of this
# target. `run` stays the pass/fail gate for CI.
waves: $(WAVE_DB)
	@if grep -q '^ result  : FAILED$$' $(SIM_LOG) 2>/dev/null; then \
		echo "note: that run FAILED -- opening its waveforms anyway, which is"; \
		echo "      the point. Use 'make run' as the pass/fail gate."; \
	fi
	@if [ -n "$(WAVE_CFG)" ]; then \
		echo "==> opening $(WAVE_DB) with saved wave configuration $(WAVE_CFG)"; \
	else \
		echo "==> opening $(WAVE_DB) with no saved wave configuration."; \
		echo "    (arrange the waveform how you like, then File > Save Waveform"; \
		echo "     Configuration as '$(TOP).wcfg' here -- later runs reopen with it.)"; \
	fi
	@$(VIVADO_ENV) $(XSIM_BIN) --gui $(WAVE_DB) $(if $(WAVE_CFG),--view $(WAVE_CFG))

# Run interactively in the XSIM GUI: the simulation is live and stepped
# from the GUI, rather than replayed from a captured database.
gui: elab
	$(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) --gui $(if $(WAVE_CFG),--view $(WAVE_CFG))

# Negative test for the interface's protocol assertions: breaks each rule
# on purpose and fails unless the interface catches it. Worth running
# whenever those assertions are touched -- a checker that stops firing
# makes every other test in here pass for the wrong reason.
check-protocol: compile
	$(VIVADO_ENV) $(XELAB_BIN) $(XELAB_FLAGS) $(CHECK_TOP) -s $(CHECK_SNAPSHOT)
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(CHECK_SNAPSHOT) -R | tee check.log; } && \
	! grep -q '^ result  : FAILED$$' check.log

# Every test in turn against one elaborated snapshot. Keeps going after a
# failure so one broken test does not hide the state of the others, then
# fails the target if any of them failed.
regress: elab
	@$(MAKE) --no-print-directory check-protocol
	@set -o pipefail; rc=0; \
	for t in $(REGRESS_TESTS); do \
	  echo "=== $$t ==="; \
	  if { $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) -sv_seed $(SEED) \
	        -testplusarg "UVM_TESTNAME=$$t" \
	        -testplusarg "UVM_VERBOSITY=$(UVM_VERBOSITY)" $(PLUSARGS) -R \
	        | tee $$t.log; } && ! grep -q '^ result  : FAILED$$' $$t.log; then \
	    echo "--- $$t PASSED"; \
	  else \
	    echo "--- $$t FAILED"; rc=1; \
	  fi; \
	done; \
	echo; echo "regression $$([ $$rc -eq 0 ] && echo PASSED || echo FAILED)"; \
	exit $$rc

# Note what is *not* removed: *.wcfg. A saved waveform arrangement is
# hand-made and is not a build artifact, so `make clean` leaves it alone.
clean:
	rm -rf xsim.dir *.wdb *.jou *.log *.pb webtalk* .Xil
	rm -f $(SNAPSHOT).* $(CHECK_SNAPSHOT).*

help:
	@echo "Targets:"
	@echo "  all (default) - compile, elaborate, and run TEST in batch mode"
	@echo "  compile        - compile sources listed in FILELIST + EXTRA_FILELIST with xvlog"
	@echo "  elab           - elaborate TOP into a simulation snapshot"
	@echo "  run / sim      - build and run TEST to completion, no GUI"
	@echo "  waves          - open the waveforms in Vivado, simulating first if needed"
	@echo "  gui            - build and run interactively in the XSIM GUI"
	@echo "  regress        - run every test in REGRESS_TESTS against one snapshot"
	@echo "  check-protocol - negative test: prove the protocol assertions fire"
	@echo "  clean          - remove simulation artifacts"
	@echo ""
	@echo "Common overrides: TEST=<uvm_test> SEED=<n> UVM_VERBOSITY=<UVM_*> WAVES=1 VIVADO_PATH=<path>"
	@echo ""
	@echo "Waveforms: 'make waves' opens $(WAVE_DB) in Vivado, running the test"
	@echo "first if there is no database yet. Delete $(WAVE_DB) to force a re-run."
	@echo "Save your arrangement from the GUI as $(TOP).wcfg and it is reused"
	@echo "automatically on every later 'make waves'."
	@echo ""
	@echo "Other files needed for simulation (e.g. sub-modules your DUT"
	@echo "instantiates)? List them in $(EXTRA_FILELIST), one per line."
