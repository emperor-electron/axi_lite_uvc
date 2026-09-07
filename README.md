# axi_lite_uvc

A reusable UVM verification component for AMBA AXI4-Lite (ARM IHI 0022),
scaffolded with [uvm-tb](../uvm-tb) and built out into a full UVC.

It drives either end of a port, applies programmable backpressure on all five
channels, answers as a slave out of a memory model you can subclass, polices the
protocol with assertions that are themselves tested, and works at any address
width and either legal data width without a single compile-time definition.

- **Drives a DUT's slave port** — an `AXI_LITE_MASTER` agent issues reads and
  writes and takes the responses back.
- **Answers a DUT's master port** — an `AXI_LITE_SLAVE` agent accepts requests
  and answers them out of an `axi_lite_mem`, with programmable latency and
  configurable SLVERR/DECERR regions.
- **Cannot violate the protocol** — the handshake, reset, response-ordering and
  encoding rules are asserted in the interface, and the assertions are proven to
  fire by a negative test (`make check-protocol`).
- **Programmable backpressure, per channel** — six built-in READY models plus a
  policy class to write your own, set independently on AW, W, B, AR and R, and
  swappable while the simulation runs.
- **Parameterizable** — address and data widths are SystemVerilog parameters, so
  five differently sized ports elaborate into one snapshot and are all exercised
  by one `make` run.
- **One interface file, synthesizable too** — the clocking blocks, assertions
  and configuration API sit behind `` `ifdef AXI_LITE_IF_SIM ``, so the same
  `axi_lite_if.sv` is both the UVC's virtual interface and an interface you can
  instantiate in RTL.

Only XSIM (Vivado 2023.2) has been used so far; see
[Simulator notes](#simulator-notes) for the three XSIM bugs this code works
around.

> **Full documentation is in [`docs/`](docs).** Start at
> [docs/README.md](docs/README.md) for the index, or go straight to
> [Getting started](docs/getting-started.md) to wire the UVC into your own
> testbench. The rest of this file is a condensed overview of the same material.

## Using it in your project

The fastest way in is [`example/`](example) — a complete, runnable testbench
around a small AXI4-Lite register file, written to be read. `example_tb_top.sv`
and `example_base_test.sv` carry numbered comments walking through connecting
the UVC and configuring it; copy the pair and swap in your own design.

```bash
cd example && make
```

The rest of this section is the same material in prose.

```bash
export AXI_LITE_UVC_ROOT=/path/to/axi_lite
```

```bash
xvlog -sv -L uvm -f $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f -f my_tb.f
```

That filelist is the entire component: `axi_lite_if.sv` and `axi_lite_pkg.sv`.
Nothing else in this repository is needed, and the UVC depends on nothing but
UVM.

Instantiate an interface per port and hand it to an agent of matching width:

```systemverilog
// In the testbench top -- widths are parameters, so as many differently
// sized ports as you like can coexist in one compilation.
axi_lite_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) axil (.aclk(aclk), .aresetn(aresetn));

my_peripheral u_dut (.aclk, .aresetn,
                     .s_axil_awvalid(axil.awvalid), .s_axil_awready(axil.awready),
                     .s_axil_awaddr (axil.awaddr),  .s_axil_awprot (axil.awprot), ...);

initial
  uvm_config_db#(virtual axi_lite_if #(12, 32))::set(
      null, "uvm_test_top.env.master_agent", "vif", axil);
```

```systemverilog
// In the env -- one agent, parameterized to match the interface.
axi_lite_agent #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) master_agent;

function void build_phase(uvm_phase phase);
  axi_lite_config agent_config = axi_lite_config::type_id::create("agent_config");
  agent_config.role = AXI_LITE_MASTER;              // issue transactions into the DUT
  agent_config.set_addr_window(12'h000, 12'h03F);   // the aperture it decodes
  agent_config.set_addr_delay(0, 3);                // 0-3 idle cycles before each address
  uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", agent_config);
  master_agent = axi_lite_agent #(12, 32)::type_id::create("master_agent", this);
