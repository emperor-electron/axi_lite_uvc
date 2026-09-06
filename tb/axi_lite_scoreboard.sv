///////////////////////////////////////////////////////////////////
// Filename: axi_lite_scoreboard.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Checks one link of the self-test: every transaction the UVC
//           issues must cross the register slice unchanged, come back
//           with the response the slave agent gave it, and read back
//           whatever was last written to that address.
///////////////////////////////////////////////////////////////////
//
// This is where the UVC gets graded. The DUT is a register slice, so the
// expected output is exactly the input -- which means any difference is
// the UVC mis-driving, mis-sampling, or losing a transaction, and the
// scoreboard can be a strict identity check rather than a model.
//
// Three checks, because they fail differently:
//
//   requests   - what left the master, field for field, against what
//                arrived at the slave. Catches a driver that mangles an
//                address, a strobe or a protection bit, and a monitor
//                that pairs AW with the wrong W.
//   responses  - what the slave answered against what the master
//                received. Catches a lost or misrouted response, and a
//                master driver that attributes B or R to the wrong
//                transaction.
//   data       - every read checked against a shadow of every write.
//                This is the only check that exercises the whole loop
//                at once: master driver, DUT, slave driver, memory
//                model and back. A byte lane swapped anywhere in that
//                path shows up here and nowhere else.
//
// Note what it does *not* compare: latency and the stall counts. Those
// describe when a transaction happened, not what it carried; a register
// slice is free to re-pace traffic and still be correct.
//
// Reads and writes are tracked in separate queues throughout. AXI4-Lite
// keeps its read and write channels independent, so a read may legally
// overtake a write in flight -- putting both in one queue would report
// that legal reordering as a failure.

`uvm_analysis_imp_decl(_src_request)
`uvm_analysis_imp_decl(_snk_request)
`uvm_analysis_imp_decl(_src_item)
`uvm_analysis_imp_decl(_snk_item)

class axi_lite_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(axi_lite_scoreboard)

  uvm_analysis_imp_src_request #(axi_lite_seq_item, axi_lite_scoreboard) src_request_export;
  uvm_analysis_imp_snk_request #(axi_lite_seq_item, axi_lite_scoreboard) snk_request_export;
  uvm_analysis_imp_src_item    #(axi_lite_seq_item, axi_lite_scoreboard) src_item_export;
  uvm_analysis_imp_snk_item    #(axi_lite_seq_item, axi_lite_scoreboard) snk_item_export;

  // Requests seen leaving the master, awaiting their arrival at the slave.
  local axi_lite_seq_item m_write_requests[$];
  local axi_lite_seq_item m_read_requests[$];

  // Completions seen at the slave, awaiting their arrival back at the
  // master. The response travels slave-to-master, so the slave side is
  // the expectation and the master side is what is checked.
  local axi_lite_seq_item m_write_responses[$];
  local axi_lite_seq_item m_read_responses[$];

  // A shadow of every write the master completed successfully, used to
  // predict what a later read should return. An axi_lite_mem rather than
  // a hand-rolled array, so the byte-strobe semantics here are the same
  // implementation the slave agent uses -- one place to be right.
  //
  // Public, and built in new() rather than build_phase(), because the
  // env has to reconcile it with the slave agent's memory as soon as the
  // scoreboard exists: the two must agree on what an *unwritten* address
  // reads back as, or every first read of a location would be reported
  // as a mismatch. See axi_lite_env_base::build_phase.
  axi_lite_mem shadow;

  // Writes currently in flight, per address, and the machinery for
  // deciding whether a read's data can be predicted at all.
  //
  // AXI4-Lite's read and write channels are independent and have no
  // ordering between them, so a read and a write to the same address
  // that overlap have no defined outcome: the slave may service either
  // first, and the order their responses come back in says nothing about
  // the order it serviced them. Predicting such a read would be checking
  // a race, not the DUT.
  //
  // A read is therefore checkable exactly when no write to its address
  // was in flight at any point during its life -- not merely at the
  // moment it completed, which is the narrower and wrong test. That
  // needs two things: the state at the read's request, and notice of any
  // write to the same address issued while the read is still out.
  //
  // Reads complete in the order they were issued (AXI4-Lite has no
  // transaction IDs, so it has no choice), which is what lets the taint
  // ride along in a plain queue instead of being matched to an object.
  local int unsigned    m_writes_in_flight[axi_lite_addr_t];
  local axi_lite_addr_t m_read_addrs[$];
  local bit             m_read_tainted[$];

  // Transactions the master has issued and not yet had answered.
  //
  // Queue emptiness alone is not enough to say the link has drained, and
  // the gap is easy to miss: between the cycle a request reaches the
  // slave and the cycle the slave answers it, every queue above is empty
  // while the transaction is very much still in flight. A test that
  // stopped there would end mid-transaction and report the response it
  // never waited for as lost -- which is exactly what happened before
  // this counter existed, on the pipelined test and on no other, since
  // only there does a sequence finish while transactions are still out.
  int unsigned num_outstanding = 0;

  int unsigned num_requests_matched  = 0;
  int unsigned num_requests_failed   = 0;
  int unsigned num_responses_matched = 0;
  int unsigned num_responses_failed  = 0;
  int unsigned num_data_matched      = 0;
  int unsigned num_data_failed       = 0;
  int unsigned num_data_skipped      = 0;

  // Cleared while a test is deliberately disturbing the link (a mid-run
  // reset, say), where transactions are expected to be lost and
  // comparing them would report the test's own stimulus as a failure.
  bit checking_enabled = 1'b1;

  // Cleared for a link whose slave deliberately answers with something
  // other than the last value written -- an error region, say.
  bit check_data = 1'b1;

  extern function new(string name = "axi_lite_scoreboard", uvm_component parent = null);

  // True once everything that went in has come back out.
  extern virtual function bit is_drained();

  // Forget all outstanding expectations, for use after a disturbance.
  extern virtual function void flush();

  extern virtual function void write_src_request(axi_lite_seq_item t);
  extern virtual function void write_snk_request(axi_lite_seq_item t);
  extern virtual function void write_src_item(axi_lite_seq_item t);
  extern virtual function void write_snk_item(axi_lite_seq_item t);

  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  // Compare one pair, reporting through `what` so the message says which
  // of the three checks failed.
  extern protected virtual function void compare_pair(string what,
                                                      axi_lite_seq_item expected,
                                                      axi_lite_seq_item actual,
                                                      ref int unsigned matched,
                                                      ref int unsigned failed);

  extern protected virtual function void predict_write(axi_lite_seq_item item);
  extern protected virtual function void check_read(axi_lite_seq_item item);

