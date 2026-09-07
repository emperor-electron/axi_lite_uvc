# Getting started

Wiring the UVC into your own testbench. Everything here has a working
counterpart in [`example/`](../example) — if a step is unclear, the file named
beside it is the same step in compilable form.

## 0. Run the example first

```bash
cd example && make
```

Five minutes with a passing run in front of you is worth more than five minutes
of reading. `example_tb_top.sv` and `example_base_test.sv` carry numbered
comments matching the steps below.

## 1. Add the UVC to your compile

The component is two files. `src/axi_lite_uvc.f` names both and puts `src/` on
the include path:

```bash
export AXI_LITE_UVC_ROOT=/path/to/axi_lite
xvlog -sv -L uvm -f $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f -f my_tb.f
```

The filelist is anchored on `$AXI_LITE_UVC_ROOT` because simulators resolve
filelist paths relative to the directory the compiler runs in, not relative to
the filelist itself.

Then, in your testbench package:

```systemverilog
import axi_lite_pkg::*;
```

## 2. Write the widths down once

This is the single most useful habit when integrating the UVC, and skipping it
is the most common way to lose an afternoon.

`virtual axi_lite_if #(12, 32)` and `virtual axi_lite_if #(32, 32)` are
**different SystemVerilog types**. A `uvm_config_db` `set()` and `get()` that
disagree by one parameter do not warn — the `get()` simply returns 0 and the
agent issues `NOVIF`. The fix is not care, it is naming:

```systemverilog
// my_tb_pkg.sv
parameter int MY_ADDR_WIDTH = 12;
parameter int MY_DATA_WIDTH = 32;

typedef virtual axi_lite_if #(MY_ADDR_WIDTH, MY_DATA_WIDTH) my_vif_t;
typedef axi_lite_agent      #(MY_ADDR_WIDTH, MY_DATA_WIDTH) my_agent_t;
```

Use `my_vif_t` and `my_agent_t` everywhere after this and the mismatch becomes
impossible rather than merely unlikely. See
[`example/example_tb_pkg.sv`](../example/example_tb_pkg.sv).

## 3. The top module: instantiate, wire, publish

A UVM component cannot reach into the design hierarchy, so the top module has
exactly three jobs.

```systemverilog
module my_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;
  import my_tb_pkg::*;

  logic aclk = 1'b0;
  logic aresetn;
  always #5ns aclk = ~aclk;

  // Release reset on a falling edge. Keeping it away from the rising edge
  // makes the UVC's reset-release rule -- every VALID low on the first ACLK
  // edge after ARESETn rises -- unambiguous.
  initial begin
    aresetn = 1'b0;
    repeat (5) @(negedge aclk);
    aresetn = 1'b1;
  end

  // ONE interface per AXI4-Lite port of the DUT.
  axi_lite_if #(MY_ADDR_WIDTH, MY_DATA_WIDTH) axil (.aclk(aclk), .aresetn(aresetn));

  // Wire it to the DUT, signal by signal or through the synthesizable modport.
  my_peripheral u_dut (.aclk, .aresetn, .s_axil(axil.dut_slave));

  initial begin
    uvm_config_db#(my_vif_t)::set(null, "*", "vif", axil);
    run_test("my_base_test");
  end
endmodule
```

Who drives what follows from the protocol, and it is why one interface type
serves both ends of a link:

| Driven by the master end | Driven by the slave end |
| --- | --- |
| `AWVALID AWADDR AWPROT` | `AWREADY` |
| `WVALID WDATA WSTRB` | `WREADY` |
| `BREADY` | `BVALID BRESP` |
| `ARVALID ARADDR ARPROT` | `ARREADY` |
| `RREADY` | `RVALID RDATA RRESP` |

Every signal ends up with exactly one driver. If the UVC is playing master, the
DUT drives the other column; if the UVC is playing slave, the roles swap and
nothing about the interface changes.

## 4. The env: one agent per port