endfunction
```

```systemverilog
// In a test -- sequences are unparameterized, so this is the same code
// whatever the port's widths are.
axi_lite_random_seq random_sequence =
    axi_lite_random_seq::type_id::create("random_sequence");
assert (random_sequence.randomize() with { num_transactions == 40; });
random_sequence.start(master_agent.sequencer);
```

The agent reconciles `agent_config` with its own parameters at build time, so a
config that disagrees with the interface it is attached to is reported rather
than silently truncating addresses.

## How it is put together

The one design decision everything else follows from: **only the four classes
that touch a virtual interface are parameterized.**

`virtual axi_lite_if #(12,32)` and `#(32,64)` are different SystemVerilog types,
so anything holding one has to be parameterized too. That is unavoidable for the
drivers, the monitor and the agent that holds them — and stops there:

| Parameterized by port width | Not parameterized |
| --- | --- |
| `axi_lite_master_driver` | `axi_lite_seq_item` |
| `axi_lite_slave_driver` | `axi_lite_config`, `axi_lite_ready_policy` |
| `axi_lite_monitor` | `axi_lite_mem` |
| `axi_lite_agent` (holds the above) | `axi_lite_sequencer`, the whole sequence library |
|  | `axi_lite_coverage` |

AXI4-Lite fixes the data bus at 32 or 64 bits and the address at no more than
64, so the transaction carries address and data as **vectors of those maxima**,
masked down to the port's real width. That is what keeps it unparameterized, and
it is why one sequence library, one scoreboard and one coverage model serve every
port: a 32-bit access and a 64-bit access are the same type.

`tb/axi_lite_env.sv` shows the pattern for a testbench holding several port
widths at once — an unparameterized `axi_lite_env_base` holding everything a test
touches, and a parameterized `axi_lite_env #(...)` that adds the agents and
publishes its sequencer up into the base. A test can then keep
`axi_lite_env_base envs[$]` containing a 12-bit and a 64-bit port side by side
and start the same sequence on both.

### What makes AXI4-Lite different from a stream

Two things, and they shape most of the code.

**Five independent channels.** AW, W, B, AR and R each have their own handshake
and run at their own pace. The master driver therefore has a thread per channel
plus one taking transactions off the sequencer, rather than one sequential task —
writing it sequentially would silently impose an ordering the protocol does not
have, most importantly making W always follow AW when AXI explicitly permits the
write data to arrive first. For the same reason the monitor samples all five
channels in *one* ordered loop: a write whose AWVALID, WVALID and BVALID all
handshake on the same edge is legal, and a thread per channel would let the
response be processed before the request that explains it.

**A slave has to answer.** A stream sink only decides TREADY; an AXI4-Lite slave
has to produce data and a response, and a read after a write to the same address
has to return what was written. That is what `axi_lite_mem` is for, and it has no
counterpart in a stream UVC.

### One file for simulation and synthesis

