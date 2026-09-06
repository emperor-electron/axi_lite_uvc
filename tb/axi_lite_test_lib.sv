///////////////////////////////////////////////////////////////////
// Filename: axi_lite_test_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : The UVC's self-test. Five differently parameterized
//           AXI4-Lite links are built, driven and checked inside a
//           single simulation, under every backpressure model the UVC
//           offers.
///////////////////////////////////////////////////////////////////
//
// The five links, all live at once in one compilation:
//
//   env_a32d32   ADDR 32  DATA 32   the common case
//   env_a32d64   ADDR 32  DATA 64   the other data width AXI4-Lite allows
//   env_a64d64   ADDR 64  DATA 64   full 64-bit addressing
//   env_a12d32   ADDR 12  DATA 32   a peripheral's own 4 KB aperture
//   env_a16d64   ADDR 16  DATA 64   a 64 KB window on a wide bus
//
// AXI4-Lite fixes the data bus at 32 or 64 bits, so unlike a stream UVC
// there is no long tail of widths to sweep -- the interesting axis is
// the *address* width, because that is what a peripheral actually
// varies. A 12-bit aperture is in the list on purpose: it is the case
// where the address window a test asks for can exceed what the bus can
// address, which is exactly what the agent's geometry reconciliation is
// there to catch.
//
// Not one of these widths is a `define. They are module and class
// parameters, so all five elaborate together and a single `make` run
// covers the lot.
//
// Every link is checked by its own scoreboard against its own register
// slice, and every link's two interfaces run the protocol assertions the
// whole time, so a UVC bug that only shows up at one width has nowhere
// to hide.

class axi_lite_base_test extends uvm_test;

  `uvm_component_utils(axi_lite_base_test)

  // The parameterization under test. These five declarations are the
  // only place in the testbench where a width is written down.
  axi_lite_env #(32, 32) env_a32d32;
  axi_lite_env #(32, 64) env_a32d64;
  axi_lite_env #(64, 64) env_a64d64;
  axi_lite_env #(12, 32) env_a12d32;
  axi_lite_env #(16, 64) env_a16d64;

  // ...and this is why that is bearable: a width-agnostic handle to
  // every one of them, which is what the rest of the test uses.
  axi_lite_env_base envs[$];

  virtual axi_lite_tb_ctrl_if ctrl;

  int unsigned transactions_per_link = 24;
  int unsigned max_drain_cycles      = 40000;

  // The address window every link's sequences draw from. 256 bytes fits
  // inside even the 12-bit aperture, so one number serves all five.
  axi_lite_addr_t window_lo = 64'h0000;
  axi_lite_addr_t window_hi = 64'h00FF;

  extern function new(string name = "axi_lite_base_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void end_of_elaboration_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);

  // Per-link knobs, overridden by the tests below. Called once per link
  // during build, before the agents exist.
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);

  // Per-link stimulus, run concurrently on every link.
  extern virtual task run_link(axi_lite_env_base e, int unsigned index);

  // Wait until every link's scoreboard has seen its traffic come back,
  // rather than guessing at a fixed settling time.
  extern virtual task drain(int unsigned limit_cycles = 0);
  extern virtual function bit all_links_drained();

  extern function axi_lite_config make_config(string name, axi_lite_role_e link_role);

endclass : axi_lite_base_test

function axi_lite_base_test::new(string name = "axi_lite_base_test",
                                 uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(virtual axi_lite_tb_ctrl_if)::get(this, "", "ctrl", ctrl))
    `uvm_fatal("NOCTRL", "no virtual axi_lite_tb_ctrl_if set in the config DB")

  // The instance names below must match the ENV_NAME parameter of the
  // matching axi_lite_link instance in the top module: that is how each
  // link's two interfaces reach the right env through the config DB.
  env_a32d32 = axi_lite_env #(32, 32)::type_id::create("env_a32d32", this);
  env_a32d64 = axi_lite_env #(32, 64)::type_id::create("env_a32d64", this);
  env_a64d64 = axi_lite_env #(64, 64)::type_id::create("env_a64d64", this);
  env_a12d32 = axi_lite_env #(12, 32)::type_id::create("env_a12d32", this);
  env_a16d64 = axi_lite_env #(16, 64)::type_id::create("env_a16d64", this);

  envs = '{env_a32d32, env_a32d64, env_a64d64, env_a12d32, env_a16d64};

  // Configs are assigned here, in the test's build_phase, because the
  // envs' own build_phase runs afterwards and only creates a default
  // config where the test has not supplied one.
  foreach (envs[i]) begin
    envs[i].master_config = make_config("master_config", AXI_LITE_MASTER);
    envs[i].slave_config  = make_config("slave_config",  AXI_LITE_SLAVE);
    configure_link(envs[i], i);
  end
