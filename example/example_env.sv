///////////////////////////////////////////////////////////////////
// Filename: example_env.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Example environment: one master agent driving the DUT's
//           AXI4-Lite slave port, and a scoreboard modelling the
//           register map behind it.
///////////////////////////////////////////////////////////////////
//
// One agent, because the DUT has one AXI4-Lite port and it is a slave
// port. That is the common case: a peripheral's control interface, with
// the testbench playing the CPU.
//
// If your DUT also has a *master* port -- an AXI4-Lite bridge, a DMA
// engine's control path, anything that issues transactions of its own --
// add a second agent whose config has `role = AXI_LITE_SLAVE`, give it
// an axi_lite_mem to answer from, and you have a whole peripheral
// modelled without writing a line of RTL. tb/axi_lite_env.sv shows that
// shape, with a master agent on one side of the DUT and a slave agent on
// the other.
//
// This env is not parameterized: it names example_agent_t from
// example_tb_pkg, which has the widths baked in. That is the right shape
// when your testbench has one port geometry. If you need several live at
// once, tb/axi_lite_env.sv again shows the pattern -- an unparameterized
// base class holding everything a test touches, plus a parameterized
// subclass that adds the agents.

class example_env extends uvm_env;

  `uvm_component_utils(example_env)

  example_agent_t    master_agent;   // drives the DUT's slave port
  example_scoreboard scoreboard;

  axi_lite_config master_config;

  example_vif_t vif;

  extern function new(string name = "example_env", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);

endclass : example_env

function example_env::new(string name = "example_env", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 1 -- collect the interface the top module published, and the
  //           config the test built. The field names match what
  //           example_tb_top.sv and example_base_test.sv set.
  // ---------------------------------------------------------------------
  if (!uvm_config_db#(example_vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", {"no 'vif' in the config DB -- check that the type parameters ",
                         "in example_tb_top's set() match example_vif_t exactly"})
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "master_config", master_config))
    `uvm_fatal("NOCFG", "no 'master_config' in the config DB")

  // ---------------------------------------------------------------------
  // STEP 2 -- give the agent its config and its interface. An agent
  //           expects exactly two things under its own instance name:
  //           "agent_config" and "vif".
  //
  // The agent cross-checks the config's widths against its own type
  // parameters at build time, so a config that disagrees is reported
  // rather than silently truncating addresses.
  // ---------------------------------------------------------------------
  uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(example_vif_t)::set(this, "master_agent", "vif", vif);

  // ---------------------------------------------------------------------
  // STEP 3 -- build the agent and the scoreboard.
  // ---------------------------------------------------------------------
  master_agent = example_agent_t::type_id::create("master_agent", this);
  scoreboard   = example_scoreboard::type_id::create("scoreboard", this);
endfunction : build_phase

function void example_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 4 -- subscribe to the monitor. item_analysis_port carries
  //           completed transactions, which is what a scoreboard checks;
  //           see example_scoreboard.sv for when the other port is the
  //           one you want. The monitor publishes regardless of role, so
  //           a passive agent still feeds checks and coverage.
  // ---------------------------------------------------------------------
  master_agent.monitor.item_analysis_port.connect(scoreboard.analysis_export);

  // The scoreboard only needs this for its clock.
  scoreboard.vif = vif;
endfunction : connect_phase
