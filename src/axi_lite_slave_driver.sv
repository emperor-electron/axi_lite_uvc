///////////////////////////////////////////////////////////////////
// Filename: axi_lite_slave_driver.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM driver for the slave end of an AXI4-Lite port. It
//           accepts AW/W/AR at whatever rate its backpressure policies
//           allow, serves each access out of the configured
//           axi_lite_mem, and returns B and R responses.
///////////////////////////////////////////////////////////////////
//
// Use this driver against a DUT's *master* port.
//
// Unlike the master driver, this one is not sequence-driven. What a
// slave does is decided entirely by configuration -- how fast it accepts
// (the three request-channel ready policies), how long it takes to
// answer (min/max_resp_delay) and what it answers with (the
// axi_lite_mem) -- so the agent's sequencer stays unused on this side:
//
//   slave_config.set_ready_mode(AXI_LITE_CH_AW, AXI_LITE_READY_RANDOM, .percent(60));
//   slave_config.set_resp_delay(1, 4);
//   slave_config.mem = my_peripheral_model;
//
// Answering, not just accepting
// -----------------------------
// This is the part a stream UVC has no equivalent of. A write is only
// serviceable once *both* its address and its data have arrived, and
// AXI4-Lite lets them arrive in either order and at unrelated rates, so
// the two request channels are captured into separate queues and paired
// by the response thread. AXI4-Lite has no transaction IDs, so pairing
// is strictly first-in-first-out and needs no matching logic.
//
// Every ready policy is asked for the *next* cycle's READY once per ACLK
// edge, before this cycle's VALID can influence it. That one-cycle
// offset is deliberate: it makes it structurally impossible for a
// backpressure model to create a combinational READY-from-VALID path,
// which is the classic way a testbench accidentally hides a deadlock
// that real hardware would hit.