endfunction : build_phase

function axi_lite_config axi_lite_base_test::make_config(string name,
                                                         axi_lite_role_e link_role);
  axi_lite_config link_config;
  link_config      = axi_lite_config::type_id::create(name);
  link_config.role = link_role;
  link_config.set_addr_window(window_lo, window_hi);
  // ADDR_WIDTH/DATA_WIDTH come from the agent's parameters; see
  // axi_lite_agent::adopt_interface_geometry.
  return link_config;
endfunction : make_config

// Default: no backpressure, no pacing, answers as early as legally
// possible. Every test below changes at least one of these.
function void axi_lite_base_test::configure_link(axi_lite_env_base e, int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_ALWAYS);
  e.set_pacing(0, 0);
  e.set_resp_delay(0, 0);
endfunction : configure_link

function void axi_lite_base_test::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  `uvm_info("TEST", $sformatf("%s: %0d AXI4-Lite links, %0d transactions each",
                              get_type_name(), envs.size(), transactions_per_link), UVM_LOW)
endfunction : end_of_elaboration_phase

task axi_lite_base_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "driving traffic on every link");

  // Every link runs concurrently, so the whole set of widths is
  // exercised in the time one of them would take.
  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end
  wait fork;

  drain();
  phase.drop_objection(this, "all links finished");
endtask : run_phase

task axi_lite_base_test::run_link(axi_lite_env_base e, int unsigned index);
  axi_lite_random_seq random_sequence;
  int unsigned n = transactions_per_link;
  random_sequence = axi_lite_random_seq::type_id::create($sformatf("random_%0d", index));
  if (!random_sequence.randomize() with { num_transactions == n; })
    `uvm_fatal("RAND", "random sequence randomization failed")
  random_sequence.start(e.master_sequencer);
endtask : run_link

function bit axi_lite_base_test::all_links_drained();
  foreach (envs[i])
    if (!envs[i].scoreboard.is_drained())
      return 1'b0;
  return 1'b1;
endfunction : all_links_drained

