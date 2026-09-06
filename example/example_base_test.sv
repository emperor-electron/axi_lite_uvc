///////////////////////////////////////////////////////////////////
// Filename: example_base_test.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Worked example of configuring and driving the AXI4-Lite UVC.
//           The companion to example_tb_top.sv: that file connects the
//           UVC to the design, this one decides how it behaves.
///////////////////////////////////////////////////////////////////
//
// ============================================================
//  WHAT THIS FILE HAS TO DO
// ============================================================
//   1. build an axi_lite_config saying which end of the port the agent
//      drives, what address window its stimulus may use, and how it
//      should pace itself and backpressure responses
//   2. create the env that holds the agent
//   3. run stimulus on the agent's sequencer
//
// The config is where nearly all the UVC's behaviour is decided, so it is
// worth reading closely. Everything else here is ordinary UVM.
//
// The derived tests at the bottom show the four knobs you are most
// likely to reach for: a different backpressure model, a specific
// register access, an address sweep, and deliberately driving outside
// the DUT's aperture to see it answer DECERR.

class example_base_test extends uvm_test;

  `uvm_component_utils(example_base_test)

  example_env env;

  // The config is built here rather than inside the env so that a
  // derived test can adjust it in its own build_phase before the agent
  // is created. See example_backpressure_test below.
  axi_lite_config master_config;

  int unsigned num_transactions = 40;

  // The address window stimulus draws from. The base test stays inside
  // the DUT's decoded aperture; example_decerr_test widens it.
  axi_lite_addr_t window_lo = EX_ID_ADDR;
  axi_lite_addr_t window_hi = EX_MAP_HI;

  extern function new(string name = "example_base_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);

  // Overridden by the derived tests; the base runs random traffic.
  extern virtual task run_stimulus();

endclass : example_base_test

function example_base_test::new(string name = "example_base_test", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 1 -- the config for the agent that issues transactions INTO the
  //           DUT's slave port.
  // ---------------------------------------------------------------------
  master_config      = axi_lite_config::type_id::create("master_config");
  master_config.role = AXI_LITE_MASTER;

  // Which addresses stimulus may use. Every sequence in the library
  // draws from this window and aligns to the bus width automatically, so
  // no sequence ever has to be told the register map. Note that
  // ADDR_WIDTH and DATA_WIDTH are *not* set here -- the agent derives
  // those from its own parameters, since a config cannot contradict the
  // interface it is attached to.
  master_config.set_addr_window(window_lo, window_hi);

  // Does this link carry AWPROT/ARPROT? Clear it for a DUT that ties
  // them off, and the UVC drives zeros and stops checking them.
  master_config.has_prot = 1'b1;

  // Source-side pacing: idle ACLK cycles inserted before the address
  // phase and, independently, before the write data phase. Independent
  // on purpose -- it is what lets the write data lead the address, which
  // is legal AXI4-Lite and a case plenty of slaves get wrong.
  master_config.set_addr_delay(0, 3);
  master_config.set_wdata_delay(0, 3);

  // ---------------------------------------------------------------------
  // STEP 2 -- backpressure. On a master agent this means the two
  //           channels it accepts on: B and R.
  //
  //   AXI_LITE_READY_ALWAYS  READY tied high -- no backpressure
  //   AXI_LITE_READY_NEVER   READY tied low  -- never accepts
  //   AXI_LITE_READY_RANDOM  per-cycle coin flip at .percent()
  //   AXI_LITE_READY_DUTY    .ready_cycles() high, .stall_cycles() low
  //   AXI_LITE_READY_BURST   accept .burst_beats(), then stall .stall_cycles()
  //   AXI_LITE_READY_DELAY   hold off .delay_min()...delay_max() after VALID
  //
  // For anything else, extend axi_lite_ready_policy, override
  // next_ready(), and hand it to set_ready_policy(). The policy class is
  // not parameterized by width, so one custom model works on every port
  // in your testbench.
  // ---------------------------------------------------------------------
  master_config.set_ready_mode(AXI_LITE_CH_B, AXI_LITE_READY_RANDOM, .percent(70));
  master_config.set_ready_mode(AXI_LITE_CH_R, AXI_LITE_READY_RANDOM, .percent(70));

  // How many transactions may be in flight at once. 1 -- the default --
  // means each completes before the next is issued, which is what most
  // AXI4-Lite peripherals expect. Raise it to exercise a slave that
  // claims to pipeline.
  master_config.max_outstanding = 1;

  // Optional deadlock watchdog: error out if a transfer stays offered
  // this long on any channel without being accepted. Leave it at 0 (the
  // default) if a test deliberately backpressures forever.
  master_config.stall_timeout_cycles = 2000;

  // ---------------------------------------------------------------------
  // STEP 3 -- hand the config to the env and build it. The env passes it
  //           down to the agent; see example_env.sv, STEP 2.
  // ---------------------------------------------------------------------
  uvm_config_db#(axi_lite_config)::set(this, "env", "master_config", master_config);

  env = example_env::type_id::create("env", this);
endfunction : build_phase

task example_base_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "driving traffic through the DUT");

  run_stimulus();

  // ---------------------------------------------------------------------
  // Let the last transaction reach the monitor before ending. A sequence
  // returns once the last response has been accepted at the master, and
  // the monitor publishes on that same edge -- but ending the phase in
  // the same delta would race it.
  // ---------------------------------------------------------------------
  env.scoreboard.wait_until_idle();

  phase.drop_objection(this, "traffic complete");
endtask : run_phase

// ---------------------------------------------------------------------
// STEP 4 -- run stimulus on the agent's sequencer.
//
// Note what is missing from these three lines: any mention of a width or
// an address. The transaction sizes and places itself from the agent's
// config at randomize time, so this same sequence drives a 12-bit/32-bit
// port and a 64-bit/64-bit one without being told which it is on.
//
// The library:
//   axi_lite_write_seq       one write
//   axi_lite_read_seq        one read; .rdata and .resp afterwards
//   axi_lite_write_read_seq  a write and a read-back, checked
//   axi_lite_sweep_seq       every location of the window, write+read
//   axi_lite_random_seq      a mix of the above
// ---------------------------------------------------------------------
task example_base_test::run_stimulus();
  axi_lite_random_seq random_sequence;
  int unsigned n = num_transactions;

  random_sequence = axi_lite_random_seq::type_id::create("random_sequence");
  if (!random_sequence.randomize() with { num_transactions == n;
                                          read_percent inside {[40:60]}; })
    `uvm_fatal("RAND", "sequence randomization failed")
  random_sequence.start(env.master_agent.sequencer);
