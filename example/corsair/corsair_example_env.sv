///////////////////////////////////////////////////////////////////
// Filename: corsair_example_env.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Environment for the Corsair example: one master agent on the
//           generated block's AXI4-Lite slave port.
///////////////////////////////////////////////////////////////////
//
// The only thing here that differs from example/example_env.sv is that
// the config carries a register model. Everything downstream -- every
// named access in every sequence -- resolves against it, so this is the
// one place a map gets attached to a link.

class corsair_example_env extends uvm_env;

  `uvm_component_utils(corsair_example_env)

  corsair_agent_t master_agent;

  axi_lite_config master_config;

  corsair_vif_t    vif;
  corsair_hw_vif_t hw_vif;

  extern function new(string name = "corsair_example_env", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

endclass : corsair_example_env

function corsair_example_env::new(string name = "corsair_example_env",
                                  uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void corsair_example_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(corsair_vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", "no 'vif' in the config DB")
  if (!uvm_config_db#(corsair_hw_vif_t)::get(this, "", "hw_vif", hw_vif))
    `uvm_fatal("NOHWVIF", "no 'hw_vif' in the config DB")
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "master_config", master_config))
    `uvm_fatal("NOCFG", "no 'master_config' in the config DB")

  uvm_config_db#(axi_lite_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(corsair_vif_t)::set(this, "master_agent", "vif", vif);

  master_agent = corsair_agent_t::type_id::create("master_agent", this);
endfunction : build_phase
