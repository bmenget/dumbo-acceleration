# Elephant Dumbo (v2) FPGA project
#
# CORE selects the RTL: rtl/<CORE>/ (filelist.txt in compile order); the name is the path under rtl/.
#   gmu/arch1_v1   Elephant v1, GMU arch-1, unmodified: the validation control
#   brody/base_r10     Dumbo v2, our port of GMU arch-1: the BASELINE for every benchmark
#   brody/*        our v2 cores (base_rN: rounds per cycle; r4_BtoJ: options B through J at 4 rounds/stage)
#   logan/*        Logan's SystemVerilog cores (shared sources in rtl/logan/src/); sizes in rtl/<CORE>/defines.txt
#   merged/*       Logan's cores with our options, and our cores with his ideas
#   attic/*        superseded cores, kept buildable
# The spec (C model and vectors) is v1 for gmu/* cores and v2 for every other core.
# SPEC=v1 / SPEC=v2 without CORE is a shorthand for CORE=gmu/arch1_v1 / CORE=brody/base_r10.
#
# SET picks the vector set for `make sim` (sim-all runs every validation set for the spec):
#   gmu     v1 only. GMU's shipped 3201 vectors. Use to confirm the flow/simulator/testbench
#           work on known-good hardware (gmu/arch1_v1) before trusting anything else.
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
#   cycles  81 vectors on an (AD, PT) grid plus plaintext-only 16 B and 64 B; used by `make cycles`.
#   prof_short, prof_long   one workload each (16+16 B, 1536+1536 B); used by `make profile`.
#
# Benchmark flow for a core (all write results keyed by CORE):
#   make sim-all CORE=brody/r4_BtoJ  1. validate: must PASS before any number below means anything
#   make cycles  CORE=brody/r4_BtoJ  2. measured cycles per message -> build/sim/questa/<core>/cycles/timing.csv
#   make profile CORE=brody/r4_BtoJ WL=long   3. where the cycles go (permutation busy / I/O / idle) -> reports/profile.csv
#   make synth   CORE=brody/r4_BtoJ  4. Fmax and area (source ./setup.sh vivado first) -> reports/synth_results.csv
#                                       Fmax search: scripts/fmax.py (tight probe, calibrated retargets, <= 4 runs).
#                                       PERIOD0=<ns> overrides the first (probe) target.
#   make report                      5. every core vs the baseline -> reports/benchmark.csv
#   make plots                       6. report graphs -> reports/graphs/ (needs matplotlib; see its README)
#
# Other examples:
#   make models                      build C models into model/lib, check v2 vs official KAT
#   make kat SPEC=v2                 generate kat/v2/gen/<set> for every set
#   make sim SPEC=v1 SET=gmu         run LWC_TB on gmu/arch1_v1 with GMU's shipped vectors
#   make sim SIM=ghdl ...            use GHDL instead of Questa (default: questa; source ./setup.sh)

SPEC_DEFAULT := v2
CORE_v1 := gmu/arch1_v1
CORE_v2 := brody/base_r10
ifeq ($(origin CORE),undefined)
CORE := $(CORE_$(if $(SPEC),$(SPEC),$(SPEC_DEFAULT)))
endif
CORE_SPEC := $(if $(filter gmu/%,$(CORE)),v1,v2)
ifneq ($(SPEC),)
ifneq ($(SPEC),$(CORE_SPEC))
$(error CORE=$(CORE) implements spec $(CORE_SPEC), but SPEC=$(SPEC))
endif
endif
SPEC := $(CORE_SPEC)
SET  ?= edge
SIM  ?= questa
WL   ?= long
TESTMODE ?=
VSIM_DO    ?= run -all; quit -f
VSIM_FLAGS ?=

ALGO_v1 := elephant160v1
ALGO_v2 := elephant160v2
ALGO    := $(ALGO_$(SPEC))
ifeq ($(ALGO),)
$(error SPEC must be v1 or v2, got '$(SPEC)')
endif
COREDIR  := rtl/$(CORE)
ifeq ($(wildcard $(COREDIR)/filelist.txt),)
$(error $(COREDIR)/filelist.txt not found (CORE=$(CORE)))
endif