endtask : run_stimulus


///////////////////////////////////////////////////////////////////
// Changing the backpressure model is a two-line derived test: build the
// base configuration, then overwrite the fields you care about.
///////////////////////////////////////////////////////////////////
class example_backpressure_test extends example_base_test;

  `uvm_component_utils(example_backpressure_test)

  extern function new(string name = "example_backpressure_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

endclass : example_backpressure_test

function example_backpressure_test::new(string name = "example_backpressure_test",
                                        uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_backpressure_test::build_phase(uvm_phase phase);
  super.build_phase(phase);   // builds the config and the env

  // Accept four responses, then shut the channel for six cycles, forever.
  // This is the model that finds "slave assumes the master is always
  // ready" bugs, because the stall always lands after a known number of
  // transfers however the DUT paced them.
  master_config.set_ready_mode(AXI_LITE_CH_B, AXI_LITE_READY_BURST,
                               .burst_beats(4), .stall_cycles(6));
  master_config.set_ready_mode(AXI_LITE_CH_R, AXI_LITE_READY_BURST,
                               .burst_beats(4), .stall_cycles(6));

  // ...and make the source bursty too, so the two interact rather than
  // each being tested against a perfectly behaved partner.
  master_config.set_addr_delay(0, 5);
  master_config.set_wdata_delay(0, 5);
endfunction : build_phase


///////////////////////////////////////////////////////////////////
// Accessing specific registers rather than random ones. The base
// sequence class gives every sequence a write() and a read() task, so a
// directed test reads like the register sequence it is describing.
///////////////////////////////////////////////////////////////////
class example_directed_seq extends axi_lite_base_seq;

  `uvm_object_utils(example_directed_seq)

  extern function new(string name = "example_directed_seq");
  extern virtual task body();

endclass : example_directed_seq

function example_directed_seq::new(string name = "example_directed_seq");
  super.new(name);
endfunction : new

