# Elephant Dumbo (v2) FPGA project
#
# SPEC selects the algorithm version end to end:
#   v1 = Elephant v1 (GMU's RTL, known good; the control experiment)
#   v2 = Dumbo v2    (our target)
#
# SET picks the vector set for `make sim` (sim-all runs every set for the SPEC):
#   gmu     v1 only. GMU's shipped 3201 vectors. Use to confirm the flow/simulator/testbench
#           work on known-good hardware (core_v1) before trusting anything else.
#   random  1000 random enc/dec vectors, AD/PT up to 1000 B, with key reuse. General
#           regression.
#   edge    374 vectors: AD/PT lengths straddling block boundaries (AD at 8/28/48 B, PT at
#           20/40/60 B). Fastest useful check (~25 s); use it in the edit-simulate loop.
#   full33  2178 vectors: every (AD, PT) length pair 0..32 B, enc + dec; the same coverage as
#           the official KAT. Use before declaring a datapath/controller change done.
#   long    10 vectors of 1536 B and 4000 B. Many-block messages: catches LFSR/mask
#           indexing and counter-width bugs that short vectors miss.
#   badtag  Decrypt with one tag bit flipped; expects plaintext then a failure status.
#           Use after touching the tag compare / final-permutation path.
#   cycles  v2 only. 75 vectors on an (AD, PT) grid for cycle counting; run it via `make cycles`.
#
# ROUNDS (optional) sets PERM_ROUNDS_PER_CYCLE for `make sim`: a copy of the RTL with that value is
#   made under build/rtl/ and simulated; rtl/ is never edited. Supported: 1,4,5,8,10,16 (the permutation
#   only has round-constant tables for these; others, e.g. 2, give wrong results).
#
#   Unset = the value in rtl/ (upstream 10). Verify a ROUNDS value in sim before synthesizing it.
# SWEEP (for `make synth`) is the list of ROUNDS values to implement in Vivado, e.g. SWEEP="1 4".
#
# Examples:
#   make models                      build C models into model/lib, check v2 vs official KAT
#   make kat SPEC=v1                 generate kat/v1/gen/{random,edge,full33,long,badtag}
#   make sim SPEC=v1 SET=gmu         run LWC_TB on core_v1 with GMU's shipped vectors
#   make sim SPEC=v2 SET=edge        run LWC_TB on core_v2 with generated vectors (see SET above)
#   make sim-all SPEC=v1             every set for that SPEC
#   make sim SPEC=v2 ROUNDS=1        same, with 1 round per cycle (80 cycles per permutation)
#   make sim SIM=ghdl ...            use GHDL instead of Questa (default: questa; source ./setup.sh)
#   make synth SPEC=v2 SWEEP="1 4"   Vivado Fmax/area for those ROUNDS (source ./setup.sh vivado first);
#                                    also appends modelled cycles/throughput to reports/perf_model.csv
#   make cycles SPEC=v2 ROUNDS=4     measure cycles in simulation and check them against the cycle model

SPEC ?= v2
SET  ?= edge
SIM  ?= questa
ROUNDS ?=
SWEEP  ?= 
TESTMODE ?=

ALGO_v1 := elephant160v1
ALGO_v2 := elephant160v2
ALGO    := $(ALGO_$(SPEC))
ifeq ($(ALGO),)
$(error SPEC must be v1 or v2, got '$(SPEC)')
endif

PY       := .venv/bin/python
TOP      := LWC_TB
ifeq ($(ROUNDS),)
SRCS     := $(shell cat rtl/core_$(SPEC)/filelist.txt tb/filelist.txt)
CFG      := $(SPEC)
else
SRCS     := $(shell python3 scripts/prep_rtl.py --spec $(SPEC) --rounds $(ROUNDS) --out build/rtl/$(SPEC)_r$(ROUNDS)) $(shell cat tb/filelist.txt)
CFG      := $(SPEC)_r$(ROUNDS)
endif
# GMU's set exists only for v1; generated sets live under gen/.
KATDIR   := $(if $(filter gmu,$(SET)),kat/$(SPEC)/gmu,kat/$(SPEC)/gen/$(SET))
SETS     := $(if $(filter v1,$(SPEC)),gmu) random edge full33 long badtag
SIMDIR   := build/sim/$(SIM)/$(CFG)/$(SET)
ABS      := $(CURDIR)

