# SIMT GEMM Core build: Verilator + C++ harness, Yosys synthesis
#   make lint TOP=<module>   lint only
#   make sim  TOP=<module>   build and run tb/<module>_tb.cpp against rtl/
#   make test                run every sw/tests/*_test.cpp and tb/*_tb.cpp
#   make synth TOP=<module>  Yosys synthesis for a Xilinx 7-series target; prints cell counts
#   make clean

TOP   ?= core
ARGS  ?=

# Packages first (Verilator needs them before the modules that import them)
PKGS  := $(sort $(wildcard rtl/*_pkg.sv))
MODS  := $(filter-out $(PKGS),$(sort $(wildcard rtl/*.sv)))
RTL   := $(PKGS) $(MODS)
TB    := tb/$(TOP)_tb.cpp
BUILD := build/$(TOP)
BIN   := $(BUILD)/V$(TOP)

VFLAGS := -Wall --assert --trace -Irtl --top-module $(TOP)

.PHONY: tools lint sim test synth clean

SYNTH ?= synth_xilinx

# Every testbench in tb/ (tb/<top>_tb.cpp) is a test
TOPS := $(patsubst tb/%_tb.cpp,%,$(wildcard tb/*_tb.cpp))
# Pure C++ tests (no RTL): sw/tests/<name>_test.cpp
SWTESTS := $(wildcard sw/tests/*_test.cpp)

tools:
	@verilator --version
	@yosys -V || echo "yosys not installed (only needed for make synth)"
	@$(CXX) --version | head -n 1

lint:
	verilator --lint-only $(VFLAGS) $(RTL)

$(BIN): $(RTL) $(TB)
	@mkdir -p $(BUILD)
	verilator --cc --exe --build -j 0 $(VFLAGS) -Mdir $(BUILD) -o V$(TOP) \
		$(RTL) $(abspath $(TB))

sim: $(BIN)
	./$(BIN) $(ARGS)

test:
	@set -e; mkdir -p build/sw; \
	for s in $(SWTESTS); do n=$$(basename $$s .cpp); echo "== $$n"; \
		$(CXX) -std=c++17 -Wall -Isw -o build/sw/$$n $$s && ./build/sw/$$n; done; \
	for t in $(TOPS); do echo "== $$t"; $(MAKE) --no-print-directory sim TOP=$$t; done; \
	echo "$(words $(SWTESTS)) C++ test(s) and $(words $(TOPS)) testbench(es) passed"

synth:
	@mkdir -p build
	yosys -q -p "read_verilog -sv $(RTL); $(SYNTH) -top $(TOP); tee -o build/$(TOP)_synth.txt stat"
	@grep -E "Number of cells|LUT[0-9]|FD[A-Z]+|CARRY4|DSP48|RAMB" build/$(TOP)_synth.txt

clean:
	rm -rf build