endclass : axi_lite_scoreboard

function axi_lite_scoreboard::new(string name = "axi_lite_scoreboard",
                                  uvm_component parent = null);
  super.new(name, parent);
  src_request_export = new("src_request_export", this);
  snk_request_export = new("snk_request_export", this);
  src_item_export    = new("src_item_export",    this);
  snk_item_export    = new("snk_item_export",    this);
  shadow             = axi_lite_mem::type_id::create("shadow");
endfunction : new

function bit axi_lite_scoreboard::is_drained();
  return (num_outstanding == 0) &&
         (m_write_requests.size() == 0) && (m_read_requests.size() == 0) &&
         (m_write_responses.size() == 0) && (m_read_responses.size() == 0);
endfunction : is_drained

function void axi_lite_scoreboard::flush();
  if (!is_drained())
    `uvm_info("SB", $sformatf(
        "flushing %0d/%0d pending request(s) and %0d/%0d pending response(s)",
        m_write_requests.size(), m_read_requests.size(),
        m_write_responses.size(), m_read_responses.size()), UVM_MEDIUM)
  m_write_requests.delete();
  m_read_requests.delete();
  m_write_responses.delete();
  m_read_responses.delete();
  m_writes_in_flight.delete();
  m_read_addrs.delete();
  m_read_tainted.delete();
  num_outstanding = 0;
endfunction : flush

function void axi_lite_scoreboard::compare_pair(string what,
                                                axi_lite_seq_item expected,
                                                axi_lite_seq_item actual,
                                                ref int unsigned matched,
                                                ref int unsigned failed);
  if (!actual.compare(expected)) begin
    `uvm_error("SB", $sformatf("%s mismatch\n  expected: %s\n  actual  : %s",
                               what, expected.convert2string(), actual.convert2string()))
    failed++;
  end
  else begin
    matched++;
  end
endfunction : compare_pair

// ---------------------------------------------------------------------
// Requests: master side is the expectation, slave side is what is checked.
// ---------------------------------------------------------------------
function void axi_lite_scoreboard::write_src_request(axi_lite_seq_item t);
  if (!checking_enabled) return;
  num_outstanding++;
  if (t.is_write()) begin
    m_write_requests.push_back(t);
    // Remember that this address is being written...
    if (m_writes_in_flight.exists(t.addr)) m_writes_in_flight[t.addr]++;
    else                                   m_writes_in_flight[t.addr] = 1;
    // ...and that any read to it already in flight can no longer be
    // predicted, since this write may or may not land before that read
    // is serviced.
    foreach (m_read_addrs[i])
      if (m_read_addrs[i] == t.addr)
        m_read_tainted[i] = 1'b1;
  end
  else begin
    m_read_requests.push_back(t);
    m_read_addrs.push_back(t.addr);
    // Tainted from birth if a write to this address is already out.
    m_read_tainted.push_back(m_writes_in_flight.exists(t.addr));
  end
endfunction : write_src_request

function void axi_lite_scoreboard::write_snk_request(axi_lite_seq_item t);
  axi_lite_seq_item expected;
  if (!checking_enabled) return;

  if (t.is_write()) begin
    if (m_write_requests.size() == 0) begin
      `uvm_error("SB", $sformatf("a write reached the slave that the master never issued: %s",
                                 t.convert2string()))
      num_requests_failed++;
      return;
    end
    expected = m_write_requests.pop_front();
  end
  else begin
    if (m_read_requests.size() == 0) begin
      `uvm_error("SB", $sformatf("a read reached the slave that the master never issued: %s",
                                 t.convert2string()))
      num_requests_failed++;
      return;
    end
    expected = m_read_requests.pop_front();
  end

  compare_pair("request", expected, t, num_requests_matched, num_requests_failed);