`axi_lite_if.sv` is meant to be the only AXI4-Lite interface in your project —
the UVC's virtual interface *and* the interface you wire up inside a design.
Everything a synthesis tool would reject (clocking blocks, assertions, the
handshake counters, the string and `%m` reporting helpers) is inside
`` `ifdef AXI_LITE_IF_SIM ``; what remains is the signal set and two
synthesizable modports:

```systemverilog
axi_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cfg (.aclk(clk), .aresetn(rstn));
my_cpu    u_cpu  (.m_axil(cfg.dut_master));
my_periph u_regs (.s_axil(cfg.dut_slave));
```

That macro is set automatically from `XILINX_SIMULATOR`, which xvlog and xelab
predefine and Vivado synthesis does not — so neither flow needs anything on the
command line. On a simulator that does not define it, pass
`+define+AXI_LITE_IF_SIM`.

Verified both ways: `synth_design` for an `xc7z045` accepts a design
instantiating the interface through both modports with 0 errors and 0 critical
warnings, and forcing `AXI_LITE_IF_SIM` on during synthesis makes it fail — so
the guard is known to be load-bearing rather than merely present.

New coverpoints or formal properties belong inside that guard too.

### Naming

Class handles are spelled out: `master_driver`, not `mst_drv`; `monitor`, not
`mon`; `sequencer`, `coverage`, `scoreboard`, `master_agent`. Two names cannot
be, because SystemVerilog reserves them:

| Wanted | Reserved by | Used instead |
| --- | --- | --- |
| `config` | `config` / `endconfig` | `agent_config`, `master_config`, `slave_config` |
| `sequence` | assertion sequences | `random_sequence`, `write_sequence`, `directed_sequence` |

Virtual-interface handles stay `vif` / `vif_src` / `vif_snk`: an interface is not
a class, and `vif` is near-universal in UVM.

Config-DB field names track the handles they fill, so the key is
`"agent_config"`, not `"cfg"`.

## Backpressure

READY has no protocol restrictions of its own, so every model here is legal by
construction. A driver asks its policy for the *next* cycle's READY once per ACLK
edge, before this cycle's VALID can influence it — which makes it structurally
impossible for a model to create a combinational READY-from-VALID path and hide a
deadlock real hardware would hit.

Because AXI4-Lite has five channels, backpressure is configured per channel. Which
ones an agent actually drives follows from its role:

| Role | Drives READY on | Meaning |
| --- | --- | --- |
| `AXI_LITE_MASTER` | B, R | how fast it accepts responses |
| `AXI_LITE_SLAVE` | AW, W, AR | how fast it accepts requests |

```systemverilog
slave_config.set_ready_mode(AXI_LITE_CH_AW, AXI_LITE_READY_BURST,
                            .burst_beats(8), .stall_cycles(3));
