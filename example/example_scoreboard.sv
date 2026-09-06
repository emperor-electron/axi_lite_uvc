///////////////////////////////////////////////////////////////////
// Filename: example_scoreboard.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Example of consuming the UVC's analysis ports: a model of
//           the DUT's register map, checked against every transaction
//           the UVC observes on the bus.
///////////////////////////////////////////////////////////////////
//
// Unlike the UVC's own self-test -- where the DUT passes transactions
// through and the check is an identity -- a real DUT has behaviour, so a
// real scoreboard has a model. This one is about as small as such a
// model gets, and it is the shape yours will have:
//
//   1. subscribe to the monitor's completed-transaction port
//   2. for a write, update the model
//   3. for a read, compare what came back against the model
//
// Each monitor offers two analysis ports, and which you subscribe to is
// a real design choice:
//
//   monitor.request_analysis_port  the transaction as soon as it is
//               fully requested -- address accepted for a read, address
//               and data both accepted for a write -- with no response
//               yet. Use it to model ahead of the DUT, or to check
//               request-side timing.
//   monitor.item_analysis_port     the completed transaction, carrying
//               BRESP/RRESP, RDATA and the latency. This is what a
//               scoreboard checks, and what this one uses.
//
// Note that both streams come from a monitor, never from a driver, so
// the check is against what the wires actually did rather than what the
// testbench meant to do. That distinction is the whole reason a passive
// agent is worth having.

class example_scoreboard extends uvm_subscriber #(axi_lite_seq_item);

  `uvm_component_utils(example_scoreboard)

  // The model. An axi_lite_mem rather than a hand-rolled array, because
  // it already implements byte strobes correctly -- and getting WSTRB
  // right in a model is exactly where a hand-rolled one goes wrong.
  axi_lite_mem model;

  // Only ever used for its clock, so wait_until_idle() can count cycles.
  // Assigned by the env.
  example_vif_t vif;

  int unsigned num_checked   = 0;
  int unsigned num_failed    = 0;
  int unsigned num_decerr    = 0;
  int unsigned num_outstanding = 0;

  extern function new(string name = "example_scoreboard", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void write(axi_lite_seq_item t);

  // What the DUT should answer with at this address.
  extern virtual function axi_lite_resp_e expected_resp(axi_lite_addr_t addr);
  extern virtual function axi_lite_data_t expected_rdata(axi_lite_addr_t addr);

  extern virtual task wait_until_idle(int unsigned timeout_cycles = 5000);
  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

endclass : example_scoreboard

function example_scoreboard::new(string name = "example_scoreboard", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_scoreboard::build_phase(uvm_phase phase);
  super.build_phase(phase);
  model = axi_lite_mem::type_id::create("model");
endfunction : build_phase

// The DUT decodes 0x00..0x3F and nothing else.
function axi_lite_resp_e example_scoreboard::expected_resp(axi_lite_addr_t addr);
  return (addr <= EX_MAP_HI) ? AXI_LITE_OKAY : AXI_LITE_DECERR;
endfunction : expected_resp

function axi_lite_data_t example_scoreboard::expected_rdata(axi_lite_addr_t addr);
  if (addr > EX_MAP_HI)          return '0;            // DECERR returns no data
  if (addr == EX_ID_ADDR)        return EX_ID_VALUE;   // read-only constant
  return model.do_read(addr, EX_DATA_WIDTH / 8);
endfunction : expected_rdata

// The formal is named `t` because uvm_subscriber#(T) declares it that
// way; renaming it would make this an overload that never gets called
// rather than an override.
function void example_scoreboard::write(axi_lite_seq_item t);
  axi_lite_resp_e want_resp = expected_resp(t.addr);

  num_checked++;
  if (want_resp != AXI_LITE_OKAY) num_decerr++;

  if (t.resp != want_resp) begin
    `uvm_error("SB", $sformatf("%s at 0x%0h answered %s, expected %s",
                               t.is_write() ? "write" : "read", t.addr,
                               t.resp.name(), want_resp.name()))
    num_failed++;
    return;
  end

  if (t.is_write()) begin
    // A write that the DUT refused did not land, and register 0 is
    // read-only -- it answers OKAY and keeps its own value. Modelling
    // both is what stops the next read of either address from being
    // reported as a mismatch.
    if ((t.resp == AXI_LITE_OKAY) && (t.addr != EX_ID_ADDR))
      model.do_write(t.addr, t.wdata, t.wstrb, t.num_bytes());
    return;
  end

  if (t.resp == AXI_LITE_OKAY) begin
    axi_lite_data_t want = expected_rdata(t.addr);
    if (t.rdata !== want) begin
      `uvm_error("SB", $sformatf("read 0x%0h returned 0x%0h, expected 0x%0h",
                                 t.addr, t.rdata, want))
      num_failed++;
    end
  end
endfunction : write

// Called by the test before it drops its objection. A sequence returns
// when the last transaction has been *answered at the master*, but the
// monitor publishes on the same edge, so a couple of cycles here is
// enough to be sure the analysis ports have been drained.
task example_scoreboard::wait_until_idle(int unsigned timeout_cycles = 5000);
  repeat (4) @(posedge vif.aclk);
endtask : wait_until_idle

function void example_scoreboard::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if (num_checked == 0)
    `uvm_error("SB", "no transactions were checked at all -- the bus never carried traffic")
endfunction : check_phase

function void example_scoreboard::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SB", $sformatf("checked %0d transaction(s), %0d bad, %0d of them decode errors",
                            num_checked, num_failed, num_decerr), UVM_LOW)
endfunction : report_phase