task axi_lite_base_test::drain(int unsigned limit_cycles = 0);
  int unsigned limit   = (limit_cycles == 0) ? max_drain_cycles : limit_cycles;
  int unsigned elapsed = 0;
  while ((elapsed < limit) && !all_links_drained()) begin
    ctrl.wait_cycles(16);
    elapsed += 16;
  end
  if (!all_links_drained())
    `uvm_warning("DRAIN", $sformatf(
        "links still had traffic outstanding after %0d cycles", elapsed))
  // A few more cycles so the last responses reach the monitors' analysis
  // ports.
  ctrl.wait_cycles(8);
endtask : drain


///////////////////////////////////////////////////////////////////
// The quickest useful run: a little traffic on every link with no
// backpressure, no pacing and no answer delay, so the link runs flat out
// and any basic wiring or width mistake shows up immediately.
///////////////////////////////////////////////////////////////////
class axi_lite_smoke_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_smoke_test)

  extern function new(string name = "axi_lite_smoke_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);

endclass : axi_lite_smoke_test

function axi_lite_smoke_test::new(string name = "axi_lite_smoke_test",
                                  uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 12;
endfunction : new

function void axi_lite_smoke_test::configure_link(axi_lite_env_base e, int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_ALWAYS);
  e.set_pacing(0, 0);
  e.set_resp_delay(0, 0);
  // Everything is ready all the time, so nothing should ever stall for
  // long; a stall of any real length means the driver is inserting
  // bubbles it was not asked for.
  e.master_config.stall_timeout_cycles = 64;
  e.slave_config.stall_timeout_cycles  = 64;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// The headline test: all five parameterizations at once, each with its
// own randomly drawn backpressure, pacing and slave answer latency.
///////////////////////////////////////////////////////////////////
class axi_lite_multiwidth_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_multiwidth_test)

  extern function new(string name = "axi_lite_multiwidth_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);

endclass : axi_lite_multiwidth_test

function axi_lite_multiwidth_test::new(string name = "axi_lite_multiwidth_test",
                                       uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 24;
endfunction : new

function void axi_lite_multiwidth_test::configure_link(axi_lite_env_base e,
                                                       int unsigned index);
  // A separately drawn model on every channel, so the five do not move
  // in lockstep and the interesting interactions -- a slow AW against a
  // fast W, a stalled B behind a busy R -- actually happen.
  axi_lite_channel_e channel = channel.first();
  forever begin
    axi_lite_default_ready_policy policy;
    policy = axi_lite_default_ready_policy::type_id::create(
        $sformatf("policy_%0d_%s", index, channel.name()));
    // Anything but NEVER: this test expects every link to drain.
    if (!policy.randomize() with { mode != AXI_LITE_READY_NEVER;
                                   ready_percent inside {[30:90]};
                                   stall_cycles  inside {[1:5]};
                                   burst_beats   inside {[1:8]};
                                   delay_max     inside {[0:6]}; })
      `uvm_fatal("RAND", "backpressure policy randomization failed")
    e.master_config.set_ready_policy(channel, policy);
    e.slave_config.set_ready_policy(channel, policy);
    if (channel == channel.last()) break;
    channel = channel.next();
  end

  e.set_pacing(0, $urandom_range(3, 0));
  e.set_resp_delay(0, $urandom_range(4, 0));
  e.master_config.stall_timeout_cycles = 4000;
  e.slave_config.stall_timeout_cycles  = 4000;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// Every built-in backpressure model, one per link, deterministically
// assigned so a single run exercises all of them and the log says which
// link had which.
///////////////////////////////////////////////////////////////////
class axi_lite_backpressure_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_backpressure_test)

  extern function new(string name = "axi_lite_backpressure_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);

endclass : axi_lite_backpressure_test

function axi_lite_backpressure_test::new(string name = "axi_lite_backpressure_test",
                                         uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 20;
endfunction : new

function void axi_lite_backpressure_test::configure_link(axi_lite_env_base e,
                                                         int unsigned index);
  case (index)
    0 : e.set_backpressure_all(AXI_LITE_READY_ALWAYS);
    1 : e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(30));
    2 : e.set_backpressure_all(AXI_LITE_READY_DUTY,   .ready_cycles(1), .stall_cycles(3));
    3 : e.set_backpressure_all(AXI_LITE_READY_BURST,  .burst_beats(4), .stall_cycles(6));
    4 : e.set_backpressure_all(AXI_LITE_READY_DELAY,  .delay_min(0), .delay_max(8));
    default : e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(50));
  endcase
  // Source-side bubbles and a slow slave too, so the three pacing
  // mechanisms interact rather than each being tested against a
  // perfectly behaved partner.
  e.set_pacing(0, 3);
  e.set_resp_delay(1, 4);
  e.master_config.stall_timeout_cycles = 8000;
  e.slave_config.stall_timeout_cycles  = 8000;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// A link that refuses every transfer, then relents.
