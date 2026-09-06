///////////////////////////////////////////////////////////////////
// Filename: axi_lite_monitor.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM monitor that samples all five AXI4-Lite channels,
//           reassembles them into whole transactions, publishes each
//           twice -- once as a request and once completed -- and turns
//           the interface's protocol assertion failures into UVM errors.
///////////////////////////////////////////////////////////////////
//
// The monitor is passive by construction -- it only ever reads the
// monitor clocking block -- so the same instance works whether the port
// is driven by this UVC, by a DUT, or by two DUTs being observed.
//
// One thread, five channels
// -------------------------
// Everything below runs in a single loop that looks at all five channels
// at each ACLK edge, in a fixed order: requests first, then responses.
// That is not a simplification, it is the correctness argument. A write
// whose AWVALID, WVALID and BVALID all handshake on the same edge is
// legal AXI4-Lite, and with a thread per channel the three would race --
// the response could be processed before the request that explains it,
// depending on nothing more principled than process scheduling order.
// One ordered loop makes the outcome the same on every simulator and
// every run.
//
// Two analysis ports, because the two views answer different questions:
//   request_analysis_port - the transaction as soon as it is fully
//            requested: for a read, at the AR handshake; for a write, at
//            whichever of AW and W completes second. It has no response
//            yet, which is exactly what a predictor wants -- it can
//            model the access before the DUT has answered.
//   item_analysis_port   - the completed transaction, at the B or R
//            handshake, carrying BRESP/RRESP, RDATA, and how many cycles
//            the whole thing took. This is what a scoreboard checks.
//
// AXI4-Lite has no transaction IDs, so responses come back in request
// order and pairing is strictly first-in-first-out. That is why the
// queues below need no matching logic at all -- and it is also why an
// out-of-order slave would show up here as a data mismatch rather than
// being silently tolerated.

class axi_lite_monitor #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) extends uvm_monitor;

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;
  typedef axi_lite_monitor#(ADDR_WIDTH, DATA_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t                                  vif;
  axi_lite_config                        agent_config;

  uvm_analysis_port #(axi_lite_seq_item) request_analysis_port;
  uvm_analysis_port #(axi_lite_seq_item) item_analysis_port;

  int unsigned                           num_writes                 = 0;
  int unsigned                           num_reads                  = 0;
  int unsigned                           num_errors                 = 0;

  // Accepted address phases whose write data has not arrived yet, and
  // accepted write data phases whose address has not. Exactly one of
  // these is non-empty at any moment on a well-behaved port.
  local axi_lite_seq_item                m_aw_q                [$];
  local int unsigned                     m_aw_cycle            [$];
  local axi_lite_wdata_phase_t           m_w_q                 [$];
  local int unsigned                     m_w_stall             [$];

  // Fully requested transactions awaiting their response.
  local axi_lite_seq_item                m_write_pending       [$];
  local int unsigned                     m_write_start         [$];
  local axi_lite_seq_item                m_read_pending        [$];
  local int unsigned                     m_read_start          [$];

  // Running stall counters, reset at each handshake on their channel.
  local int unsigned                     m_aw_stall_now             = 0;
  local int unsigned                     m_w_stall_now              = 0;
  local int unsigned                     m_ar_stall_now             = 0;
  local int unsigned                     m_b_stall_now              = 0;
  local int unsigned                     m_r_stall_now              = 0;

  local int unsigned                     m_cycle                    = 0;

  extern function new(string name = "axi_lite_monitor", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  // The five per-channel samplers, called in this order once per edge.
  extern protected virtual function void sample_aw();
  extern protected virtual function void sample_w();
  extern protected virtual function void sample_ar();
  extern protected virtual function void sample_b();
  extern protected virtual function void sample_r();

  // Pair up any address phase that now has its write data, publishing
  // the completed request.
  extern protected virtual function void pair_writes();

  // A fresh transaction already bound to this port's geometry.
  extern protected virtual function axi_lite_seq_item new_item(string name);

  // Publish a stable snapshot on the request port. A clone, so that a
  // subscriber holding it does not watch it grow a response later.
  extern protected virtual function void publish_request(axi_lite_seq_item item);

  // Warn once per channel when a transfer has been offered for longer
  // than the configured watchdog allows.
  extern protected virtual function void check_stall(string channel, int unsigned stall);

  extern protected virtual function void flush_on_reset();

endclass : axi_lite_monitor

function axi_lite_monitor::new(string name = "axi_lite_monitor", uvm_component parent = null);
  super.new(name, parent);
  request_analysis_port = new("request_analysis_port", this);
  item_analysis_port    = new("item_analysis_port", this);
endfunction : new

function void axi_lite_monitor::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
               "no virtual axi_lite_if #(%0d,%0d) set in the config DB for %s",
               ADDR_WIDTH,
               DATA_WIDTH,
               get_full_name()
               ))
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_lite_config set in the config DB")
endfunction : build_phase