class axi_lite_slave_driver #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) extends uvm_driver #(axi_lite_seq_item);

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef axi_lite_slave_driver #(ADDR_WIDTH, DATA_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t           vif;
  axi_lite_config agent_config;
  axi_lite_mem    mem;

  // Census, reported at the end of the run: what this slave was asked
  // for, and how often it had to say no.
  int unsigned num_writes_served   = 0;
  int unsigned num_reads_served    = 0;
  int unsigned num_error_responses = 0;

  // Per-channel READY census: cycles this slave was willing to accept,
  // out of cycles it was running. Reported at the end of the run,
  // because the ratio is the backpressure the DUT actually saw -- which
  // is the only way to tell a configured ready model from one that
  // silently did nothing, and worth knowing when a random policy makes
  // every seed a different experiment.
  int unsigned num_cycles_ready[axi_lite_channel_e];
  int unsigned num_cycles_total[axi_lite_channel_e];

  // Accepted-but-not-yet-serviced request phases, in arrival order.
  local axi_lite_addr_phase_t  m_aw_q[$];
  local axi_lite_wdata_phase_t m_w_q[$];
  local axi_lite_addr_phase_t  m_ar_q[$];

  extern function new(string name = "axi_lite_slave_driver", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  extern virtual task drive_idle();
  extern virtual task wait_reset_release();

  // One thread per channel. The three request channels accept; the two
  // response channels answer.
  extern protected virtual task aw_thread();
  extern protected virtual task w_thread();
  extern protected virtual task ar_thread();
  extern protected virtual task b_thread();
  extern protected virtual task r_thread();

  extern protected virtual function axi_lite_ready_policy policy_for(axi_lite_channel_e channel);
  extern protected virtual function int unsigned draw_resp_delay();
  extern protected virtual function void count_cycle(axi_lite_channel_e channel, bit ready);
  extern protected virtual function string ready_census(axi_lite_channel_e channel);

endclass : axi_lite_slave_driver

function axi_lite_slave_driver::new(string name = "axi_lite_slave_driver",
                                    uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_slave_driver::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_lite_if #(%0d,%0d) set in the config DB for %s",
        ADDR_WIDTH, DATA_WIDTH, get_full_name()))
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_lite_config set in the config DB")

  // A slave with no model would have nothing to answer with, so one is
  // built rather than leaving the port silent. Sharing a handle between
  // agents is how two ports end up backed by the same memory.
  if (agent_config.mem == null) begin
    `uvm_info("MEM", "no axi_lite_mem provided; building an empty one", UVM_MEDIUM)
    agent_config.mem = axi_lite_mem::type_id::create("mem");
  end
  mem = agent_config.mem;
endfunction : build_phase

// Like the master driver, the run loop is a reset loop: the five channel
// threads are killed together when ARESETn drops and rebuilt when it
// releases, which is both what the hardware does and much easier to
// reason about than unwinding five threads individually.
task axi_lite_slave_driver::run_phase(uvm_phase phase);
  forever begin
    drive_idle();
    wait_reset_release();

    fork
      begin : reset_scope
        fork
          aw_thread();
          w_thread();
          ar_thread();
          b_thread();
          r_thread();
          @(negedge vif.aresetn);
        join_any
        disable fork;
      end : reset_scope
    join

    `uvm_info("RESET", "ARESETn asserted; dropping every channel", UVM_MEDIUM)
    drive_idle();
    // Requests accepted but not yet answered are abandoned: after reset
    // the master will not be waiting for them either.
    if ((m_aw_q.size() + m_w_q.size() + m_ar_q.size()) != 0)
      `uvm_info("RESET", $sformatf(
          "discarding %0d write address, %0d write data and %0d read address phase(s) accepted before reset",
          m_aw_q.size(), m_w_q.size(), m_ar_q.size()), UVM_MEDIUM)
    m_aw_q.delete();
    m_w_q.delete();
    m_ar_q.delete();
  end
endtask : run_phase

task axi_lite_slave_driver::drive_idle();
  vif.slv_cb.awready <= 1'b0;
  vif.slv_cb.wready  <= 1'b0;
  vif.slv_cb.arready <= 1'b0;
  vif.slv_cb.bvalid  <= 1'b0;
  vif.slv_cb.bresp   <= 2'b00;
  vif.slv_cb.rvalid  <= 1'b0;
  vif.slv_cb.rdata   <= '0;
  vif.slv_cb.rresp   <= 2'b00;
endtask : drive_idle

task axi_lite_slave_driver::wait_reset_release();
  if (vif.aresetn !== 1'b1) begin
    `uvm_info("RESET", "waiting for ARESETn to deassert", UVM_MEDIUM)
    wait (vif.aresetn === 1'b1);
  end
  @(vif.slv_cb);
endtask : wait_reset_release

function axi_lite_ready_policy axi_lite_slave_driver::policy_for(axi_lite_channel_e channel);
  axi_lite_ready_policy policy = agent_config.get_ready_policy(channel);
  if (policy == null) begin
    axi_lite_default_ready_policy default_policy;
    default_policy = axi_lite_default_ready_policy::type_id::create(
        $sformatf("ready_policy_%s", channel.name()));
    default_policy.mode = AXI_LITE_READY_ALWAYS;
    agent_config.set_ready_policy(channel, default_policy);
    policy = default_policy;
  end
  return policy;
endfunction : policy_for

function int unsigned axi_lite_slave_driver::draw_resp_delay();
  if (agent_config.max_resp_delay <= agent_config.min_resp_delay)
    return agent_config.min_resp_delay;
  return $urandom_range(agent_config.max_resp_delay, agent_config.min_resp_delay);
endfunction : draw_resp_delay

// ---------------------------------------------------------------------
// Request channels. All three have the same shape: decide this cycle's
// acceptance from the value already on the wire, capture the payload if
// a handshake completed, then ask the policy for the next cycle's READY.
// ---------------------------------------------------------------------
task axi_lite_slave_driver::aw_thread();
  bit cur_ready = 1'b0;
  bit accepted;
  bit next;
  axi_lite_ready_policy policy = policy_for(AXI_LITE_CH_AW);

  vif.slv_cb.awready <= 1'b0;
  policy.reset();

  forever begin
    axi_lite_ready_policy configured = policy_for(AXI_LITE_CH_AW);
    if (configured != policy) begin
      policy = configured;
      policy.reset();
    end

    count_cycle(AXI_LITE_CH_AW, cur_ready);
    accepted = (vif.slv_cb.awvalid === 1'b1) && cur_ready;
    if (accepted) begin
      axi_lite_addr_phase_t phase;
      phase.addr = axi_lite_addr_t'(vif.slv_cb.awaddr);
      phase.prot = agent_config.has_prot ? axi_lite_prot_t'(vif.slv_cb.awprot) : 3'b000;
      m_aw_q.push_back(phase);
    end

    next = policy.next_ready(.valid(vif.slv_cb.awvalid === 1'b1), .accepted(accepted));
    vif.slv_cb.awready <= next;
    cur_ready          = next;
    @(vif.slv_cb);
  end
endtask : aw_thread

task axi_lite_slave_driver::w_thread();
  bit cur_ready = 1'b0;
  bit accepted;
  bit next;
  axi_lite_ready_policy policy = policy_for(AXI_LITE_CH_W);

  vif.slv_cb.wready <= 1'b0;
  policy.reset();

  forever begin
    axi_lite_ready_policy configured = policy_for(AXI_LITE_CH_W);
    if (configured != policy) begin
      policy = configured;
      policy.reset();
    end

    count_cycle(AXI_LITE_CH_W, cur_ready);
    accepted = (vif.slv_cb.wvalid === 1'b1) && cur_ready;
    if (accepted) begin
      axi_lite_wdata_phase_t phase;
      phase.data = axi_lite_data_t'(vif.slv_cb.wdata);
      phase.strb = axi_lite_strb_t'(vif.slv_cb.wstrb);
      m_w_q.push_back(phase);
    end

    next = policy.next_ready(.valid(vif.slv_cb.wvalid === 1'b1), .accepted(accepted));
    vif.slv_cb.wready <= next;
    cur_ready         = next;
    @(vif.slv_cb);
  end
endtask : w_thread

task axi_lite_slave_driver::ar_thread();
  bit cur_ready = 1'b0;
  bit accepted;
  bit next;
  axi_lite_ready_policy policy = policy_for(AXI_LITE_CH_AR);

  vif.slv_cb.arready <= 1'b0;
  policy.reset();

  forever begin
    axi_lite_ready_policy configured = policy_for(AXI_LITE_CH_AR);
    if (configured != policy) begin
      policy = configured;
      policy.reset();
    end

    count_cycle(AXI_LITE_CH_AR, cur_ready);
    accepted = (vif.slv_cb.arvalid === 1'b1) && cur_ready;
    if (accepted) begin
      axi_lite_addr_phase_t phase;
      phase.addr = axi_lite_addr_t'(vif.slv_cb.araddr);
      phase.prot = agent_config.has_prot ? axi_lite_prot_t'(vif.slv_cb.arprot) : 3'b000;
      m_ar_q.push_back(phase);
    end

    next = policy.next_ready(.valid(vif.slv_cb.arvalid === 1'b1), .accepted(accepted));
    vif.slv_cb.arready <= next;
    cur_ready          = next;
    @(vif.slv_cb);
  end
endtask : ar_thread

// ---------------------------------------------------------------------
// Response channels. Both wait for the work they need to exist, apply
// the access to the memory model, wait out the configured answer delay,
// then hold VALID until the master takes the response.
// ---------------------------------------------------------------------
task axi_lite_slave_driver::b_thread();
  forever begin
    axi_lite_addr_phase_t  aw;
    axi_lite_wdata_phase_t w;
    axi_lite_resp_e        resp;

    // A write is serviceable only once both halves have arrived, and
    // AXI4-Lite lets them arrive in either order.
    while ((m_aw_q.size() == 0) || (m_w_q.size() == 0))
      @(vif.slv_cb);

    aw = m_aw_q.pop_front();
    w  = m_w_q.pop_front();

    // The access happens before the answer delay, not after, so that a
    // read issued behind a slow write response still sees the written
    // value -- which is what a real register file does.
    resp = mem.write(aw.addr, w.data, w.strb, STRB_WIDTH, aw.prot);
    num_writes_served++;
    if (resp != AXI_LITE_OKAY) num_error_responses++;
    `uvm_info("SLV", $sformatf("write 0x%0h <= 0x%0h (strb 0b%0b) -> %s",
                               aw.addr, w.data, w.strb, resp.name()), UVM_HIGH)

    repeat (draw_resp_delay()) @(vif.slv_cb);

    vif.slv_cb.bresp  <= resp;
    vif.slv_cb.bvalid <= 1'b1;

    // BVALID may not be withdrawn, so this loop touches nothing but the
    // clock until BREADY answers.
    forever begin
      @(vif.slv_cb);
      if (vif.slv_cb.bready === 1'b1) break;
    end

    vif.slv_cb.bvalid <= 1'b0;
  end
endtask : b_thread

task axi_lite_slave_driver::r_thread();
  forever begin
    axi_lite_addr_phase_t ar;
    axi_lite_data_t       data;
    axi_lite_resp_e       resp;

    while (m_ar_q.size() == 0)
      @(vif.slv_cb);

    ar   = m_ar_q.pop_front();
    resp = mem.read(ar.addr, STRB_WIDTH, ar.prot, data);
    num_reads_served++;
    if (resp != AXI_LITE_OKAY) num_error_responses++;
    `uvm_info("SLV", $sformatf("read 0x%0h => 0x%0h -> %s", ar.addr, data, resp.name()), UVM_HIGH)

    repeat (draw_resp_delay()) @(vif.slv_cb);

    vif.slv_cb.rdata  <= data[DATA_WIDTH-1:0];
    vif.slv_cb.rresp  <= resp;
    vif.slv_cb.rvalid <= 1'b1;

    forever begin
      @(vif.slv_cb);
      if (vif.slv_cb.rready === 1'b1) break;
    end

    vif.slv_cb.rvalid <= 1'b0;
  end
endtask : r_thread

function void axi_lite_slave_driver::count_cycle(axi_lite_channel_e channel, bit ready);
  if (!num_cycles_total.exists(channel)) begin
    num_cycles_total[channel] = 0;
    num_cycles_ready[channel] = 0;
  end
  num_cycles_total[channel]++;
  if (ready) num_cycles_ready[channel]++;
endfunction : count_cycle

function string axi_lite_slave_driver::ready_census(axi_lite_channel_e channel);
  int unsigned total = num_cycles_total.exists(channel) ? num_cycles_total[channel] : 0;
  int unsigned high  = num_cycles_ready.exists(channel) ? num_cycles_ready[channel] : 0;
  return $sformatf("%s %0d/%0d (%0d%%)", axi_lite_short_name(channel.name(), 12),
                   high, total, (total == 0) ? 0 : (100 * high) / total);
endfunction : ready_census

function void axi_lite_slave_driver::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SLV", $sformatf("served %0d writes and %0d reads (%0d answered with an error); memory holds %0d bytes",
                             num_writes_served, num_reads_served, num_error_responses,
                             (mem == null) ? 0 : mem.num_bytes_written()), UVM_LOW)
  `uvm_info("SLV", $sformatf("READY high on %s, %s, %s",
                             ready_census(AXI_LITE_CH_AW),
                             ready_census(AXI_LITE_CH_W),
                             ready_census(AXI_LITE_CH_AR)), UVM_LOW)
endfunction : report_phase