```systemverilog
class my_env extends uvm_env;
  `uvm_component_utils(my_env)

  my_agent_t      master_agent;
  my_scoreboard   scoreboard;
  axi_lite_config master_config;
  my_vif_t        vif;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(my_vif_t)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no 'vif' in the config DB")
    if (!uvm_config_db#(axi_lite_config)::get(this, "", "master_config", master_config))
      `uvm_fatal("NOCFG", "no 'master_config' in the config DB")

    // An agent expects exactly two things under its own instance name.
    uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", master_config);
    uvm_config_db#(my_vif_t)::set(this, "master_agent", "vif", vif);

    master_agent = my_agent_t::type_id::create("master_agent", this);
    scoreboard   = my_scoreboard::type_id::create("scoreboard", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    master_agent.monitor.item_analysis_port.connect(scoreboard.analysis_export);
  endfunction
endclass
```

`my_scoreboard` here extends `uvm_subscriber #(axi_lite_seq_item)`, which is
where `analysis_export` comes from — see
[Checks and coverage](checks-and-coverage.md#the-monitors-analysis-ports) for
which of the monitor's two ports to connect to.

The agent expects two config-DB entries under its own instance name:
`"agent_config"` and `"vif"`. It passes both down to its children itself, so
you set them once.

At build time the agent reconciles the config's `addr_width`/`data_width`
against its own type parameters. Where the config is silent (0, the default) it
adopts the parameters; where it disagrees it warns and the parameters win. A
config claiming 32 bits on a 64-bit bus is reported rather than silently
truncating every write.

## 5. The test: build the config, run stimulus

Nearly all of the UVC's behaviour is decided in `axi_lite_config`. Build it in
the test rather than the env, so a derived test can adjust it before the agent
is created.

```systemverilog
class my_base_test extends uvm_test;
  `uvm_component_utils(my_base_test)

  my_env          env;
  axi_lite_config master_config;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    master_config      = axi_lite_config::type_id::create("master_config");
    master_config.role = AXI_LITE_MASTER;         // issue transactions into the DUT

    master_config.set_addr_window(12'h000, 12'h03F);  // the aperture the DUT decodes
    master_config.set_addr_delay(0, 3);               // idle cycles before each address
    master_config.set_wdata_delay(0, 3);              // ...and before each write data phase

    // Backpressure on the two channels a master accepts on.
    master_config.set_ready_mode(AXI_LITE_CH_B, AXI_LITE_READY_RANDOM, .percent(70));
    master_config.set_ready_mode(AXI_LITE_CH_R, AXI_LITE_READY_RANDOM, .percent(70));

    master_config.max_outstanding      = 1;     // one transaction at a time
    master_config.stall_timeout_cycles = 2000;  // deadlock watchdog; 0 disables

    uvm_config_db#(axi_lite_config)::set(this, "env", "master_config", master_config);
    env = my_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    axi_lite_random_seq random_sequence;
    phase.raise_objection(this);

    random_sequence = axi_lite_random_seq::type_id::create("random_sequence");
    if (!random_sequence.randomize() with { num_transactions == 40; })
      `uvm_fatal("RAND", "sequence randomization failed")
    random_sequence.start(env.master_agent.sequencer);

    env.scoreboard.wait_until_idle();  // let the last item reach the monitor
    phase.drop_objection(this);
  endtask
endclass
```

Notice what the stimulus does not mention: any width, and any address. The
transaction sizes and places itself from the agent's config at randomize time,
so the same three lines drive a 12/32 port and a 64/64 one.

Full reference: **[Configuration](configuration.md)**, **[Stimulus](stimulus.md)**.

## 6. If your DUT has a master port too

Add a second interface, a second agent, and set `role = AXI_LITE_SLAVE` on its
config. The slave agent accepts requests and answers them out of an
`axi_lite_mem` — a whole peripheral modelled without a line of RTL:

```systemverilog
axi_lite_config slave_config = axi_lite_config::type_id::create("slave_config");
slave_config.role = AXI_LITE_SLAVE;
slave_config.mem  = axi_lite_mem::type_id::create("mem");
slave_config.mem.add_region(64'h1000, 64'h1FFF, AXI_LITE_DECERR, "unmapped");
slave_config.set_resp_delay(1, 4);
slave_config.set_ready_mode(AXI_LITE_CH_AW, AXI_LITE_READY_RANDOM, .percent(60));
```

A slave agent needs no sequencer and takes no stimulus: what it accepts and
what it answers come from its config and its memory model.
[`tb/axi_lite_link.sv`](../tb/axi_lite_link.sv) shows a master agent on one side
of a DUT and a slave agent on the other.

## 7. Ending the test without racing the monitor

A sequence returns once the last response has been accepted at the master, and
the monitor publishes that same transaction on the same clock edge. Dropping the
objection immediately would race it, so wait for your scoreboard to go idle
first — and make "idle" mean *nothing outstanding*, not *no queued items*, or
the drain check will pass in the window between a request leaving and its
response returning. See [Troubleshooting](troubleshooting.md#a-test-ends-while-a-response-is-still-in-flight).

## Common next steps

- Change the backpressure model → [Configuration › Backpressure](configuration.md#backpressure-per-channel)
- Write a directed register sequence → [Stimulus › write() and read()](stimulus.md#directed-access-write-and-read)
- Model a real peripheral for a slave agent → [Configuration › The slave memory model](configuration.md#the-slave-memory-model)
- Understand what the assertions already check for you → [Checks and coverage](checks-and-coverage.md)
