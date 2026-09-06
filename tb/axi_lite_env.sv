///////////////////////////////////////////////////////////////////
// Filename: axi_lite_env.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : One link of the self-test: a master agent issuing
//           transactions into the register slice's slave port, a slave
//           agent answering its master port out of a memory model, and
//           the scoreboard between them.
///////////////////////////////////////////////////////////////////
//
// The pair of classes here is the pattern that makes a width-agnostic
// test possible, and is worth copying into any testbench that has to
// hold several differently sized ports at once:
//
//   axi_lite_env_base  - unparameterized. Holds everything a test
//                        actually touches: the two configs, the master
//                        sequencer, the memory model, the scoreboard, a
//                        name.
//   axi_lite_env #(..) - parameterized. Adds the two agents, which are
//                        the only things that need to know a width, and
//                        publishes its sequencer up into the base class.
//
// A test can therefore keep `axi_lite_env_base envs[$]` containing a
// 32-bit port and a 64-bit port side by side, and start the same
// sequence on each without a cast or a parameter in sight.

virtual class axi_lite_env_base extends uvm_env;

  axi_lite_config     master_config;      // issues transactions into the DUT's slave port
  axi_lite_config     slave_config;       // answers the DUT's master port
  axi_lite_sequencer  master_sequencer;   // published by the parameterized subclass
  axi_lite_scoreboard scoreboard;

  // What the slave agent answers from. Held here so a test can preload
  // it, add error regions to it, or read it back, without knowing the
  // port's width.
  axi_lite_mem mem;

  // Human-readable link name, e.g. "A32/D64", used in log lines so a
  // failure names the link it came from.
  string link_desc = "";

  extern function new(string name = "axi_lite_env_base", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

  // Convenience for tests: reprogram this link's backpressure.
  extern virtual function void set_backpressure(axi_lite_channel_e channel,
                                                axi_lite_ready_mode_e mode,
                                                int unsigned percent      = 50,
                                                int unsigned ready_cycles = 1,
                                                int unsigned stall_cycles = 1,
                                                int unsigned burst_beats  = 4,
                                                int unsigned delay_min    = 0,
                                                int unsigned delay_max    = 4);

  // The same model on every channel of both agents, which is what most
  // tests want: the master's response channels and the slave's request
  // channels throttled alike.
  extern virtual function void set_backpressure_all(axi_lite_ready_mode_e mode,
                                                    int unsigned percent      = 50,
                                                    int unsigned ready_cycles = 1,
                                                    int unsigned stall_cycles = 1,
                                                    int unsigned burst_beats  = 4,
                                                    int unsigned delay_min    = 0,
                                                    int unsigned delay_max    = 4);

  // Convenience for tests: reprogram master-side pacing and slave-side
  // answer latency.
  extern virtual function void set_pacing(int unsigned min_cycles, int unsigned max_cycles);
  extern virtual function void set_resp_delay(int unsigned min_cycles, int unsigned max_cycles);

endclass : axi_lite_env_base

function axi_lite_env_base::new(string name = "axi_lite_env_base", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_env_base::build_phase(uvm_phase phase);
  super.build_phase(phase);
  // Configs are created here rather than in the test so that a test only
  // has to override what it cares about, in its own build_phase, before
  // super.build_phase() reaches the agents.
  if (master_config == null) begin
    master_config      = axi_lite_config::type_id::create("master_config");
    master_config.role = AXI_LITE_MASTER;
  end
  if (slave_config == null) begin
    slave_config      = axi_lite_config::type_id::create("slave_config");
    slave_config.role = AXI_LITE_SLAVE;
  end
  if (mem == null)
    mem = axi_lite_mem::type_id::create("mem");
  // An unwritten location reads back as a function of its own address,
  // so an address-decode bug in the path shows up on the very first read
  // rather than only after something has been written there.
  mem.fill_from_address = 1'b1;
  slave_config.mem      = mem;

  scoreboard = axi_lite_scoreboard::type_id::create("scoreboard", this);

  // The scoreboard predicts read data from its own shadow memory, so the
  // two models have to agree on what an address nobody has written yet
  // reads back as -- otherwise the very first read of every location
  // would be reported as a mismatch. Reconciling them here, in the one
  // place that owns both, is what keeps that from being a trap.
  scoreboard.shadow.fill_from_address = mem.fill_from_address;
  scoreboard.shadow.default_byte      = mem.default_byte;
endfunction : build_phase

function void axi_lite_env_base::set_backpressure(axi_lite_channel_e channel,
                                                  axi_lite_ready_mode_e mode,
                                                  int unsigned percent      = 50,
                                                  int unsigned ready_cycles = 1,
                                                  int unsigned stall_cycles = 1,
                                                  int unsigned burst_beats  = 4,
                                                  int unsigned delay_min    = 0,
                                                  int unsigned delay_max    = 4);
  // Each channel belongs to exactly one of the two agents -- the master
  // accepts responses, the slave accepts requests -- so setting it on
  // both configs installs it where it will actually be used and leaves a
  // harmless unused copy on the other.
  master_config.set_ready_mode(channel, mode, percent, ready_cycles, stall_cycles,
                               burst_beats, delay_min, delay_max);
  slave_config.set_ready_mode(channel, mode, percent, ready_cycles, stall_cycles,
                              burst_beats, delay_min, delay_max);
endfunction : set_backpressure

function void axi_lite_env_base::set_backpressure_all(axi_lite_ready_mode_e mode,
                                                      int unsigned percent      = 50,
                                                      int unsigned ready_cycles = 1,
                                                      int unsigned stall_cycles = 1,
                                                      int unsigned burst_beats  = 4,
                                                      int unsigned delay_min    = 0,
                                                      int unsigned delay_max    = 4);
  master_config.set_ready_mode_all(mode, percent, ready_cycles, stall_cycles,
                                   burst_beats, delay_min, delay_max);
  slave_config.set_ready_mode_all(mode, percent, ready_cycles, stall_cycles,
                                  burst_beats, delay_min, delay_max);
endfunction : set_backpressure_all

function void axi_lite_env_base::set_pacing(int unsigned min_cycles, int unsigned max_cycles);
  master_config.set_addr_delay(min_cycles, max_cycles);
  master_config.set_wdata_delay(min_cycles, max_cycles);
endfunction : set_pacing

function void axi_lite_env_base::set_resp_delay(int unsigned min_cycles, int unsigned max_cycles);
  slave_config.set_resp_delay(min_cycles, max_cycles);
endfunction : set_resp_delay


///////////////////////////////////////////////////////////////////
// The parameterized half. Everything width-dependent lives here and
// nowhere else in the testbench.
///////////////////////////////////////////////////////////////////
class axi_lite_env #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) extends axi_lite_env_base;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef axi_lite_agent      #(ADDR_WIDTH, DATA_WIDTH) agent_t;
  typedef axi_lite_env        #(ADDR_WIDTH, DATA_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  agent_t master_agent;   // on the port into the DUT
  agent_t slave_agent;    // on the port out of the DUT

  vif_t vif_src;     // DUT slave port  (UVC issues transactions)
  vif_t vif_snk;     // DUT master port (UVC answers them)

  extern function new(string name = "axi_lite_env", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);

endclass : axi_lite_env

function axi_lite_env::new(string name = "axi_lite_env", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(vif_t)::get(this, "", "vif_src", vif_src))
    `uvm_fatal("NOVIF", $sformatf("no 'vif_src' for %s -- did the link module's name match?",
                                  get_full_name()))
  if (!uvm_config_db#(vif_t)::get(this, "", "vif_snk", vif_snk))
    `uvm_fatal("NOVIF", $sformatf("no 'vif_snk' for %s -- did the link module's name match?",
                                  get_full_name()))

  link_desc = $sformatf("A%0d/D%0d", ADDR_WIDTH, DATA_WIDTH);

  // Each agent gets its own config and its own end of the link. The
  // agent reconciles these widths with its parameters, so a config that
  // disagrees is caught rather than silently truncating addresses.
  uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(axi_lite_config)::set(this, "slave_agent",  "agent_config", slave_config);
  uvm_config_db#(vif_t)::set(this, "master_agent", "vif", vif_src);
  uvm_config_db#(vif_t)::set(this, "slave_agent",  "vif", vif_snk);

  master_agent = agent_t::type_id::create("master_agent", this);
  slave_agent  = agent_t::type_id::create("slave_agent",  this);
endfunction : build_phase

function void axi_lite_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);

  // Publish the sequencer through the unparameterized base, so tests can
  // reach it without knowing this link's width.
  master_sequencer = master_agent.sequencer;

  // Both ends feed the scoreboard: what the UVC issued, and what reached
  // the far side. Both streams come from monitors, never from drivers,
  // so the check is against what the wires actually did.
  master_agent.monitor.request_analysis_port.connect(scoreboard.src_request_export);
  slave_agent.monitor.request_analysis_port.connect(scoreboard.snk_request_export);
  master_agent.monitor.item_analysis_port.connect(scoreboard.src_item_export);
  slave_agent.monitor.item_analysis_port.connect(scoreboard.snk_item_export);
endfunction : connect_phase
