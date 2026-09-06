///////////////////////////////////////////////////////////////////
// Filename: axi_lite_agent.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM agent for one end of an AXI4-Lite port. Instantiates the
//           monitor plus, when active, the driver appropriate to the
//           configured role and its sequencer, and reconciles the
//           run-time config with the interface's compile-time widths.
///////////////////////////////////////////////////////////////////
//
// This is the only place where the UVC's two worlds meet.
//
//  - Below it, three classes are parameterized by the port's widths,
//    because they touch a virtual interface and `virtual axi_lite_if
//    #(32,32)` and `#(32,64)` are different types.
//
//  - Above it, everything -- transactions, sequences, the sequencer,
//    the memory model, coverage, and any scoreboard you write -- is
//    unparameterized, so it is written once and reused at every width.
//
// Instantiating one is therefore the only place a width appears:
//
//   axi_lite_agent #(.ADDR_WIDTH(32), .DATA_WIDTH(64)) master_agent;
//
// The role decides which driver exists at all. A master agent issues
// transactions into a DUT's slave port; a slave agent answers a DUT's
// master port out of an axi_lite_mem and is where response latency and
// request backpressure are configured. Either way the monitor is the
// same and always present, so a passive agent still checks the protocol
// and feeds coverage.

class axi_lite_agent #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) extends uvm_agent;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef axi_lite_agent#(ADDR_WIDTH, DATA_WIDTH) this_type;
  typedef axi_lite_master_driver#(ADDR_WIDTH, DATA_WIDTH) master_driver_t;
  typedef axi_lite_slave_driver#(ADDR_WIDTH, DATA_WIDTH) slave_driver_t;
  typedef axi_lite_monitor#(ADDR_WIDTH, DATA_WIDTH) monitor_t;

  `uvm_component_param_utils(this_type)

  vif_t              vif;
  axi_lite_config    agent_config;

  monitor_t          monitor;
  axi_lite_sequencer sequencer;
  master_driver_t    master_driver;  // non-null only when active and AXI_LITE_MASTER
  slave_driver_t     slave_driver;  // non-null only when active and AXI_LITE_SLAVE
  axi_lite_coverage  coverage;

  extern function new(string name = "axi_lite_agent", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);
  extern virtual function void end_of_elaboration_phase(uvm_phase phase);

  // Fill in any bus geometry the config did not state, and reject any it
  // stated wrongly, using this agent's own parameters as the truth.
  extern virtual function void adopt_interface_geometry();

  // Convenience for a testbench that holds the agent handle: the two
  // transaction streams.
  extern virtual function uvm_analysis_port#(axi_lite_seq_item) request_port();
  extern virtual function uvm_analysis_port#(axi_lite_seq_item) item_port();

endclass : axi_lite_agent

function axi_lite_agent::new(string name = "axi_lite_agent", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_agent::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config)) begin
    `uvm_info("CFG", "no axi_lite_config provided; building a default one", UVM_MEDIUM)
    agent_config = axi_lite_config::type_id::create("agent_config");
  end
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
               "no virtual axi_lite_if #(%0d,%0d) set in the config DB for %s",
               ADDR_WIDTH,
               DATA_WIDTH,
               get_full_name()
               ))

  adopt_interface_geometry();

  // uvm_agent reads its own is_active from the config DB; keep the two
  // views of "active" from disagreeing by letting the config win.
  is_active = agent_config.is_active;

  // Hand both down to every child, so a user only ever sets them once,
  // on the agent.
  uvm_config_db#(axi_lite_config)::set(this, "*", "agent_config", agent_config);
  uvm_config_db#(vif_t)::set(this, "*", "vif", vif);

  monitor = monitor_t::type_id::create("monitor", this);

  if (agent_config.coverage_enable) coverage = axi_lite_coverage::type_id::create("coverage", this);

  if (get_is_active() == UVM_ACTIVE) begin
    case (agent_config.role)
      AXI_LITE_MASTER: begin
        // Only the master end takes stimulus, so only it needs a
        // sequencer. A slave agent's behaviour comes from its config and
        // its memory model, not from transactions.
        sequencer     = axi_lite_sequencer::type_id::create("sequencer", this);
        master_driver = master_driver_t::type_id::create("master_driver", this);
      end
      AXI_LITE_SLAVE: begin
        slave_driver = slave_driver_t::type_id::create("slave_driver", this);
      end
      default: `uvm_fatal("ROLE", $sformatf("unhandled role %s", agent_config.role.name()))
    endcase
  end
endfunction : build_phase

function void axi_lite_agent::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if (coverage != null) monitor.item_analysis_port.connect(coverage.analysis_export);
  if (master_driver != null) master_driver.seq_item_port.connect(sequencer.seq_item_export);
  // The slave driver is not sequence-driven: what it accepts and what it
  // answers come from the config and the memory model, not from
  // transactions, so there is deliberately nothing to connect it to.
endfunction : connect_phase

// The config's widths and the agent's parameters describe the same port
// from two directions. Where the config is silent, take the parameters;
// where it disagrees, say so loudly -- a config that claims 32 bits on a
// 64-bit bus would otherwise just quietly truncate every write.
function void axi_lite_agent::adopt_interface_geometry();
  if (agent_config.addr_width != ADDR_WIDTH) begin
    if (agent_config.addr_width != 0)
      `uvm_warning("GEOMETRY", $sformatf(
                   "config says ADDR_WIDTH is %0d but this agent is parameterized for %0d; using %0d",
                   agent_config.addr_width,
                   ADDR_WIDTH,
                   ADDR_WIDTH
                   ))
    agent_config.addr_width = ADDR_WIDTH;
  end
  if (agent_config.data_width != DATA_WIDTH) begin
    if (agent_config.data_width != 0)
      `uvm_warning("GEOMETRY", $sformatf(
                   "config says DATA_WIDTH is %0d but this agent is parameterized for %0d; using %0d",
                   agent_config.data_width,
                   DATA_WIDTH,
                   DATA_WIDTH
                   ))
    agent_config.data_width = DATA_WIDTH;
  end

  // An address window reaching past what the bus can address would ask
  // sequences for addresses the DUT can never see. Clamping it here is
  // the difference between a clear warning and a silent hole in the
  // stimulus.
  if (ADDR_WIDTH < AXI_LITE_MAX_ADDR_WIDTH) begin
    axi_lite_addr_t limit = (axi_lite_addr_t'(1) << ADDR_WIDTH) - 1;
    if (agent_config.addr_hi > limit) begin
      `uvm_warning(
          "GEOMETRY",
          $sformatf(
              "address window ends at 0x%0h but only %0d address bits exist; clamping to 0x%0h",
              agent_config.addr_hi, ADDR_WIDTH, limit))
      agent_config.addr_hi = limit;
    end
  end

  // AWPROT/ARPROT have no width to derive from -- they are always three
  // bits -- so whether this link uses them stays the config's call.
endfunction : adopt_interface_geometry

// Tell the interface which checks are live, so its assertions match this
// link's conventions. Done in end_of_elaboration so it lands before any
// driver or DUT has run.
function void axi_lite_agent::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  vif.configure(.en_checks(agent_config.protocol_checks_enable),
                .en_addr_alignment(agent_config.check_addr_alignment),
                .en_exokay(agent_config.check_exokay), .en_prot(agent_config.has_prot));
  `uvm_info("CFG", $sformatf("%s -> %s", vif.path(), agent_config.convert2string()), UVM_LOW)
endfunction : end_of_elaboration_phase

function uvm_analysis_port#(axi_lite_seq_item) axi_lite_agent::request_port();
  return monitor.request_analysis_port;
endfunction : request_port

function uvm_analysis_port#(axi_lite_seq_item) axi_lite_agent::item_port();
  return monitor.item_analysis_port;
endfunction : item_port
