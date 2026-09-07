# AXI4-Lite UVC

A reusable UVM verification component for AMBA AXI4-Lite (ARM IHI 0022).

It drives either end of an AXI4-Lite port, applies programmable backpressure on
all five channels independently, answers as a slave out of a memory model you
can subclass, and polices the protocol with 49 assertions — which are themselves
put under test by a negative testbench that commits deliberate violations and
requires each one to be caught.

Address and data widths are SystemVerilog parameters, so a 12-bit peripheral
port and a 64-bit host port can live in the same simulation and be driven by the
same sequences.

The interface is one file that is both the UVC's virtual interface and a
synthesizable interface you can instantiate inside your design — there is no
second "verification interface" to keep in step.

## Start here

```bash
cd example && make
```

That builds and runs a complete testbench around a small AXI4-Lite register
file. It is the shortest path from "I have this repo" to "I have seen it work".

Then read, in order:

| Document | What it covers |
| --- | --- |
| **[Getting started](getting-started.md)** | Wiring the UVC into your own testbench: the top module, the env, the test, and the one type mismatch that catches everyone. |
| **[Features](features.md)** | What the UVC actually gives you, and why each piece is shaped the way it is. |
| **[Configuration](configuration.md)** | `axi_lite_config` field by field — role, geometry, address window, pacing, backpressure, the slave model. |
| **[Stimulus](stimulus.md)** | The transaction, the sequence library, and how to write sequences of your own. |
| **[Checks and coverage](checks-and-coverage.md)** | The protocol assertions, the monitor's two analysis ports, and the functional coverage model. |
| **[Troubleshooting](troubleshooting.md)** | Every failure mode with a non-obvious cause, including the XSIM miscompilations this code works around. |

## The shape of it in three snippets

**In the testbench top** — instantiate one interface per AXI4-Lite port, wire it
to the DUT, and publish it:

```systemverilog
axi_lite_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) axil (.aclk(aclk), .aresetn(aresetn));

my_peripheral u_dut (.aclk, .aresetn, .s_axil(axil.dut_slave));

initial uvm_config_db#(virtual axi_lite_if #(12, 32))::set(null, "*", "vif", axil);
```

**In the env** — one agent per port, parameterized to match its interface:

```systemverilog
axi_lite_config agent_config = axi_lite_config::type_id::create("agent_config");
agent_config.role = AXI_LITE_MASTER;            // issue transactions into the DUT
agent_config.set_addr_window(12'h000, 12'h03F); // the aperture it decodes
agent_config.set_addr_delay(0, 3);              // 0-3 idle cycles before each address

uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", agent_config);
master_agent = axi_lite_agent #(12, 32)::type_id::create("master_agent", this);
```

**In a test** — sequences carry no width, so this is the same code on every port:

```systemverilog
axi_lite_random_seq random_sequence =
    axi_lite_random_seq::type_id::create("random_sequence");
assert (random_sequence.randomize() with { num_transactions == 40; });
random_sequence.start(env.master_agent.sequencer);
```

## Pulling it into your project

The whole component is two files, and the filelist that names them:

```bash
export AXI_LITE_UVC_ROOT=/path/to/axi_lite
xvlog -sv -L uvm -f $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f -f my_tb.f
```

Nothing else in this repository is needed at compile time, and the UVC depends
on nothing but UVM.

## Repository layout

| Path | Contents |
| --- | --- |
| [`src/`](../src) | The UVC. `axi_lite_if.sv` + `axi_lite_pkg.sv`, pulled in by `axi_lite_uvc.f`. |
| [`example/`](../example) | A worked integration: a register-file DUT, an env, a scoreboard and five tests, all heavily commented. Copy this. |
| [`tb/`](../tb) | The UVC's own self-test: master and slave agents facing each other across a register slice, at five different port geometries. |
| [`docs/`](.) | You are here. |

## Status

Verified on XSIM (Vivado 2023.2) only, and `xc7z045` synthesis for the
interface. The self-test regression is 8 tests across 5 port geometries, the
example is 5 tests, and the protocol checker's negative test drives 17 scenarios
— 13 deliberate violations that must be caught and 4 that must stay quiet. See [Running the tests](checks-and-coverage.md#running-the-tests).