master_config.set_ready_mode_all(AXI_LITE_READY_RANDOM, .percent(60));
```

| Mode | Behaviour |
| --- | --- |
| `AXI_LITE_READY_ALWAYS` | READY tied high; no backpressure |
| `AXI_LITE_READY_NEVER` | READY tied low; the channel never accepts |
| `AXI_LITE_READY_RANDOM` | per-cycle coin flip at `ready_percent` |
| `AXI_LITE_READY_DUTY` | square wave: `ready_cycles` high, `stall_cycles` low |
| `AXI_LITE_READY_BURST` | accept `burst_beats` *transfers*, then stall `stall_cycles` |
| `AXI_LITE_READY_DELAY` | hold off `delay_min..delay_max` cycles after VALID |

Measured READY duty cycles from one `axi_lite_backpressure_test` run, which is
how you can tell the models do what they claim — the slave driver reports its own
per-channel census at the end of every run:

```
AXI_LITE_READY_ALWAYS             AW 367/368 (99%)  W 367/368 (99%)  AR 367/368 (99%)
AXI_LITE_READY_RANDOM(30%)        AW 107/368 (29%)  W 100/368 (27%)  AR  99/368 (26%)
AXI_LITE_READY_DUTY(1 on/3 off)   AW  92/368 (25%)  W  92/368 (25%)  AR  92/368 (25%)
AXI_LITE_READY_BURST(4/6 stall)   AW 355/368 (96%)  W 355/368 (96%)  AR 355/368 (96%)
AXI_LITE_READY_DELAY(0..8)        AW   9/368 ( 2%)  W  84/368 (22%)  AR  11/368 ( 2%)
```

`BURST` reads high because it counts *accepted transfers*, not cycles: with only
20 transactions on the port it rarely reaches four in a burst, so it spends most
of its time open. That is the model behaving correctly, and it is the reason the
census is worth printing — an aggregate number is only interpretable next to the
model that produced it.

For anything these do not cover — a recorded trace, a credit counter,
backpressure on writes only — extend `axi_lite_ready_policy`, override
`next_ready()`, and hand it to `axi_lite_config::set_ready_policy()`. The policy
class is deliberately unparameterized, so one custom model works against every
port in the testbench, and the drivers re-read the handle every cycle so a test
can swap models mid-run:

```systemverilog
env.set_backpressure_all(AXI_LITE_READY_NEVER);   // jam the port solid
// ...
env.set_backpressure_all(AXI_LITE_READY_ALWAYS);  // and let it drain
```

Master-side pacing is the counterpart: each transaction's `addr_delay` and
`wdata_delay` are idle cycles inserted before the address phase and the write
data phase, drawn from the config's windows. They are **independent**, which is
what lets W lead AW — legal AXI4-Lite, and a case plenty of slaves get wrong.
Leaving both at 0 issues back-to-back at full rate.

`axi_lite_config::max_outstanding` caps how many transactions the master keeps in
flight. At its default of 1 each completes before the next is issued, which is
what most AXI4-Lite peripherals expect and what makes a scoreboard's job
unambiguous. Raise it — and clear a sequence's `blocking` flag so it runs ahead —
to exercise a slave that claims to pipeline.

## The slave model

An `AXI_LITE_SLAVE` agent answers out of an `axi_lite_mem`: a sparse,
byte-granular store plus a response policy.

```systemverilog
axi_lite_mem mem = axi_lite_mem::type_id::create("mem");
mem.fill_from_address = 1'b1;                       // untouched bytes read back as f(address)
mem.add_region(32'h1000, 32'h1FFF, AXI_LITE_SLVERR, "reserved");
mem.add_region(32'h2000, 32'hFFFF, AXI_LITE_DECERR, "unmapped");
slave_config.mem = mem;
```

Storage is bytes, not words, and that one choice is what keeps the class
unparameterized: WSTRB is a per-byte enable so it applies directly, a 32-bit port
and a 64-bit port index the same array, and only the addresses actually touched
cost anything.

`fill_from_address` is worth knowing about. Left off, an unwritten location reads
back as zero; switched on it reads back as a function of its own address, which
turns an address-decode bug into a data mismatch the *first* time that location is
read rather than only after something has been written there.

For a peripheral with real behaviour, subclass it —
`resp_for_read`/`resp_for_write` and `do_read`/`do_write` are all virtual, so a
register with side effects is an override rather than a rewrite.

## Protocol checks

`axi_lite_if.sv` carries 49 assertions (the WDATA X-check replicated per byte
lane) covering the handshake rules (§A3.2), the channel dependencies (§A3.3),
response encodings and the AXI4-Lite subset restrictions (§B1.1), reset behaviour
(§A3.1.2) and X-propagation. They are plain SystemVerilog with no UVM in them:
each failure bumps `protocol_error_count`, and the monitor's `check_phase` turns a
non-zero count into a `UVM_ERROR` so violations fail the test rather than
scrolling past in a log. That also means the interface is usable in a non-UVM
testbench.

They police the DUT and the UVC equally — whichever side drives the signal that
breaks a rule is the side the failure points at.

Four things are worth knowing about how they are written:

- **Every VALID must be low during reset** is qualified on reset having already
  been low at the previous edge, giving a synchronous driver one ACLK edge to
  react to an asynchronously asserted reset — the same cycle a real sync-reset
  flop takes. A driver that keeps offering a transfer *through* reset still fails.
- **Response ordering is checked by counting handshakes**, not by tracking
  transactions: the Nth B may not complete before the Nth AW and the Nth W have.
  The current cycle's own handshake counts, so a slave that accepts an address,
  its data and answers in one cycle is allowed — what is caught is a response for
  a transaction that was never requested.
- **WDATA is only X-checked on lanes WSTRB enables**, because AXI leaves a
  disabled lane's write data explicitly undefined. `make check-protocol` includes
  a scenario proving an X in a disabled lane stays quiet.
- **Address alignment and the EXOKAY ban are switchable** (`check_addr_alignment`,
  `check_exokay`), because a design that decodes sub-word addresses is a real
  thing even though AXI4-Lite does not describe one.

## Running the self-test

```bash
cd tb && make regress
```

Needs Vivado on the machine (the Makefile sources `settings64.sh` itself);
override with `make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ...`.

| Target | What it does |
| --- | --- |
| `make` | compile, elaborate, run `axi_lite_multiwidth_test` to completion |
| `make regress` | the protocol-checker test, then every test below |
| `make check-protocol` | negative test: break each rule, require it to be caught |
| `make TEST=<name>` | one test |
| `make waves` | open the waveforms in Vivado, simulating first if there are none |
| `make gui` | run interactively in the XSIM GUI |

| Test | What it covers |
| --- | --- |
| `axi_lite_smoke_test` | full-rate traffic, no backpressure |
| `axi_lite_multiwidth_test` | all five ports, a separately drawn READY model per channel |
| `axi_lite_backpressure_test` | every built-in ready model, one per port |
| `axi_lite_no_ready_test` | every request channel held closed for 300 cycles, then released |
| `axi_lite_sweep_test` | walk every location of every window, write and read back |
| `axi_lite_error_resp_test` | SLVERR and DECERR regions in the slave model |
| `axi_lite_pipelined_test` | four transactions in flight against a slow slave |
| `axi_lite_reset_test` | ARESETn pulsed mid-traffic, then recovery |

Both directories are `uvm-tb` testbenches, not just Makefiles that happen to
look like one, so the GUI drives them too:

```bash
uvm-tb gui tb
```

It discovers the tests by following the inheritance chain with verible — all
eight self-test tests and all five example tests show up — and shells out to the
same Makefile, so the CLI and the GUI always agree on what counts as a failure.

### Waveforms

`make waves` opens `waves.wdb` in the Vivado window. `waves.wdb` is a real file
target, so the recipe that produces it runs only when it is missing: the first
call simulates and then opens, and every later call opens straight away. Delete
the database (or `make clean`) to force a fresh capture — worth remembering after
editing the design, since make cannot tell that an existing database has gone
stale.

A failing test still opens its waveforms, which is the point of the target;
`make` / `make run` / `make regress` remain the pass/fail gates, and `make waves`
prints a note when the run it is showing you failed.

Arrange the waveform how you like and save it from the GUI as
`axi_lite_tb_top.wcfg` — `<TOP>.wcfg` is what the GUI offers by default — and
every later `make waves` reopens with it via `--view`, so the layout survives
re-running the simulation. `waves.wcfg` is accepted as a fallback name,
`WAVE_CFG=` overrides both, and `make clean` deliberately does not delete
`*.wcfg`: a hand-made arrangement is not a build artifact.

### The five parameter combinations

`axi_lite_tb_top.sv` instantiates all of these at once. They are module and class
parameters — **not** `` `define ``s — so one compilation and one simulation covers
the lot, rather than five recompiles with a different macro each time.

