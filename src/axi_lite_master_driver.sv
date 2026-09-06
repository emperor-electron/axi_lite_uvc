///////////////////////////////////////////////////////////////////
// Filename: axi_lite_master_driver.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM driver for the master end of an AXI4-Lite port: turns
//           axi_lite_seq_item transactions into AW/W/AR activity, takes
//           B and R responses back off the bus, and obeys the handshake
//           and reset rules of AMBA AXI4-Lite.
///////////////////////////////////////////////////////////////////
//
// Use this driver against a DUT's *slave* port -- it is the thing that
// issues transactions.
//
// Five channels, five threads
// ---------------------------
// The single biggest difference from a stream driver is that AXI4-Lite's
// channels are independent. AW, W, AR, B and R each have their own
// handshake and are allowed to run at their own pace, so each gets its
// own thread and its own queue, and a sixth thread takes transactions
// off the sequencer and feeds them in. Writing it as one sequential
// task would silently impose an ordering the protocol does not have --
// most importantly it would make W always follow AW, when AXI explicitly
// permits the write data to arrive first.
//
// Three protocol rules shape the whole thing, and each is easy to break
// by accident:
//
//  1. VALID must never be withdrawn. Once a phase is offered it stays
//     offered, payload frozen, until READY completes the handshake. Each
//     channel's stall loop therefore touches nothing but the clock.
//
//  2. VALID must never depend on READY. A phase is offered because a
//     transaction asked for it, never because the far side looked ready,
//     so this driver cannot express the "wait for READY, then assert
//     VALID" deadlock even if a test asked for it.
//
//  3. VALID must be low during reset, and must still be low on the first
//     ACLK edge after ARESETn releases. wait_reset_release() spends that
//     edge doing nothing, which is exactly what it is for.
//
// Ordering and outstanding transactions
// -------------------------------------
// AXI4-Lite has no transaction IDs, so responses come back in the order
// the requests were issued. That is what makes the two pending queues
// below sufficient: the head of m_b_pending owns the next BRESP, and the
// head of m_r_pending owns the next RDATA, with no matching to do.
//
// agent_config.max_outstanding caps how many transactions are in flight.
// At its default of 1 each transaction completes before the next is
// issued, which is what most AXI4-Lite peripherals expect. Raising it
// is how a slave that claims to pipeline gets tested.
//
// Sequences are answered as soon as a transaction is accepted for
// issue, not when it completes -- otherwise the sequencer would
// serialise everything and max_outstanding could never exceed 1. A
// sequence that needs the answer waits for it on the item itself:
//
//   finish_item(item);
//   item.wait_done();       // returns when B or R came back
//   if (item.resp != AXI_LITE_OKAY) ...

class axi_lite_master_driver #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) extends uvm_driver #(axi_lite_seq_item);

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef axi_lite_master_driver #(ADDR_WIDTH, DATA_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t           vif;
  axi_lite_config agent_config;

  // Transactions issued and transactions actually answered; reported at
  // the end of the run so a hung port is obvious without opening a
  // waveform.
  int unsigned num_writes_issued    = 0;
  int unsigned num_reads_issued     = 0;
  int unsigned num_responses        = 0;
  int unsigned num_error_responses  = 0;
  int unsigned num_aborted          = 0;

  // Per-channel work queues. A transaction is pushed onto the queues its
  // kind needs and popped by the thread that owns that channel.
  local axi_lite_seq_item m_aw_q[$];
  local axi_lite_seq_item m_w_q[$];
  local axi_lite_seq_item m_ar_q[$];

  // Transactions awaiting a response, in issue order.
  local axi_lite_seq_item m_b_pending[$];
  local axi_lite_seq_item m_r_pending[$];
  // Cycle at which each pending transaction's address phase was
  // accepted, pushed and popped in lockstep with the queues above so a
  // response can report the latency it took.
  local int unsigned m_b_start[$];
  local int unsigned m_r_start[$];

  local int unsigned m_in_flight = 0;
  local int unsigned m_cycle     = 0;   // free-running ACLK counter

  extern function new(string name = "axi_lite_master_driver", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  // Put every master-driven signal in its idle state. Legal at any time,
  // since a low VALID means nothing is being offered.
  extern virtual task drive_idle();
  extern virtual task wait_reset_release();

  // The six concurrent threads. Each runs forever; the run loop kills
  // and restarts them across a reset.
  extern protected virtual task cycle_counter();
  extern protected virtual task dispatch_thread();
  extern protected virtual task aw_thread();
  extern protected virtual task w_thread();
  extern protected virtual task ar_thread();
  extern protected virtual task b_thread();
  extern protected virtual task r_thread();

  // Complete everything in flight as aborted, so nothing waiting on
  // wait_done() hangs for the rest of the simulation.
  extern protected virtual function void abort_in_flight();

  // A channel's policy, or a permanently-ready default if the config
  // never named one. Re-read every cycle, so a test can swap the model
  // mid-run and have it take effect.
  extern protected virtual function axi_lite_ready_policy policy_for(axi_lite_channel_e channel);

endclass : axi_lite_master_driver

function axi_lite_master_driver::new(string name = "axi_lite_master_driver",
                                     uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_lite_master_driver::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_lite_if #(%0d,%0d) set in the config DB for %s",
        ADDR_WIDTH, DATA_WIDTH, get_full_name()))
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_lite_config set in the config DB")
  if (ADDR_WIDTH > AXI_LITE_MAX_ADDR_WIDTH)
    `uvm_fatal("ADDRW", $sformatf(
        "ADDR_WIDTH=%0d exceeds AXI_LITE_MAX_ADDR_WIDTH=%0d; raise it in axi_lite_types.sv",
        ADDR_WIDTH, AXI_LITE_MAX_ADDR_WIDTH))
  if (DATA_WIDTH > AXI_LITE_MAX_DATA_WIDTH)
    `uvm_fatal("DATAW", $sformatf(
        "DATA_WIDTH=%0d exceeds AXI_LITE_MAX_DATA_WIDTH=%0d; raise it in axi_lite_types.sv",
        DATA_WIDTH, AXI_LITE_MAX_DATA_WIDTH))