task example_directed_seq::body();
  axi_lite_data_t data;
  axi_lite_resp_e resp;

  // The ID register is read-only and holds a known constant.
  read(EX_ID_ADDR, data, resp);
  if (resp != AXI_LITE_OKAY)
    `uvm_error("DIRECTED", $sformatf("reading the ID register answered %s", resp.name()))
  else if (data !== EX_ID_VALUE)
    `uvm_error("DIRECTED", $sformatf("ID register read 0x%0h, expected 0x%0h", data, EX_ID_VALUE))

  // ...and writing it is accepted and ignored, which is what the DUT
  // documents and what the scoreboard models.
  write(EX_ID_ADDR, 64'hFFFF_FFFF, resp);
  read(EX_ID_ADDR, data, resp);
  if (data !== EX_ID_VALUE)
    `uvm_error("DIRECTED", "the read-only ID register changed after being written")

  // A scratch register takes a whole word...
  write(EX_REG_LO, 64'hDEAD_BEEF, resp);
  read(EX_REG_LO, data, resp);
  if (data !== 64'hDEAD_BEEF)
    `uvm_error("DIRECTED", $sformatf("0x%0h read back 0x%0h, expected 0xDEADBEEF",
                                     EX_REG_LO, data))

  // ...and a single byte lane, leaving the other three alone. Getting
  // WSTRB right is the most common register-file bug there is, so it is
  // worth one directed access even when random traffic covers it.
  write(EX_REG_LO, 64'h0000_00A5, resp, .strb(4'b0001));
  read(EX_REG_LO, data, resp);
  if (data !== 64'hDEAD_BEA5)
    `uvm_error("DIRECTED", $sformatf("byte-strobed write left 0x%0h, expected 0xDEADBEA5", data))

  // An address the DUT does not decode. Note that this is outside the
  // config's address window -- and deliberately so: the window shapes
  // *random* stimulus, and a directed access says exactly where it wants
  // to go, so write()/read() do not hold it to the window. Probing an
  // unmapped address to watch the slave answer DECERR is a test, not a
  // mistake.
  read(EX_MAP_HI + 1, data, resp);
  if (resp != AXI_LITE_DECERR)
    `uvm_error("DIRECTED", $sformatf("reading unmapped 0x%0h answered %s, expected DECERR",
                                     EX_MAP_HI + 1, resp.name()))
endtask : body


class example_directed_test extends example_base_test;

  `uvm_component_utils(example_directed_test)

  extern function new(string name = "example_directed_test", uvm_component parent = null);
  extern virtual task run_stimulus();

endclass : example_directed_test

function example_directed_test::new(string name = "example_directed_test",
                                    uvm_component parent = null);
  super.new(name, parent);
endfunction : new

task example_directed_test::run_stimulus();
  example_directed_seq directed_sequence;
  directed_sequence = example_directed_seq::type_id::create("directed_sequence");
  directed_sequence.start(env.master_agent.sequencer);
endtask : run_stimulus


///////////////////////////////////////////////////////////////////
// Walking the whole register map. The sweep sequence writes an
// address-derived pattern to every location in the window and reads it
// straight back, which is the check that catches an address that is
// truncated, shifted, or decoded onto the wrong register.
//
// Register 0 is read-only, so it will not read back what the sweep
// wrote -- the sweep's own comparison is therefore turned off and the
// scoreboard, which knows about the read-only register, does the
// checking instead. That division is worth noticing: the sequence's
// check is a convenience for bring-up, the scoreboard's is the real one.
///////////////////////////////////////////////////////////////////
class example_sweep_test extends example_base_test;

  `uvm_component_utils(example_sweep_test)

  extern function new(string name = "example_sweep_test", uvm_component parent = null);
  extern virtual task run_stimulus();

endclass : example_sweep_test

function example_sweep_test::new(string name = "example_sweep_test",
                                 uvm_component parent = null);
  super.new(name, parent);
endfunction : new

task example_sweep_test::run_stimulus();
  axi_lite_sweep_seq sweep_sequence;
  sweep_sequence = axi_lite_sweep_seq::type_id::create("sweep_sequence");
  sweep_sequence.check_readback = 1'b0;
  if (!sweep_sequence.randomize() with { max_locations == EX_NUM_REGS; })
    `uvm_fatal("RAND", "sweep sequence randomization failed")
  sweep_sequence.start(env.master_agent.sequencer);
endtask : run_stimulus


///////////////////////////////////////////////////////////////////
// Driving outside the DUT's aperture on purpose.
//
// Widening the config's address window is the whole change: the
// sequences already draw from it, so half the traffic now lands where
// nothing is decoded and the DUT answers DECERR. The scoreboard knows
// the map, so it requires the error rather than merely tolerating it --
// which is the difference between testing the error path and ignoring it.
///////////////////////////////////////////////////////////////////
class example_decerr_test extends example_base_test;

  `uvm_component_utils(example_decerr_test)

  extern function new(string name = "example_decerr_test", uvm_component parent = null);

endclass : example_decerr_test

function example_decerr_test::new(string name = "example_decerr_test",
                                  uvm_component parent = null);
  super.new(name, parent);
  // Twice the decoded map, so roughly half of all accesses miss it.
  window_hi = 2 * (EX_MAP_HI + 1) - 1;
endfunction : new