PY       := .venv/bin/python
TOP      := LWC_TB
SRCS     := $(shell cat $(COREDIR)/filelist.txt tb/filelist.txt)
# Mixed-language cores: .vhd files go to vcom (in filelist order), .sv/.v files to vlog afterwards.
# Verilog defines (NAME=VALUE per line, # comments) come from rtl/<CORE>/defines.txt if it exists.
VHDL_SRCS := $(filter %.vhd,$(SRCS))
VLOG_SRCS := $(filter %.sv %.v,$(SRCS))
DEFINES   := $(shell sed 's/\#.*//' $(COREDIR)/defines.txt 2>/dev/null)
VLOG_CMD   = $(if $(VLOG_SRCS),vlog -sv -quiet $(addprefix +define+,$(DEFINES)) $(addprefix $(ABS)/,$(VLOG_SRCS)) &&)
CFG      := $(CORE)
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

.PHONY: help venv models kat sim sim-all cycles profile synth report plots clean

help:
	@sed -n '3,/^SPEC_DEFAULT :=/p' Makefile | grep -v '^SPEC_DEFAULT' | sed 's/^# \{0,1\}//'

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
	@test -z "$(VLOG_SRCS)" || { echo "SIM=ghdl: $(CORE) has Verilog sources; use SIM=questa"; exit 1; }
	@mkdir -p build/ghdl/$(CFG)
	$(GHDL) -a $(GHDLFLAGS) $(SRCS)
	$(GHDL) -e $(GHDLFLAGS) $(TOP)
	cd $(SIMDIR) && $(GHDL) -r $(GHDLFLAGS) $(TOP) \
	  $(addprefix -g,$(TB_GENERICS)) > sim.out 2>&1 || true
else ifeq ($(SIM),questa)
	cd $(SIMDIR) && vlib work >/dev/null && \
	  vcom -2008 -quiet $(addprefix $(ABS)/,$(VHDL_SRCS)) && \
	  $(VLOG_CMD) \
	  vsim -c -quiet $(VSIM_FLAGS) $(addprefix -g,$(TB_GENERICS)) $(TOP) -do "$(VSIM_DO)" > sim.out 2>&1 || true
else
	$(error SIM must be ghdl or questa)
endif
	@scripts/sim_result.sh $(SIMDIR) $(CFG) $(SET)

sim-all:
	@for s in $(SETS); do $(MAKE) --no-print-directory sim CORE=$(CORE) SET=$$s SIM=$(SIM) || exit 1; done

# ---- Benchmarking -----------------------------------------------------------
# Measured cycles from LWC_TB's own timing mode (G_TEST_MODE=4): one row per message in
# build/sim/<sim>/<core>/cycles/timing.csv. v2 cores only (the vector set is v2).
cycles:
	@test "$(SPEC)" = v2 || { echo "make cycles: v2 cores only"; exit 1; }
	@$(MAKE) --no-print-directory sim CORE=$(CORE) SET=cycles TESTMODE=4 SIM=$(SIM)

# Where the cycles go: dumps the core's busy signals (rtl/<core>/profile.txt) and its data
# handshakes to a VCD while running prof_<WL>, then classifies every clock cycle. Questa only.
PROF_DO := $(ABS)/build/prof/$(CORE).do
profile:
	@test "$(SIM)" = questa || { echo "make profile: needs SIM=questa"; exit 1; }
	@test -f $(COREDIR)/profile.txt || { echo "make profile: $(COREDIR)/profile.txt missing (see scripts/profile.py)"; exit 1; }
	@mkdir -p $(dir $(PROF_DO)) && python3 scripts/profile.py do --core $(CORE) --out $(PROF_DO)
	@$(MAKE) --no-print-directory sim CORE=$(CORE) SET=prof_$(WL) SIM=questa \
	  VSIM_FLAGS=-voptargs=+acc VSIM_DO="do $(PROF_DO)"
	@python3 scripts/profile.py parse --core $(CORE) --workload $(WL) \
	  --vcd build/sim/questa/$(CORE)/prof_$(WL)/prof.vcd

# ---- Implementation -------------------------------------------------------
# Needs Vivado on PATH (source ./setup.sh vivado). Prints a line per Vivado run; results go to
# reports/synth_results.csv (one row per synthesis of a core) and reports/synth_runs.csv (every run).
synth:
	python3 scripts/synth.py --core $(CORE) $(if $(PERIOD0),--period0 $(PERIOD0))

# Every v2 core with measured cycles, joined with its latest synthesis, against the baseline brody/base_r10.
report:
	python3 scripts/report.py

# Report graphs (scripts/plot_report.py) from reports/*.csv, the sweep and the profile VCDs.
plots:
	python3 scripts/plot_report.py

clean:
	rm -rf build