//
// This is the sharpest test of the master driver's handshake: with every
// READY held low for hundreds of cycles, each VALID and its entire
// payload must stay exactly as first offered. The interface's
// *VALID_HELD and *_STABLE assertions are what actually check that, all
// the way through the stall. Releasing the backpressure afterwards then
// proves the stalled transactions were only held, not lost.
///////////////////////////////////////////////////////////////////
class axi_lite_no_ready_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_no_ready_test)

  int unsigned stall_cycles = 300;

  extern function new(string name = "axi_lite_no_ready_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);
  extern virtual task run_phase(uvm_phase phase);

endclass : axi_lite_no_ready_test

function axi_lite_no_ready_test::new(string name = "axi_lite_no_ready_test",
                                     uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 8;
endfunction : new

function void axi_lite_no_ready_test::configure_link(axi_lite_env_base e,
                                                     int unsigned index);
  // Only the slave's request channels are jammed. Jamming the master's
  // response channels as well would be legal but pointless: with nothing
  // ever accepted there would be no response to hold up.
  e.slave_config.set_ready_mode(AXI_LITE_CH_AW, AXI_LITE_READY_NEVER);
  e.slave_config.set_ready_mode(AXI_LITE_CH_W,  AXI_LITE_READY_NEVER);
  e.slave_config.set_ready_mode(AXI_LITE_CH_AR, AXI_LITE_READY_NEVER);
  e.set_pacing(0, 0);
  e.set_resp_delay(0, 0);
  // The whole point of this test is a very long legitimate stall, so the
  // deadlock watchdog stays off until backpressure is released.
  e.master_config.stall_timeout_cycles = 0;
  e.slave_config.stall_timeout_cycles  = 0;
endfunction : configure_link

task axi_lite_no_ready_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "stalling every link, then releasing");

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end

  // Let the register slices fill and every link jam solid.
  ctrl.wait_cycles(stall_cycles);
  foreach (envs[i])
    if (envs[i].scoreboard.num_responses_matched != 0)
      `uvm_error("BACKPRESSURE", $sformatf(
          "link %s completed %0d transaction(s) while every READY was held low the whole time",
          envs[i].link_desc, envs[i].scoreboard.num_responses_matched))

  `uvm_info("BACKPRESSURE", "releasing backpressure on every link", UVM_LOW)
  foreach (envs[i]) begin
    envs[i].set_backpressure_all(AXI_LITE_READY_ALWAYS);
    envs[i].master_config.stall_timeout_cycles = 8000;
    envs[i].slave_config.stall_timeout_cycles  = 8000;
  end

  wait fork;
  drain();
  phase.drop_objection(this, "all links drained after release");
endtask : run_phase


///////////////////////////////////////////////////////////////////
// Walk every location of every link's window, writing an
// address-dependent pattern and reading it straight back. This is the
// register-map shape of test, and it is the one that catches an address
// that is truncated, shifted, or decoded onto the wrong word -- failures
// random traffic can miss for a long time.
///////////////////////////////////////////////////////////////////
class axi_lite_sweep_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_sweep_test)

  extern function new(string name = "axi_lite_sweep_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);
  extern virtual task run_link(axi_lite_env_base e, int unsigned index);

endclass : axi_lite_sweep_test

function axi_lite_sweep_test::new(string name = "axi_lite_sweep_test",
                                  uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_sweep_test::configure_link(axi_lite_env_base e, int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(70));
  e.set_pacing(0, 2);
  e.set_resp_delay(0, 3);
  e.master_config.stall_timeout_cycles = 8000;
  e.slave_config.stall_timeout_cycles  = 8000;
endfunction : configure_link

task axi_lite_sweep_test::run_link(axi_lite_env_base e, int unsigned index);
  axi_lite_sweep_seq sweep_sequence;
  sweep_sequence = axi_lite_sweep_seq::type_id::create($sformatf("sweep_%0d", index));
  if (!sweep_sequence.randomize() with { max_locations == 32; })
    `uvm_fatal("RAND", "sweep sequence randomization failed")
  sweep_sequence.start(e.master_sequencer);
endtask : run_link


///////////////////////////////////////////////////////////////////
// Error responses. Half of each link's address window is given to the
// slave model as a SLVERR region and a DECERR region, so the UVC has to
// carry a non-OKAY BRESP/RRESP back intact -- and the scoreboard has to
// agree that a refused write never landed.
//
// Worth having as its own test because an error response is the one
// path where the data and the response disagree: the read data that
// comes with a DECERR is meaningless, and anything that compares it
// would fail for the wrong reason.
///////////////////////////////////////////////////////////////////
class axi_lite_error_resp_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_error_resp_test)

  extern function new(string name = "axi_lite_error_resp_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);
  extern virtual function void end_of_elaboration_phase(uvm_phase phase);
  extern virtual function void check_phase(uvm_phase phase);

endclass : axi_lite_error_resp_test

function axi_lite_error_resp_test::new(string name = "axi_lite_error_resp_test",
                                       uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 32;
endfunction : new

function void axi_lite_error_resp_test::configure_link(axi_lite_env_base e,
                                                       int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(70));
  e.set_pacing(0, 2);
  e.set_resp_delay(0, 3);
  e.master_config.stall_timeout_cycles = 8000;
  e.slave_config.stall_timeout_cycles  = 8000;

  // The env creates the memory in its build_phase, which has not run
  // yet, so the model is built here and handed over.
  if (e.mem == null)
    e.mem = axi_lite_mem::type_id::create($sformatf("mem_%0d", index));

  // Upper half of the window errors: a quarter SLVERR, a quarter DECERR.
  e.mem.add_region(64'h0080, 64'h00BF, AXI_LITE_SLVERR, "slverr_region");
  e.mem.add_region(64'h00C0, 64'h00FF, AXI_LITE_DECERR, "decerr_region");
endfunction : configure_link

function void axi_lite_error_resp_test::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  foreach (envs[i])
    `uvm_info("TEST", $sformatf("%s memory: %s", envs[i].link_desc,
                                envs[i].mem.convert2string()), UVM_LOW)
endfunction : end_of_elaboration_phase

// The point of the test is that error responses happen and are carried
// back faithfully. A run in which none occurred would pass every other
// check while proving nothing, so the absence of them is itself a
// failure.
function void axi_lite_error_resp_test::check_phase(uvm_phase phase);
  super.check_phase(phase);
  foreach (envs[i]) begin
    axi_lite_mem mem = envs[i].mem;
    if (mem.num_reads + mem.num_writes == 0)
      `uvm_error("TEST", $sformatf("link %s never reached its slave model", envs[i].link_desc))
  end
endfunction : check_phase


///////////////////////////////////////////////////////////////////
// Several transactions in flight at once.
//
// AXI4-Lite has no transaction IDs, so a pipelined master is only
// correct if responses come back in issue order and are attributed in
// that order -- which is precisely the assumption the master driver's
// two pending queues encode. Raising max_outstanding and letting the
// sequences run ahead is what tests that assumption rather than merely
// stating it.
//
// The scoreboard's read-data check knows that a read overlapping a write
// to the same address has two legal answers and skips those, so the
// checking stays honest under reordering that the protocol allows.
///////////////////////////////////////////////////////////////////
class axi_lite_pipelined_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_pipelined_test)

  int unsigned outstanding = 4;

  extern function new(string name = "axi_lite_pipelined_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);
  extern virtual task run_link(axi_lite_env_base e, int unsigned index);

endclass : axi_lite_pipelined_test

function axi_lite_pipelined_test::new(string name = "axi_lite_pipelined_test",
                                      uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 32;
endfunction : new

function void axi_lite_pipelined_test::configure_link(axi_lite_env_base e,
                                                      int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(60));
  e.set_pacing(0, 2);
  // A slave that takes its time is what actually makes transactions
  // overlap; with a zero-latency slave each one would finish before the
  // next was issued however high max_outstanding was.
  e.set_resp_delay(2, 8);
  e.master_config.max_outstanding      = outstanding;
  e.master_config.stall_timeout_cycles = 8000;
  e.slave_config.stall_timeout_cycles  = 8000;
endfunction : configure_link

task axi_lite_pipelined_test::run_link(axi_lite_env_base e, int unsigned index);
  axi_lite_random_seq random_sequence;
  int unsigned n = transactions_per_link;
  random_sequence = axi_lite_random_seq::type_id::create($sformatf("random_%0d", index));
  if (!random_sequence.randomize() with { num_transactions == n; })
    `uvm_fatal("RAND", "random sequence randomization failed")
  // Do not wait for each response before issuing the next -- otherwise
  // max_outstanding could never be reached and this test would be the
  // base test with a bigger number in the config.
  random_sequence.blocking = 1'b0;
  random_sequence.start(e.master_sequencer);
endtask : run_link


///////////////////////////////////////////////////////////////////
// Reset in the middle of live traffic on every link at once.
//
// The transactions in flight when ARESETn drops are expected to be lost
// -- that is what reset means -- so checking is switched off across the
// disturbance and the scoreboards are flushed afterwards. What is being
// tested is what happens next: that both drivers come out of reset
// legally (every VALID low on the first edge after release, which the
// interface asserts) and that the link then carries a clean pass of
// traffic with nothing left over from before.
///////////////////////////////////////////////////////////////////
class axi_lite_reset_test extends axi_lite_base_test;

  `uvm_component_utils(axi_lite_reset_test)

  extern function new(string name = "axi_lite_reset_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_lite_env_base e, int unsigned index);
  extern virtual task run_phase(uvm_phase phase);

endclass : axi_lite_reset_test

function axi_lite_reset_test::new(string name = "axi_lite_reset_test",
                                  uvm_component parent = null);
  super.new(name, parent);
  transactions_per_link = 24;
endfunction : new

function void axi_lite_reset_test::configure_link(axi_lite_env_base e, int unsigned index);
  e.set_backpressure_all(AXI_LITE_READY_RANDOM, .percent(50));
  e.set_pacing(0, 2);
  e.set_resp_delay(0, 3);
  e.master_config.stall_timeout_cycles = 8000;
  e.slave_config.stall_timeout_cycles  = 8000;
endfunction : configure_link

task axi_lite_reset_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "reset in the middle of traffic");

  // --- Pass 1: traffic across a reset. Nothing here is checked. ---
  foreach (envs[i]) envs[i].scoreboard.checking_enabled = 1'b0;

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end

  ctrl.wait_cycles(150);
  `uvm_info("RESET", "asserting ARESETn while every link is busy", UVM_LOW)
  ctrl.assert_reset(6);

  wait fork;
  drain(4000);

  // --- Pass 2: the link must now behave as though nothing happened. ---
  //
  // Both models have to be brought back into agreement first, and the
  // reason is worth stating precisely.
  //
  // ARESETn resets the bus, not the peripheral behind it, so the slave
  // agent's memory deliberately keeps everything pass 1 wrote to it. The
  // scoreboard's shadow, though, only learns about a write when it sees
  // that write *complete* at the master -- and checking was off for all
  // of pass 1, so it learned about none of them. Worse, reset cut some
  // writes off mid-flight, and for those nobody can say whether they
  // landed: the address and data may have reached the slave a cycle
  // before ARESETn dropped, or a cycle after.
  //
  // So the shadow is re-seeded from the slave's memory here. That is not
  // weakening the check: the slave model is part of the UVC, not the
  // DUT, and what is under test is the register slice and the drivers
  // between them. Pass 2 then holds every transaction to the strict
  // three-way check from a starting point both models agree on --
  // which is exactly what the test set out to establish.
  ctrl.wait_cycles(64);   // let anything still moving finish first
  foreach (envs[i]) begin
    envs[i].scoreboard.flush();
    envs[i].scoreboard.shadow.copy(envs[i].mem);
    envs[i].scoreboard.checking_enabled = 1'b1;
  end
  `uvm_info("RESET", "reset released; re-running traffic with checking on", UVM_LOW)

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end
  wait fork;
  drain();

  phase.drop_objection(this, "post-reset traffic verified");
endtask : run_phase