task axi_lite_monitor::run_phase(uvm_phase phase);
  forever begin
    @(vif.mon_cb);

    if (vif.mon_cb.aresetn !== 1'b1) begin
      flush_on_reset();
      continue;
    end

    m_cycle++;

    // Requests before responses, so a transaction that is requested and
    // answered on the same edge is seen in the order it happened.
    sample_aw();
    sample_w();
    sample_ar();
    pair_writes();
    sample_b();
    sample_r();
  end
endtask : run_phase

function axi_lite_seq_item axi_lite_monitor::new_item(string name);
  axi_lite_seq_item item;
  item = axi_lite_seq_item::type_id::create(name);
  item.set_geometry(agent_config);
  return item;
endfunction : new_item

function void axi_lite_monitor::publish_request(axi_lite_seq_item item);
  axi_lite_seq_item snapshot;
  if (!$cast(snapshot, item.clone()))
    `uvm_fatal("CLONE", "clone of a transaction did not yield an axi_lite_seq_item")
  request_analysis_port.write(snapshot);
endfunction : publish_request

function void axi_lite_monitor::check_stall(string channel, int unsigned stall);
  if ((agent_config.stall_timeout_cycles > 0) && (stall == agent_config.stall_timeout_cycles))
    `uvm_error("STALL_TIMEOUT", $sformatf(
               {
                 "the %s channel has been stalled for %0d cycles with VALID high and READY low ",
                 "on %s -- the far side may be deadlocked"
               },
               channel,
               stall,
               vif.path()
               ))
endfunction : check_stall

function void axi_lite_monitor::sample_aw();
  if (vif.mon_cb.awvalid !== 1'b1) return;

  if (vif.mon_cb.awready !== 1'b1) begin
    m_aw_stall_now++;
    check_stall("AW", m_aw_stall_now);
    return;
  end

  begin
    axi_lite_seq_item item = new_item("write");
    item.kind              = AXI_LITE_WRITE;
    item.addr              = axi_lite_addr_t'(vif.mon_cb.awaddr);
    item.prot              = agent_config.has_prot ? axi_lite_prot_t'(vif.mon_cb.awprot) : 3'b000;
    item.addr_stall_cycles = m_aw_stall_now;
    m_aw_q.push_back(item);
    m_aw_cycle.push_back(m_cycle);
  end
  m_aw_stall_now = 0;
endfunction : sample_aw

function void axi_lite_monitor::sample_w();
  if (vif.mon_cb.wvalid !== 1'b1) return;

  if (vif.mon_cb.wready !== 1'b1) begin
    m_w_stall_now++;
    check_stall("W", m_w_stall_now);
    return;
  end

  begin
    axi_lite_wdata_phase_t phase;
    phase.data = axi_lite_data_t'(vif.mon_cb.wdata);
    phase.strb = axi_lite_strb_t'(vif.mon_cb.wstrb);
    m_w_q.push_back(phase);
    m_w_stall.push_back(m_w_stall_now);
  end
  m_w_stall_now = 0;
endfunction : sample_w

function void axi_lite_monitor::sample_ar();
  if (vif.mon_cb.arvalid !== 1'b1) return;

  if (vif.mon_cb.arready !== 1'b1) begin
    m_ar_stall_now++;
    check_stall("AR", m_ar_stall_now);
    return;
  end

  begin
    axi_lite_seq_item item = new_item("read");
    item.kind              = AXI_LITE_READ;
    item.addr              = axi_lite_addr_t'(vif.mon_cb.araddr);
    item.prot              = agent_config.has_prot ? axi_lite_prot_t'(vif.mon_cb.arprot) : 3'b000;
    item.addr_stall_cycles = m_ar_stall_now;
    // A read is fully requested the moment its address is accepted.
    publish_request(item);
    m_read_pending.push_back(item);
    m_read_start.push_back(m_cycle);
  end
  m_ar_stall_now = 0;
endfunction : sample_ar

// A write is fully requested once both halves are in. Whichever arrived
// first waited in its queue, which is why this is a separate step rather
// than something either channel sampler could do on its own.
function void axi_lite_monitor::pair_writes();
  while ((m_aw_q.size() != 0) && (m_w_q.size() != 0)) begin
    axi_lite_seq_item      item = m_aw_q.pop_front();
    axi_lite_wdata_phase_t phase = m_w_q.pop_front();
    int unsigned           start = m_aw_cycle.pop_front();

    item.wdata              = phase.data;
    item.wstrb              = phase.strb;
    item.wdata_stall_cycles = m_w_stall.pop_front();

    publish_request(item);
    m_write_pending.push_back(item);
    m_write_start.push_back(start);
  end
endfunction : pair_writes

function void axi_lite_monitor::sample_b();
  axi_lite_seq_item item;

  if (vif.mon_cb.bvalid !== 1'b1) return;

  if (vif.mon_cb.bready !== 1'b1) begin
    m_b_stall_now++;
    check_stall("B", m_b_stall_now);
    return;
  end

  if (m_write_pending.size() == 0) begin
    // The interface asserts this too (B_WITHOUT_REQUEST); saying it here
    // as well is what stops the monitor silently publishing a response
    // it cannot attribute to anything.
    `uvm_error("B_ORPHAN",
               $sformatf(
                   "a write response completed on %s with no fully requested write outstanding",
                   vif.path()))
    m_b_stall_now = 0;
    return;
  end

  item                   = m_write_pending.pop_front();
  item.resp              = axi_lite_resp_e'(vif.mon_cb.bresp);
  item.has_response      = 1'b1;
  item.resp_stall_cycles = m_b_stall_now;
  item.latency_cycles    = m_cycle - m_write_start.pop_front();
  m_b_stall_now          = 0;

  num_writes++;
  if (item.resp != AXI_LITE_OKAY) num_errors++;
  `uvm_info("MON", item.convert2string(), UVM_HIGH)
  item_analysis_port.write(item);
endfunction : sample_b

function void axi_lite_monitor::sample_r();
  axi_lite_seq_item item;

  if (vif.mon_cb.rvalid !== 1'b1) return;

  if (vif.mon_cb.rready !== 1'b1) begin
    m_r_stall_now++;
    check_stall("R", m_r_stall_now);
    return;
  end

  if (m_read_pending.size() == 0) begin
    `uvm_error("R_ORPHAN", $sformatf("read data completed on %s with no read address outstanding",
                                     vif.path()))
    m_r_stall_now = 0;
    return;
  end

  item                   = m_read_pending.pop_front();
  item.rdata             = axi_lite_data_t'(vif.mon_cb.rdata);
  item.resp              = axi_lite_resp_e'(vif.mon_cb.rresp);
  item.has_response      = 1'b1;
  item.resp_stall_cycles = m_r_stall_now;
  item.latency_cycles    = m_cycle - m_read_start.pop_front();
  m_r_stall_now          = 0;

  num_reads++;
  if (item.resp != AXI_LITE_OKAY) num_errors++;
  `uvm_info("MON", item.convert2string(), UVM_HIGH)
  item_analysis_port.write(item);
endfunction : sample_r

// A transaction interrupted by reset never completes, so it is dropped
// rather than spliced onto whatever comes after reset releases.
function void axi_lite_monitor::flush_on_reset();
  int unsigned n = m_aw_q.size() + m_w_q.size() + m_write_pending.size() + m_read_pending.size();
  if (n != 0)
    `uvm_warning(
        "RESET_FLUSH", $sformatf(
        "ARESETn asserted with %0d transaction(s) in flight on %s; discarding them", n, vif.path()))

  m_aw_q.delete();
  m_aw_cycle.delete();
  m_w_q.delete();
  m_w_stall.delete();
  m_write_pending.delete();
  m_write_start.delete();
  m_read_pending.delete();
  m_read_start.delete();

  m_aw_stall_now = 0;
  m_w_stall_now  = 0;
  m_ar_stall_now = 0;
  m_b_stall_now  = 0;
  m_r_stall_now  = 0;
endfunction : flush_on_reset

// The interface's assertions know nothing about UVM: they count their
// own failures. Turning that count into a UVM_ERROR here is what makes a
// protocol violation fail the test rather than scroll past in a log.
function void axi_lite_monitor::check_phase(uvm_phase phase);
  int unsigned dangling;
  super.check_phase(phase);

  if (vif.protocol_error_count > 0)
    `uvm_error("PROTOCOL", $sformatf(
               "%0d AXI4-Lite protocol assertion failure(s) on %s -- see the $error lines above",
               vif.protocol_error_count,
               vif.path()
               ))

  dangling = m_write_pending.size() + m_read_pending.size();
  if (dangling != 0)
    `uvm_warning("INCOMPLETE", $sformatf(
                 "simulation ended with %0d transaction(s) requested and never answered on %s",
                 dangling,
                 vif.path()
                 ))

  if ((m_aw_q.size() != 0) || (m_w_q.size() != 0))
    `uvm_warning("HALF_WRITE", $sformatf(
                 "simulation ended with %0d write address and %0d write data phase(s) unpaired on %s",
                 m_aw_q.size(),
                 m_w_q.size(),
                 vif.path()
                 ))
endfunction : check_phase

function void axi_lite_monitor::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info(
      "MON", $sformatf(
      "observed %0d writes and %0d reads (%0d error responses)", num_writes, num_reads, num_errors),
      UVM_LOW)
endfunction : report_phase
