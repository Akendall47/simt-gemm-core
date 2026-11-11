# SIMT GEMM Core

A GPU-style SIMT core in SystemVerilog that runs INT8 matrix multiply (GEMM), built to measure
latency hiding with warps, vector vs matrix instructions, and SIMT vs SIMD.

A self-directed extension of my Advanced Computer Architecture (ACA) module at Imperial:
taking the ideas from the course into GPU territory, on my own terms.

ACA is mostly about making one thread fast. Out-of-order execution, caches and branch prediction
all exist to hide latency, and in the coursework I explored that design space with gem5 and McPAT.
GPUs take the opposite bet: run many threads, and when one stalls on memory, switch to another.
I wanted to build that alternative myself and measure it with the same discipline as the
coursework, through parameter sweeps, utilisation and clear plots.

The core is a small GPU-style SIMT core in SystemVerilog that runs AI kernels. It uses warps to
hide memory latency, and an INT8 dot-product instruction inside each lane, the same operation as
Arm's `SDOT`. That last part follows where mobile GPUs are heading: Arm's Mali G2-Ultra NX
(Sep 2026) puts neural accelerators inside the shader cores.

| From the course | Where it goes in this project |
| --- | --- |
| Memory latency and caches | The thing being hidden: a C++ memory model with configurable latency |
| Out-of-order execution hiding stalls | Replaced by warp switching: the GPU's answer to the same problem |
| Vector and SIMD processing | Lanes executing in lockstep, and the `DOT4` instruction |
| Design-space exploration (gem5, McPAT coursework) | Sweeping warps against memory latency and measuring utilisation |
| Benchmarking methodology | Fixed kernels (`vadd`, INT8 GEMM), golden models, repeatable runs |

## Questions

**v1 (the main project):**

1. **Latency hiding (SIMT).** How many resident warps does it take to keep the dot-product unit
   busy at a given memory latency?

**Next, each small and on the same GEMM:**

2. **Vector vs matrix.** `DOT4` gives 4 multiply-adds from 8 inputs; an outer product (`MOPA`)
   gives 16 from 8. How much faster is GEMM, and how many fewer register reads per multiply-add?
   (The idea behind Arm SME2 and GPU tensor cores.)
3. **SIMT vs SIMD.** Per-thread loads (each lane computes its own address) vs one vector load
   (`LDV`) from a single base address. How many memory requests and cycles does each take?

**Extensions, only if there's time:** tiling into on-chip memory with a roofline plot; divergence
using the Mandelbrot maths from PYNQZOOM.

Every milestone ends with a number in `results/`, not just a working waveform.

## Architecture (v1)

```
            +------------------ SIMT GEMM Core -----------------+
 program -> | fetch -> decode -> warp scheduler -> issue        |
  memory    |       ^                                           |
            |       | block dispatcher: next block to a free warp|
            |   per-warp state: PC, block id, waiting flag      |
            |                        v                          |
            |   4 lanes:  regfile | ALU | DOT4                  |
            |                        |                          |
            |   load/store unit                                 |
            +------------------------|--------------------------+
                                     v  valid/ready req/resp
                          global memory model (C++, Verilator)
                          configurable latency, counts requests and bytes
```

| Parameter | v1 |
| --- | --- |
| `LANES` (threads per warp) | 4, fixed |
| `WARPS` (resident warps) | 1, 2 or 4 (the experiment) |
| Registers per lane | 16 x 32-bit |
| Global memory latency (C++ model) | swept: 5, 20, 50 cycles |

**Execution model.** All 4 lanes of a warp execute the same instruction (SIMT). The harness
launches a kernel as a grid of blocks; each block is one warp's worth of work. When a warp hits
`HALT`, the dispatcher gives it the next block. When a warp issues a load it waits, and the
scheduler issues from another ready warp (round-robin). That switch is the latency hiding being
measured.