# LWC_TB file generics: inputs from KATDIR, logs into SIMDIR.
TB_GENERICS := G_FNAME_PDI=$(ABS)/$(KATDIR)/pdi.txt \
               G_FNAME_SDI=$(ABS)/$(KATDIR)/sdi.txt \
               G_FNAME_DO=$(ABS)/$(KATDIR)/do.txt \
               G_FNAME_LOG=$(ABS)/$(SIMDIR)/log.txt \
               G_FNAME_TIMING=$(ABS)/$(SIMDIR)/timing.txt \
               G_FNAME_TIMING_CSV=$(ABS)/$(SIMDIR)/timing.csv \
               G_FNAME_FAILED_TVS=$(ABS)/$(SIMDIR)/failed_test_vectors.txt \
               G_FNAME_RESULT=$(ABS)/$(SIMDIR)/result.txt \
               $(if $(TESTMODE),G_TEST_MODE=$(TESTMODE))

GHDL      ?= ghdl
GHDLFLAGS ?= --std=08 -frelaxed --workdir=$(ABS)/build/ghdl/$(CFG)

.PHONY: help venv models kat sim sim-all cycles synth bench clean

help:
	@sed -n '3,/^SPEC ?=/p' Makefile | grep -v '^SPEC ?=' | sed 's/^# \{0,1\}//'

# ---- C models and vectors ------------------------------------------------
venv: .venv/bin/cryptotvgen
.venv/bin/cryptotvgen:
	python3 -m venv .venv
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q requests ./ref/LWC/software/cryptotvgen

models: venv
	.venv/bin/cryptotvgen --prepare_libs --candidates_dir=model
	$(PY) scripts/check_model_kat.py model/lib/crypto_aead/elephant160v2.so \
	  model/crypto_aead/elephant160v2/ref/LWC_AEAD_KAT_128_96.txt

kat: venv
	$(PY) scripts/gen_kat.py --spec $(SPEC)

# ---- Simulation -----------------------------------------------------------
sim:
	@test -f $(KATDIR)/pdi.txt || { echo "no vectors in $(KATDIR) (run make kat SPEC=$(SPEC))"; exit 1; }
	@rm -rf $(SIMDIR) && mkdir -p $(SIMDIR)
ifeq ($(SIM),ghdl)
	@mkdir -p build/ghdl/$(CFG)
	$(GHDL) -a $(GHDLFLAGS) $(SRCS)
	$(GHDL) -e $(GHDLFLAGS) $(TOP)
	cd $(SIMDIR) && $(GHDL) -r $(GHDLFLAGS) $(TOP) \
	  $(addprefix -g,$(TB_GENERICS)) > sim.out 2>&1 || true
else ifeq ($(SIM),questa)
	cd $(SIMDIR) && vlib work >/dev/null && \
	  vcom -2008 -quiet $(addprefix $(ABS)/,$(SRCS)) && \
	  vsim -c -quiet $(addprefix -g,$(TB_GENERICS)) $(TOP) -do "run -all; quit -f" > sim.out 2>&1 || true
else
	$(error SIM must be ghdl or questa)
endif
	@scripts/sim_result.sh $(SIMDIR) $(CFG) $(SET)

sim-all:
	@for s in $(SETS); do $(MAKE) --no-print-directory sim SPEC=$(SPEC) SET=$$s SIM=$(SIM) || exit 1; done

# Cycle counts from LWC_TB's own timing mode (G_TEST_MODE=4) -> build/sim/<sim>/<cfg>/cycles/timing.csv,
# then compare with the model in scripts/cycle_model.py. SPEC=v2 only; ROUNDS selects PERM_ROUNDS_PER_CYCLE.
cycles:
	@$(MAKE) --no-print-directory sim SPEC=$(SPEC) SET=cycles TESTMODE=4 ROUNDS=$(ROUNDS) SIM=$(SIM)
	@python3 scripts/cycle_model.py --validate

# ---- Implementation / benchmarking ----------------------------------------
# Needs Vivado on PATH (source ./setup.sh vivado). Prints a line per Vivado run; results go to
# reports/synth_results.csv (one row per design point) and reports/synth_runs.csv (every run).
synth:
	python3 scripts/synth_sweep.py --spec $(SPEC) --rounds $(SWEEP)

bench:
	$(PY) scripts/collect_results.py

clean:
	rm -rf build