| Env | ADDR | DATA | Why it is in the list |
| --- | --- | --- | --- |
| `env_a32d32` | 32 | 32 | the common case |
| `env_a32d64` | 32 | 64 | the other data width AXI4-Lite allows |
| `env_a64d64` | 64 | 64 | full 64-bit addressing |
| `env_a12d32` | 12 | 32 | a peripheral's own 4 KB aperture |
| `env_a16d64` | 16 | 64 | a 64 KB window on a wide bus |

AXI4-Lite fixes the data bus at 32 or 64 bits, so unlike a stream UVC there is no
long tail of widths to sweep — the axis that actually varies from design to design
is the *address*, which is why three of the five differ only there. A 12-bit
aperture is in the list on purpose: it is the case where an address window a test
asks for can exceed what the bus can address, which is what the agent's geometry
reconciliation exists to catch.

Each port is a master agent driving a register slice, a slave agent answering its
far side out of a memory model, and a scoreboard requiring every request, every
response and every byte of read data to come back unchanged and in order.

### What a passing run has established

All eight tests pass on five seeds (1, 7, 42, 12345, 99999), with zero protocol
assertion failures across all ten interfaces, and `make check-protocol` reports
17 of 17 scenarios behaving correctly — so the assertions above are known to be
alive rather than merely silent.

The example's five tests pass on three seeds as well, which is a different claim
and worth making separately: the self-test's DUT passes transactions through, so
it can only show that the UVC does not corrupt them. The example's DUT has
behaviour — a read-only register, byte-strobed writes, an unmapped region that
answers DECERR — so a run of it shows the UVC is usable against something that
answers back.

Two things this does *not* establish, and it is worth being plain about them:
the coverage model is sampled on every run but no closure target has been set
against it, and only XSIM has been used, so the SystemVerilog here is known to be
accepted by exactly one tool.

## Repository layout