endfunction : build_phase

// The run loop is a reset loop. Everything below it assumes reset is
// away; when ARESETn drops, the whole set of channel threads is killed
// at once and rebuilt, which is both what the hardware does and much
// easier to reason about than teaching six threads to unwind.
task axi_lite_master_driver::run_phase(uvm_phase phase);
  forever begin
    drive_idle();
    wait_reset_release();

    fork
      begin : reset_scope
        fork
          cycle_counter();
          dispatch_thread();
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
    m_aw_q.delete();
    m_w_q.delete();
    m_ar_q.delete();
    abort_in_flight();
  end
endtask : run_phase

task axi_lite_master_driver::drive_idle();
  vif.mst_cb.awvalid <= 1'b0;
  vif.mst_cb.awaddr  <= '0;
  vif.mst_cb.awprot  <= '0;
  vif.mst_cb.wvalid  <= 1'b0;
  vif.mst_cb.wdata   <= '0;
  vif.mst_cb.wstrb   <= '0;
  vif.mst_cb.arvalid <= 1'b0;
  vif.mst_cb.araddr  <= '0;
  vif.mst_cb.arprot  <= '0;
  vif.mst_cb.bready  <= 1'b0;
  vif.mst_cb.rready  <= 1'b0;
endtask : drive_idle