**Deliberate v1 simplifications:**
- **No branches.** Kernels are short straight-line code; the grid of blocks replaces loops.
- **Not pipelined.** Each instruction finishes before the next issues; only loads take multiple
  cycles, which is all the experiment needs.
- **No assembler.** Kernels are built in C++ with encode functions (`enc_add(rd, rs1, rs2)` returns
  the 32-bit instruction word).

**Global memory lives in C++.** The RTL talks to it over a valid/ready request and response
interface. The C++ model adds latency and counts requests and bytes, so traffic is measured exactly.

## ISA (32-bit instructions)

Encoding: `[31:26] opcode | [25:22] rd | [21:18] rs1 | [17:14] rs2 | [13:0] imm14` (signed).
`LI` has no source registers, so it takes a wider signed `imm18` in `[17:0]`.

**v1: 8 instructions**

| Mnemonic | Meaning |
| --- | --- |
| `LI rd, imm` | load sign-extended imm18 |
| `ADD rd, rs1, rs2` | integer add |
| `ADDI rd, rs1, imm` | add sign-extended imm14 |
| `S2R rd, sreg` | read special register: lane id, warp id, block id |
| `LD rd, imm(rs1)` | load a 32-bit word from global memory (address per lane) |
| `ST rs2, imm(rs1)` | store a 32-bit word to global memory (address per lane) |
| `DOT4 rd, rs1, rs2` | rd += sum of 4 signed INT8 x INT8 products (like Arm `SDOT`) |
| `HALT` | block finished; warp is free for the next block |

**Next:** `MOPA` (4x4 INT8 outer product into a per-warp INT32 accumulator tile, plus a way to
store the tile) and `LDV` (one vector load for the whole warp from a single base address).
Extensions would add `LDS/STS`, `BRA/BRANY`, `MASKNZ/MASKALL` and `MULQ`.

## Kernels

| Kernel | What it shows |
| --- | --- |
| `vadd` | first end-to-end test: lanes, loads, stores |
| `gemm_dot4` | 8x8x8 INT8 GEMM: 16 blocks, each warp computes 4 outputs with `DOT4` |
| `gemm_mopa` (next) | same GEMM with the outer-product instruction |
| `gemm_ldv` (next) | same GEMM with vector loads instead of per-lane loads |

Store B transposed so each `LD` brings four consecutive INT8 values for `DOT4`.

## Milestones (small steps)

Each step is 1 to 2 hours, ends with one new passing testbench, and is one commit. Every testbench in
`tb/` runs on each push (`make test` locally, GitHub Actions in CI), so the green ticks build up as the
core does. Everything runs in simulation (Verilator); no FPGA needed.

| Step | Build | Done when |
| --- | --- | --- |
| 0 | Setup: repo, CI, `make tools` | CI is green with zero testbenches |
| 1 | `core_pkg.sv`: opcodes, field widths, parameters; matching C++ encode header | `sw/tests/encode_test.cpp`: encode then decode every v1 instruction round-trips |
| 2 | Register file, one lane: 16 x 32-bit, 2 read ports, 1 write port | `regfile_tb`: random writes and reads match a C++ array |
| 3 | ALU: `ADD`, `ADDI`, `LI` | `alu_tb`: 1,000 random cases match C++ |
| 4 | `DOT4` unit: 4 signed INT8 products summed into INT32 | `dot4_tb`: random and edge cases (-128 x -128) match C++ |
| 5 | Decoder: instruction word to control signals | `decoder_tb`: each v1 instruction decodes correctly |
| 6 | Core, one lane: program memory, fetch, decode, execute `LI ADD ADDI HALT` | `core_tb`: a 5-instruction program leaves the right registers |
| 7 | Four lanes plus `S2R` (lane id) | each lane holds its own result after `S2R` and `ADD` |
| 8 | C++ memory model: valid/ready, configurable latency, request counter | memory test passes; handshake assertion never fires |
| 9 | `LD` and `ST` in the core; core waits on loads | `vadd` matches the golden model |
| 10 | `DOT4` in the core | one block of `gemm_dot4` (4 outputs) matches |
| 11 | Block dispatcher: grid of blocks, block id via `S2R` | full 8x8 `gemm_dot4` (16 blocks) matches; cycle count printed |
| 12 | Second warp and round-robin scheduler; switch while a warp waits on a load | same GEMM still matches, with fewer cycles |
| 13 | `WARPS` parameter (1/2/4); sweep script writes CSV; plot | headline plot in `results/` and README |