```
src/                        the reusable UVC -- this is what other projects compile
  axi_lite_if.sv              parameterized interface, clocking blocks, assertions
  axi_lite_pkg.sv             the package; includes everything below
  axi_lite_types.sv           enums, typedefs, capacity constants
  axi_lite_ready_policy.sv    per-channel backpressure contract + built-in models
  axi_lite_mem.sv             the slave agent's memory and response model
  axi_lite_config.sv          role, geometry, address window, pacing, backpressure
  axi_lite_seq_item.sv        one whole transaction, read or write
  axi_lite_sequencer.sv       unparameterized
  axi_lite_master_driver.sv   issues AW/W/AR, takes B/R back
  axi_lite_slave_driver.sv    accepts AW/W/AR, answers B/R from the memory model
  axi_lite_monitor.sv         request and completed-transaction analysis ports
  axi_lite_coverage.sv        kind, response, strobe, protection, latency, stall
  axi_lite_agent.sv           where parameterized meets unparameterized
  axi_lite_seq_lib.sv         write / read / write-read / sweep / random
  axi_lite_uvc.f              drop this into another testbench's compile

example/                    a runnable integration example, written to be read
  example_tb_top.sv           STEP 1-5: interface, DUT wiring, config DB
  example_base_test.sv        STEP 1-4: config, backpressure, stimulus
  example_env.sv              STEP 1-4: the agent and the analysis port
  example_scoreboard.sv       a model of the DUT's register map
  example_tb_pkg.sv           the widths and the register map, written down once
  example_dut.sv              a register file, so there is something to model
  Makefile filelist.f wave.tcl

tb/                         self-test; no consuming project needs any of it
  axi_lite_chan_fifo.sv       a protocol-correct buffer for one channel
  axi_lite_reg_slice.sv       five of those: a slave port in, a master port out
  axi_lite_tb_ctrl_if.sv      sole owner of ARESETn; lets a test pulse reset
  axi_lite_link.sv            one link: two interfaces + a register slice
  axi_lite_env.sv             parameterized env + unparameterized base
  axi_lite_scoreboard.sv      request, response and read-data checks
  axi_lite_test_lib.sv        the eight tests
  axi_lite_if_check_tb.sv     negative test for the assertions (no UVM)
  axi_lite_tb_top.sv          five ports, one simulation
  Makefile filelist.f wave.tcl
```

## Simulator notes

XSIM 2023.2 needed three workarounds. All three fail silently, misleadingly, or
by crashing the tool rather than producing a useful error, so they are called out
here and commented at the source:

- **`enum.name().substr(...)` inside an enum-iteration loop segfaults the
  elaborator.** Not an error message — `xelab` dies with SIGSEGV part-way through
  compiling the package. Either construct alone is fine; walking an enum with
  `first()`/`next()`/`last()` while calling `.substr()` on `name()` in the same
  loop is what kills it. `axi_lite_short_name()` in `axi_lite_types.sv` takes the
  name as a string argument instead, which materialises it into a formal first.
- **A conditional expression yielding an enum is evaluated wrongly inside a
  `randomize() with` clause.** `kind == (is_read ? AXI_LITE_READ : AXI_LITE_WRITE)`
  solved the read case to `WRITE` and declared the write case unsatisfiable. The
  choice is made in procedural code into a variable of the enum's own type, and
  the constraint compares against that.
- **Masking a 64-bit rand field by constraint either fails or collapses.**
  `(wdata & ~data_mask) == 0` makes a 32-bit write unsatisfiable even though
  zeroing the top half plainly satisfies it; rewriting it as
  `(wdata >> data_width) == 0` does solve, but the solver then returns `wdata == 0`
  on *every* draw — stimulus that looks healthy and carries no data. Neither
  failure appears on a 64-bit bus, where the mask is all ones and the constraint
  is vacuous, so it would have gone unnoticed on the widest port and quietly
  broken the narrow ones. `axi_lite_seq_item::post_randomize()` trims the field
  afterwards instead, which is what the driver would do to those bits anyway.

The Makefile is structured with a `SIM` variable and an `ifeq` block per
simulator, so Questa/VCS/Xcelium can be added without touching the rest of it.