// Rule 3: come out of reset with every VALID low, and spend the first
// post-reset ACLK edge doing nothing, so the earliest edge at which this
// driver can assert a VALID is the one after it.
task axi_lite_master_driver::wait_reset_release();
  if (vif.aresetn !== 1'b1) begin
    `uvm_info("RESET", "waiting for ARESETn to deassert", UVM_MEDIUM)
    wait (vif.aresetn === 1'b1);
  end
  @(vif.mst_cb);
endtask : wait_reset_release

function axi_lite_ready_policy axi_lite_master_driver::policy_for(axi_lite_channel_e channel);
  axi_lite_ready_policy policy = agent_config.get_ready_policy(channel);
  if (policy == null) begin
    // A config that never mentioned backpressure on this channel gets
    // none, rather than some arbitrary default throttle it did not ask
    // for. Installing it back into the config keeps the object stable
    // from cycle to cycle, so the "did the policy change?" test below
    // does not fire every cycle.
    axi_lite_default_ready_policy default_policy;
    default_policy = axi_lite_default_ready_policy::type_id::create(
        $sformatf("ready_policy_%s", channel.name()));
    default_policy.mode = AXI_LITE_READY_ALWAYS;
    agent_config.set_ready_policy(channel, default_policy);
    policy = default_policy;
  end
  return policy;
endfunction : policy_for

task axi_lite_master_driver::cycle_counter();
  forever begin
    @(vif.mst_cb);
    m_cycle++;
  end
endtask : cycle_counter

// Take transactions off the sequencer and file them onto the channels
// they need. item_done() is called as soon as a transaction is accepted
// for issue rather than when it completes, so several can be in flight
// at once; the cap is enforced here, by waiting for a slot.
task axi_lite_master_driver::dispatch_thread();
  forever begin
    seq_item_port.get_next_item(req);

    // Polling on the clock rather than blocking on a semaphore, so a
    // test that changes max_outstanding mid-run is obeyed from the next
    // cycle instead of from the next restart.
    while (m_in_flight >= agent_config.max_outstanding)
      @(vif.mst_cb);

    m_in_flight++;
    if (req.is_write()) begin
      num_writes_issued++;
      m_b_pending.push_back(req);
      m_aw_q.push_back(req);
      m_w_q.push_back(req);
    end
    else begin
      num_reads_issued++;
      m_r_pending.push_back(req);
      m_ar_q.push_back(req);
    end

    seq_item_port.item_done();
  end
endtask : dispatch_thread

task axi_lite_master_driver::aw_thread();
  forever begin
    axi_lite_seq_item item;

    while (m_aw_q.size() == 0)
      @(vif.mst_cb);
    item = m_aw_q.pop_front();

    // Idle gap before the address phase. A legal bubble: AWVALID is low
    // throughout.
    repeat (item.addr_delay) @(vif.mst_cb);

    vif.mst_cb.awaddr  <= item.addr[ADDR_WIDTH-1:0];
    vif.mst_cb.awprot  <= agent_config.has_prot ? item.prot : 3'b000;
    vif.mst_cb.awvalid <= 1'b1;

    // Rule 1: hold everything steady until AWREADY answers. Nothing in
    // this loop writes a payload signal, so stability is structural.
    forever begin
      @(vif.mst_cb);
      if (vif.mst_cb.awready === 1'b1) break;
      item.addr_stall_cycles++;
    end

    m_b_start.push_back(m_cycle);
    vif.mst_cb.awvalid <= 1'b0;
  end
endtask : aw_thread

task axi_lite_master_driver::w_thread();
  forever begin
    axi_lite_seq_item item;

    while (m_w_q.size() == 0)
      @(vif.mst_cb);
    item = m_w_q.pop_front();

    // Independent of the address phase's delay, which is what lets the
    // write data lead the address -- legal AXI4-Lite, and a case plenty
    // of slaves get wrong.
    repeat (item.wdata_delay) @(vif.mst_cb);

    vif.mst_cb.wdata  <= item.wdata[DATA_WIDTH-1:0];
    vif.mst_cb.wstrb  <= item.wstrb[STRB_WIDTH-1:0];
    vif.mst_cb.wvalid <= 1'b1;

    forever begin
      @(vif.mst_cb);
      if (vif.mst_cb.wready === 1'b1) break;
      item.wdata_stall_cycles++;
    end

    vif.mst_cb.wvalid <= 1'b0;
  end
endtask : w_thread

task axi_lite_master_driver::ar_thread();
  forever begin
    axi_lite_seq_item item;

    while (m_ar_q.size() == 0)
      @(vif.mst_cb);
    item = m_ar_q.pop_front();

    repeat (item.addr_delay) @(vif.mst_cb);

    vif.mst_cb.araddr  <= item.addr[ADDR_WIDTH-1:0];
    vif.mst_cb.arprot  <= agent_config.has_prot ? item.prot : 3'b000;
    vif.mst_cb.arvalid <= 1'b1;

    forever begin
      @(vif.mst_cb);
      if (vif.mst_cb.arready === 1'b1) break;
      item.addr_stall_cycles++;
    end

    m_r_start.push_back(m_cycle);
    vif.mst_cb.arvalid <= 1'b0;
  end
endtask : ar_thread

// BREADY comes from a policy, not from a transaction: how fast this
// master accepts write responses is a property of the master, not of
// any one write. The policy is asked for the *next* cycle's BREADY once
// per edge, before this cycle's BVALID can influence it, which makes it
// structurally impossible for a model to create a combinational
// BREADY-from-BVALID path.
task axi_lite_master_driver::b_thread();
  bit cur_ready = 1'b0;
  bit accepted;
  bit next;
  axi_lite_ready_policy policy = policy_for(AXI_LITE_CH_B);

  vif.mst_cb.bready <= 1'b0;
  policy.reset();

  forever begin
    axi_lite_ready_policy configured = policy_for(AXI_LITE_CH_B);
    if (configured != policy) begin
      policy = configured;
      policy.reset();
      `uvm_info("BACKPRESSURE",
                $sformatf("B-channel backpressure changed to %s", policy.convert2string()),
                UVM_MEDIUM)
    end

    accepted = (vif.mst_cb.bvalid === 1'b1) && cur_ready;
    if (accepted) begin
      if (m_b_pending.size() == 0) begin
        `uvm_error("B_UNEXPECTED",
                   "a write response arrived with no write outstanding on this master")
      end
      else begin
        axi_lite_seq_item item = m_b_pending.pop_front();
        item.resp           = axi_lite_resp_e'(vif.mst_cb.bresp);
        item.has_response   = 1'b1;
        item.latency_cycles = (m_b_start.size() == 0) ? 0 : (m_cycle - m_b_start.pop_front());
        num_responses++;
        if (item.resp != AXI_LITE_OKAY) num_error_responses++;
        m_in_flight--;
        item.set_done();
        `uvm_info("DRV", $sformatf("write complete: %s", item.convert2string()), UVM_HIGH)
      end
    end
    else if ((vif.mst_cb.bvalid === 1'b1) && (m_b_pending.size() != 0)) begin
      m_b_pending[0].resp_stall_cycles++;
    end

    next = policy.next_ready(.valid(vif.mst_cb.bvalid === 1'b1), .accepted(accepted));
    vif.mst_cb.bready <= next;
    cur_ready         = next;
    @(vif.mst_cb);
  end
endtask : b_thread

task axi_lite_master_driver::r_thread();
  bit cur_ready = 1'b0;
  bit accepted;
  bit next;
  axi_lite_ready_policy policy = policy_for(AXI_LITE_CH_R);

  vif.mst_cb.rready <= 1'b0;
  policy.reset();

  forever begin
    axi_lite_ready_policy configured = policy_for(AXI_LITE_CH_R);
    if (configured != policy) begin
      policy = configured;
      policy.reset();
      `uvm_info("BACKPRESSURE",
                $sformatf("R-channel backpressure changed to %s", policy.convert2string()),
                UVM_MEDIUM)
    end

    accepted = (vif.mst_cb.rvalid === 1'b1) && cur_ready;
    if (accepted) begin
      if (m_r_pending.size() == 0) begin
        `uvm_error("R_UNEXPECTED",
                   "read data arrived with no read outstanding on this master")
      end
      else begin
        axi_lite_seq_item item = m_r_pending.pop_front();
        item.rdata          = axi_lite_data_t'(vif.mst_cb.rdata);
        item.resp           = axi_lite_resp_e'(vif.mst_cb.rresp);
        item.has_response   = 1'b1;
        item.latency_cycles = (m_r_start.size() == 0) ? 0 : (m_cycle - m_r_start.pop_front());
        num_responses++;
        if (item.resp != AXI_LITE_OKAY) num_error_responses++;
        m_in_flight--;
        item.set_done();
        `uvm_info("DRV", $sformatf("read complete: %s", item.convert2string()), UVM_HIGH)
      end
    end
    else if ((vif.mst_cb.rvalid === 1'b1) && (m_r_pending.size() != 0)) begin
      m_r_pending[0].resp_stall_cycles++;
    end

    next = policy.next_ready(.valid(vif.mst_cb.rvalid === 1'b1), .accepted(accepted));
    vif.mst_cb.rready <= next;
    cur_ready         = next;
    @(vif.mst_cb);
  end
endtask : r_thread

// A transaction interrupted by reset never gets an answer, so the only
// honest thing to do is mark it aborted and release anything waiting on
// it. Leaving it pending would hang the sequence that issued it.
function void axi_lite_master_driver::abort_in_flight();
  int unsigned n = m_b_pending.size() + m_r_pending.size();
  if (n != 0)
    `uvm_warning("RESET_ABORT", $sformatf(
        "ARESETn asserted with %0d transaction(s) outstanding; all are abandoned", n))

  foreach (m_b_pending[i]) begin
    m_b_pending[i].aborted = 1'b1;
    m_b_pending[i].set_done();
  end
  foreach (m_r_pending[i]) begin
    m_r_pending[i].aborted = 1'b1;
    m_r_pending[i].set_done();
  end
  num_aborted += n;

  m_b_pending.delete();
  m_r_pending.delete();
  m_b_start.delete();
  m_r_start.delete();
  m_in_flight = 0;
endfunction : abort_in_flight

function void axi_lite_master_driver::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("DRV", $sformatf(
      "issued %0d writes and %0d reads; %0d answered (%0d with an error response), %0d abandoned by reset",
      num_writes_issued, num_reads_issued, num_responses, num_error_responses, num_aborted), UVM_LOW)
endfunction : report_phase
