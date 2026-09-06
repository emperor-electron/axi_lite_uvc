///////////////////////////////////////////////////////////////////
// Filename: axi_lite_sequencer.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM sequencer that arbitrates and dispatches
//           axi_lite_seq_item transactions from sequences to the
//           AXI4-Lite master driver.
///////////////////////////////////////////////////////////////////
//
// Note what is *not* here: any width parameter. Because the transaction
// is unparameterized, so is the sequencer, so a test can hold every
// port's sequencer -- 32-bit, 64-bit, 12-bit address -- in one plain
// queue and start the same sequence on all of them.
//
// The sequencer carries the agent's config so that sequences reached
// through p_sequencer can size their transactions and pick addresses
// from the right window without being handed the config separately.

class axi_lite_sequencer extends uvm_sequencer #(axi_lite_seq_item);

  axi_lite_config agent_config;

  `uvm_component_utils(axi_lite_sequencer)

  extern function new(string name = "axi_lite_sequencer", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

endclass : axi_lite_sequencer

function axi_lite_sequencer::new(string name = "axi_lite_sequencer", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_sequencer::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_lite_config set in the config DB")
endfunction : build_phase