endfunction : write_snk_request

// ---------------------------------------------------------------------
// Responses: slave side is the expectation, master side is what is
// checked -- the response travels from the slave back to the master, so
// that is the direction the comparison has to run.
// ---------------------------------------------------------------------
function void axi_lite_scoreboard::write_snk_item(axi_lite_seq_item t);
  if (!checking_enabled) return;
  if (t.is_write()) m_write_responses.push_back(t);
  else              m_read_responses.push_back(t);
endfunction : write_snk_item

function void axi_lite_scoreboard::write_src_item(axi_lite_seq_item t);
  axi_lite_seq_item expected;
  if (!checking_enabled) return;

  // Decremented before the comparison, not after: this transaction's
  // life ends here whether or not it matched, and leaving it counted on
  // an error path would hang the next drain().
  if (num_outstanding != 0) num_outstanding--;

  if (t.is_write()) begin
    if (m_write_responses.size() == 0) begin
      `uvm_error("SB", $sformatf("the master got a write response the slave never sent: %s",
                                 t.convert2string()))
      num_responses_failed++;
      return;
    end
    expected = m_write_responses.pop_front();
  end
  else begin
    if (m_read_responses.size() == 0) begin
      `uvm_error("SB", $sformatf("the master got read data the slave never sent: %s",
                                 t.convert2string()))
      num_responses_failed++;
      return;
    end
    expected = m_read_responses.pop_front();
  end

  compare_pair("response", expected, t, num_responses_matched, num_responses_failed);

  // The transaction is now complete at the master, which is the moment
  // its effect on memory becomes visible to any later read.
  if (t.is_write()) predict_write(t);
  else              check_read(t);
endfunction : write_src_item

function void axi_lite_scoreboard::predict_write(axi_lite_seq_item item);
  if (m_writes_in_flight.exists(item.addr)) begin
    if (m_writes_in_flight[item.addr] <= 1) m_writes_in_flight.delete(item.addr);
    else                                    m_writes_in_flight[item.addr]--;
  end
  // A write the slave refused never landed, so the shadow must not
  // record it either.
  if (item.resp == AXI_LITE_OKAY)
    shadow.do_write(item.addr, item.wdata, item.wstrb, item.num_bytes());
endfunction : predict_write

function void axi_lite_scoreboard::check_read(axi_lite_seq_item item);
  axi_lite_data_t expected;
  bit             tainted;

  // Popped whatever happens, so the queues stay in step with the reads.
  tainted = (m_read_tainted.size() != 0) ? m_read_tainted.pop_front() : 1'b1;
  if (m_read_addrs.size() != 0) void'(m_read_addrs.pop_front());

  if (!check_data || (item.resp != AXI_LITE_OKAY))
    return;

  // A read that overlapped a write to the same address has two legal
  // answers -- before and after -- so checking it would be checking the
  // test's timing, not the DUT.
  if (tainted) begin
    num_data_skipped++;
    return;
  end

  expected = shadow.do_read(item.addr, item.num_bytes());
  if (item.rdata !== expected) begin
    `uvm_error("SB", $sformatf(
        "read 0x%0h returned 0x%0h but the last write there left 0x%0h",
        item.addr, item.rdata, expected))
    num_data_failed++;
  end
  else begin
    num_data_matched++;
  end
endfunction : check_read

// Anything still queued at the end went into the DUT and never came out.
// With a register slice and a slave that keeps answering, that is a lost
// transaction -- exactly the failure a deadlocked backpressure model
// would produce, so it is worth an error rather than a warning.
function void axi_lite_scoreboard::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if ((m_write_requests.size() != 0) || (m_read_requests.size() != 0))
    `uvm_error("SB_LEAK", $sformatf(
        "%0d write and %0d read request(s) left the master and never reached the slave",
        m_write_requests.size(), m_read_requests.size()))
  if ((m_write_responses.size() != 0) || (m_read_responses.size() != 0))
    `uvm_error("SB_LEAK", $sformatf(
        "%0d write and %0d read response(s) left the slave and never reached the master",
        m_write_responses.size(), m_read_responses.size()))
  if (num_outstanding != 0)
    `uvm_error("SB_LEAK", $sformatf("%0d transaction(s) were issued and never answered",
                                    num_outstanding))
  if ((num_requests_matched == 0) && (num_requests_failed == 0))
    `uvm_error("SB_EMPTY", "no transactions were checked at all -- the link never carried traffic")
endfunction : check_phase

function void axi_lite_scoreboard::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SB", $sformatf(
      "requests %0d ok / %0d bad, responses %0d ok / %0d bad, read data %0d ok / %0d bad (%0d skipped as racing a write)",
      num_requests_matched, num_requests_failed,
      num_responses_matched, num_responses_failed,
      num_data_matched, num_data_failed, num_data_skipped), UVM_LOW)
endfunction : report_phase