**v1 total: about 17 to 21 hours.** Estimates are rough; steps 8 and 9 (memory and stalls) usually
take longest.

**Next (same small-step style):**

| Step | Build | Done when |
| --- | --- | --- |
| 14 | Per-warp 4x4 INT32 accumulator tile and `MOPA` | unit test of one outer product matches C++ |
| 15 | Tile store instruction and `gemm_mopa` | GEMM matches; compare cycles and register reads with `gemm_dot4` |
| 16 | `LDV` vector load (one request for the warp) | `gemm_ldv` matches; compare request counts with per-lane loads |

Run `make synth` on each new module to watch the hardware cost grow. Optional at the very end:
Vivado implementation for the PYNQ-Z1's Zynq part to get a real fmax (no board needed for that either).

## Verification

- **Golden models (C++):** every kernel has a plain C++ reference; output memory must match bit for bit.
- **Testbench rule:** each `tb/<top>_tb.cpp` returns 0 on pass and non-zero on failure, so `make test`
  and CI can run them all.
- **SystemVerilog assertions:** valid/ready payload stable until accepted; at most one warp issues per
  cycle; PC stays inside program memory; a waiting warp never issues.

## Repo layout

```
rtl/        SystemVerilog: *_pkg.sv for shared types, then one module per file
tb/         C++ Verilator harnesses, one per top module (<top>_tb.cpp)
sw/         C++ encode helpers and golden models; sw/tests/ for pure C++ tests
kernels/    kernels written as C++ (lists of encoded instructions)
results/    CSVs and plots produced by runs
```

## Tools

All free, all running on a laptop. No FPGA board needed.

| Tool | Used for | Industry equivalent |
| --- | --- | --- |
| Verilator | simulation: compiles the RTL to C++, runs assertions | commercial simulators (Synopsys VCS, Cadence Xcelium, Siemens Questa) |
| C++ harnesses and golden models | stimulus, checking, statistics | SystemVerilog/UVM testbenches |
| Yosys (`make synth`) | synthesis for a Xilinx 7-series target: LUT, flip-flop, DSP counts | Synopsys Design Compiler / Cadence Genus, or Vivado for FPGAs |
| GitHub Actions | runs `make test` on every push | regression farms |

Optional later: SymbiYosys (in YosysHQ's OSS CAD Suite) to formally prove a few assertions; EDA
Playground to try a testbench on a commercial simulator.

**RTL rules so both Verilator and Yosys accept the code:**
- Refer to package items explicitly (`core_pkg::OP_ADD`); don't use `import core_pkg::*`.
  Yosys's built-in parser doesn't accept package imports.
- Wrap concurrent assertions in `` `ifndef SYNTHESIS ... `endif ``. Yosys skips them; Verilator runs them.

## Build

Needs Verilator 5.x and a C++ compiler (g++ or clang++); Yosys for `make synth`.

```
make tools                 # print tool versions
make lint TOP=<module>     # Verilator lint only
make sim  TOP=<module>     # build and run build/<module>/V<module>, with assertions and VCD tracing
make synth TOP=<module>    # Yosys synthesis; LUT/FF/DSP counts in build/<module>_synth.txt
make test                  # run every sw/tests/*_test.cpp and tb/*_tb.cpp; fails if any fails
make clean
```

## How I'm building this

Step by step, by hand, one milestone at a time, with each module tested before the next one starts.
