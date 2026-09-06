///////////////////////////////////////////////////////////////////
// Filename: axi_lite_seq_item.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : UVM sequence item representing one complete AXI4-Lite
//           transaction -- a write (AW + W, answered by B) or a read
//           (AR, answered by R) -- sized at run time from the agent's
//           config so that one transaction type, and therefore one
//           sequence library and one scoreboard, serves every bus width
//           in the testbench.
///////////////////////////////////////////////////////////////////
//
// One item is one transaction, not one channel transfer. AXI4-Lite has
// no bursts, so a transaction is always exactly one address phase, at
// most one data phase, and exactly one response -- which makes the whole
// access fit in a single object and a scoreboard's life very simple.
//
// The address and data are vectors of the widest bus AXI4-Lite allows
// (64 bits) and are constrained to zero above the link's real width,
// which keeps the ergonomic `item.addr == 'h40` style of constraint
// working while leaving this class unparameterized. That is what lets a
// 32-bit link and a 64-bit link share one sequence library.
//
// The item also carries its own completion, so a sequence can fire off
// several transactions and then wait for the one it cares about:
//
//   start_item(item); ... finish_item(item);
//   item.wait_done();                 // returns when B or R came back
//   if (item.resp != AXI_LITE_OKAY) ...

class axi_lite_seq_item extends uvm_sequence_item;

  // ---- Bus geometry. Not rand: these describe the link the transaction
  // is for, and are normally filled in from `agent_config` by
  // pre_randomize().
  int unsigned         addr_width             = 32;
  int unsigned         data_width             = 32;
  bit                  has_prot               = 1'b1;

  // Legal address window and the alignment every address must satisfy,
  // both derived from the config by set_geometry().
  axi_lite_addr_t      addr_lo                = '0;
  axi_lite_addr_t      addr_hi                = 64'hFF;
  axi_lite_addr_t      align_mask             = ~axi_lite_addr_t'(3);

  // Which bits of the address and of WSTRB this link actually has.
  // Precomputed in set_geometry() rather than written as a shift inside
  // the constraints: a shift by a variable amount is one place a solver
  // can be slow, and `wstrb[n-1:0]` with a variable n is not even legal
  // SystemVerilog.
  axi_lite_addr_t      addr_mask              = 64'hFFFF_FFFF;
  axi_lite_data_t data_mask = 64'hFFFF_FFFF;
  axi_lite_strb_t      strb_mask              = 8'h0F;

  // Bounds for the two pacing knobs, likewise copied from the config.
  int unsigned         min_addr_delay         = 0;
  int unsigned         max_addr_delay         = 0;
  int unsigned         min_wdata_delay        = 0;
  int unsigned         max_wdata_delay        = 0;

  // When set (the default), a write enables every byte lane. Clear it to
  // let the solver choose the WSTRB pattern freely, which is how partial
  // writes get exercised.
  //
  // A plain knob rather than a `soft` constraint, following the same
  // reasoning as the rest of this UVC: a non-rand bit gating a hard
  // implication behaves identically from a user's point of view and
  // never puts the solver in a position to have to weigh priorities.
  bit                  full_strobe            = 1'b1;

  // Optional handle to the agent's config. When set (the sequence base
  // class does this for you), pre_randomize() adopts its geometry, so a
  // sequence never has to restate the link's widths or address map.
  axi_lite_config      agent_config;

  // ---- The request -------------------------------------------------
  rand axi_lite_kind_e kind;
  rand axi_lite_addr_t addr;
  rand axi_lite_prot_t prot;
  rand axi_lite_data_t wdata;  // writes only
  rand axi_lite_strb_t wstrb;  // writes only

  // ---- Stimulus-only pacing. Idle ACLK cycles the master driver
  // inserts before offering the address phase and, independently, the
  // write data phase. They are independent so that W can be presented
  // before AW -- legal AXI4-Lite, and a case slaves get wrong.
  // Not part of the observed transaction, so do_compare() ignores them.
  rand int unsigned    addr_delay;
  rand int unsigned    wdata_delay;

  // ---- The answer, filled in by the driver and by the monitor -------
  axi_lite_data_t      rdata                  = '0;  // reads only
  axi_lite_resp_e      resp                   = AXI_LITE_OKAY;  // BRESP for writes, RRESP for reads

  // False until the response has been seen. do_compare() only compares
  // response fields when both items have one, so a request captured at
  // the address phase still compares cleanly against a completed
  // transaction's request half.
  bit                  has_response           = 1'b0;

  // Set when ARESETn cut the transaction short. Such a transaction is
  // still marked done -- otherwise anything blocked in wait_done() would
  // hang for the rest of the simulation -- so this is the flag that
  // distinguishes "finished" from "answered". `resp` is meaningless when
  // it is set.
  bit                  aborted                = 1'b0;

  // ---- Observed timing, filled in by the monitor. Descriptive, never
  // compared: how long a transaction took is the DUT's business, not
  // part of what it carried.
  int unsigned         latency_cycles         = 0;  // address accepted -> response accepted
  int unsigned         addr_stall_cycles      = 0;  // AWVALID/ARVALID high, READY low
  int unsigned         wdata_stall_cycles     = 0;  // WVALID high, WREADY low
  int unsigned         resp_stall_cycles      = 0;  // BVALID/RVALID high, our READY low

  `uvm_object_utils(axi_lite_seq_item)

  // Every access is the full width of the data bus, so the low address
  // bits must be clear (AXI4-Lite, IHI 0022 B1.1). Hard, so no
  // `randomize() with` can talk the item into an unaligned address.
  constraint c_alignment {(addr & align_mask) == addr;}

  // ...and inside the aperture the DUT actually decodes.
  constraint c_window {addr inside {[addr_lo : addr_hi]};}

  // Zero every bit above the link's real width.
  constraint c_addr_width {(addr & ~addr_mask) == '0;}

  // WSTRB has one bit per byte lane of this bus and nothing above it.
  constraint c_strb_width {(wstrb & ~strb_mask) == '0;}


  // A read has no write data phase, so its WSTRB and WDATA are not
  // stimulus -- pinning them to zero keeps a read's convert2string()
  // honest and stops a scoreboard from ever comparing them.
  constraint c_read_has_no_wdata {
    (kind == AXI_LITE_READ) -> (wstrb == '0);
    (kind == AXI_LITE_READ) -> (wdata == '0);
  }

  // Ordinary writes enable every lane. Partial strobes are opt-in, by
  // clearing `full_strobe` before randomizing.
  constraint c_full_strobe {(full_strobe && (kind == AXI_LITE_WRITE)) -> (wstrb == strb_mask);}

  // A link whose AxPROT is tied off drives zeros rather than random
  // values that nothing will ever look at.
  constraint c_prot {(!has_prot) -> (prot == '0);}

  constraint c_addr_delay {addr_delay inside {[min_addr_delay : max_addr_delay]};}
  constraint c_wdata_delay {wdata_delay inside {[min_wdata_delay : max_wdata_delay]};}

  // Completion signalling for wait_done(). An event rather than a flag
  // alone, so several processes can wait on the same transaction.
  local bit   m_completed = 1'b0;
  local event m_done_ev;

  extern function new(string name = "axi_lite_seq_item");

  // Adopt a link's geometry, so the constraints above size and mask this
  // transaction correctly. Called automatically from pre_randomize()
  // when `agent_config` is set; call it directly when building a
  // transaction without randomizing.
  extern function void set_geometry(axi_lite_config link_config);
  extern function void pre_randomize();
  extern function void post_randomize();

  // ---- Completion ---------------------------------------------------
  extern function void set_done();
  extern function bit is_done();
  extern task wait_done();

  // ---- Helpers ------------------------------------------------------
  extern function bit is_write();
  extern function bit is_error();
  extern function int unsigned num_bytes();  // bytes moved by this transfer
  extern function int unsigned num_strobed_bytes();  // byte lanes WSTRB enables
  // The data this transaction carried, whichever direction it went.
  extern function axi_lite_data_t payload();

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
  extern virtual function void do_print(uvm_printer printer);
  extern virtual function string convert2string();

endclass : axi_lite_seq_item

function axi_lite_seq_item::new(string name = "axi_lite_seq_item");
  super.new(name);
endfunction : new

// Rounding matters here. The window's low end rounds *up* to the next
// aligned address and its high end rounds *down*, so every address the
// solver can pick is both inside the window and aligned. A window too
// narrow to contain one aligned transfer collapses to a single address
// rather than producing an unsatisfiable constraint that would surface
// as a mystery randomization failure.
function void axi_lite_seq_item::set_geometry(axi_lite_config link_config);
  axi_lite_addr_t width_mask;
  axi_lite_addr_t lo_aligned;
  axi_lite_addr_t hi_aligned;
  int unsigned    bytes;

  if (link_config == null) return;

  addr_width = link_config.addr_width;
  data_width = link_config.data_width;
  has_prot = link_config.has_prot;
  min_addr_delay = link_config.min_addr_delay;
  max_addr_delay = link_config.max_addr_delay;
  min_wdata_delay = link_config.min_wdata_delay;
  max_wdata_delay = link_config.max_wdata_delay;

  bytes = link_config.bytes_per_beat();
  align_mask = link_config.addr_align_mask();
  strb_mask = axi_lite_strb_t'((32'h1 << bytes) - 1);
  data_mask  = (data_width >= AXI_LITE_MAX_DATA_WIDTH) ?
                   '1 : ((axi_lite_data_t'(1) << data_width) - 1);

  // Nothing above the link's address width can ever be decoded, so the
  // window is clamped to it before it is aligned.
  width_mask = (addr_width >= AXI_LITE_MAX_ADDR_WIDTH)
             ? '1 : ((axi_lite_addr_t'(1) << addr_width) - 1);
  addr_mask = width_mask;

  lo_aligned = ((link_config.addr_lo & width_mask) + (bytes - 1)) & align_mask;
  hi_aligned = (link_config.addr_hi & width_mask) & align_mask;

  if (lo_aligned > hi_aligned) begin
    lo_aligned = link_config.addr_lo & width_mask & align_mask;
    hi_aligned = lo_aligned;
  end

  addr_lo = lo_aligned;
  addr_hi = hi_aligned;
endfunction : set_geometry

function void axi_lite_seq_item::pre_randomize();
  set_geometry(agent_config);
endfunction : pre_randomize

// WDATA is trimmed to the bus width here rather than by a constraint,
// and that is a deliberate concession to the solver rather than a
// stylistic choice.
//
// The obvious constraint -- `(wdata & ~data_mask) == 0` -- makes XSIM
// 2023.2 declare a 32-bit write unsatisfiable, even though zeroing the
// top half plainly satisfies it. Rewriting it as `(wdata >> data_width)
// == 0` does solve, but the solver then answers it the laziest way it
// can and returns wdata == 0 on *every* draw, which is far worse: the
// stimulus would look healthy and carry no data. Neither failure mode
// appears on a 64-bit bus, where the mask is all ones and the
// constraint is vacuous, so it would have gone unnoticed on the widest
// port and broken the narrow ones.
//
// Trimming after the fact has neither problem. The solver draws a full
// 64 bits with nothing to reason about, and the bits the bus cannot
// carry are dropped here -- which is exactly what the driver would do
// to them anyway, so this only makes the transaction honest about it.
function void axi_lite_seq_item::post_randomize();
  wdata &= data_mask;
endfunction : post_randomize

function void axi_lite_seq_item::set_done();
  m_completed = 1'b1;
  ->m_done_ev;
endfunction : set_done

function bit axi_lite_seq_item::is_done();
  return m_completed;
endfunction : is_done

// Checking the flag first is what makes this safe to call after the fact:
// a transaction that already completed returns immediately instead of
// waiting forever for an event that has been and gone.
task axi_lite_seq_item::wait_done();
  if (!m_completed) @(m_done_ev);
endtask : wait_done

function bit axi_lite_seq_item::is_write();
  return (kind == AXI_LITE_WRITE);
endfunction : is_write

function bit axi_lite_seq_item::is_error();
  return has_response && (resp != AXI_LITE_OKAY);
endfunction : is_error

function int unsigned axi_lite_seq_item::num_bytes();
  return (data_width == 0) ? 4 : (data_width / 8);
endfunction : num_bytes

function int unsigned axi_lite_seq_item::num_strobed_bytes();
  num_strobed_bytes = 0;
  for (int unsigned i = 0; i < num_bytes(); i++) if (wstrb[i]) num_strobed_bytes++;
endfunction : num_strobed_bytes

function axi_lite_data_t axi_lite_seq_item::payload();
  return is_write() ? wdata : rdata;
endfunction : payload

function void axi_lite_seq_item::do_copy(uvm_object rhs);
  axi_lite_seq_item rhs_;
  if (rhs == null) `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs)) `uvm_fatal("DO_COPY", "cast of rhs to axi_lite_seq_item failed")
  super.do_copy(rhs);
  addr_width         = rhs_.addr_width;
  data_width         = rhs_.data_width;
  has_prot           = rhs_.has_prot;
  addr_lo            = rhs_.addr_lo;
  addr_hi            = rhs_.addr_hi;
  align_mask         = rhs_.align_mask;
  addr_mask          = rhs_.addr_mask;
  data_mask          = rhs_.data_mask;
  strb_mask          = rhs_.strb_mask;
  min_addr_delay     = rhs_.min_addr_delay;
  max_addr_delay     = rhs_.max_addr_delay;
  min_wdata_delay    = rhs_.min_wdata_delay;
  max_wdata_delay    = rhs_.max_wdata_delay;
  full_strobe        = rhs_.full_strobe;
  agent_config       = rhs_.agent_config;
  kind               = rhs_.kind;
  addr               = rhs_.addr;
  prot               = rhs_.prot;
  wdata              = rhs_.wdata;
  wstrb              = rhs_.wstrb;
  addr_delay         = rhs_.addr_delay;
  wdata_delay        = rhs_.wdata_delay;
  rdata              = rhs_.rdata;
  resp               = rhs_.resp;
  has_response       = rhs_.has_response;
  aborted            = rhs_.aborted;
  latency_cycles     = rhs_.latency_cycles;
  addr_stall_cycles  = rhs_.addr_stall_cycles;
  wdata_stall_cycles = rhs_.wdata_stall_cycles;
  resp_stall_cycles  = rhs_.resp_stall_cycles;
endfunction : do_copy

// Compares what the transaction *was*, never when it happened. The
// pacing knobs and the observed stall counts describe timing, so a
// transaction that crossed a register slice still compares equal to the
// one that went in.
//
// Two further exclusions are protocol, not convenience:
//   - WDATA is compared only on byte lanes WSTRB enables, because AXI
//     leaves a disabled lane's write data explicitly undefined;
//   - response fields are compared only when both items have a
//     response, so a request captured at the address phase compares
//     cleanly against a completed transaction.
function bit axi_lite_seq_item::do_compare(uvm_object rhs, uvm_comparer comparer);
  axi_lite_seq_item rhs_;

  if (!$cast(rhs_, rhs)) `uvm_fatal("DO_COMPARE", "cast of rhs to axi_lite_seq_item failed")
  if (!super.do_compare(rhs, comparer)) return 1'b0;

  if (kind !== rhs_.kind) begin
    comparer.print_msg($sformatf("kind differs: %s vs %s", kind.name(), rhs_.kind.name()));
    return 1'b0;
  end
  if (addr !== rhs_.addr) begin
    comparer.print_msg($sformatf("addr differs: 0x%0h vs 0x%0h", addr, rhs_.addr));
    return 1'b0;
  end
  if (has_prot && rhs_.has_prot && (prot !== rhs_.prot)) begin
    comparer.print_msg($sformatf("prot differs: 0x%0h vs 0x%0h", prot, rhs_.prot));
    return 1'b0;
  end

  if (is_write()) begin
    if (wstrb !== rhs_.wstrb) begin
      comparer.print_msg($sformatf("wstrb differs: 0x%0h vs 0x%0h", wstrb, rhs_.wstrb));
      return 1'b0;
    end
    for (int unsigned i = 0; i < num_bytes(); i++)
    if (wstrb[i] && (wdata[i*8+:8] !== rhs_.wdata[i*8+:8])) begin
      comparer.print_msg(
          $sformatf("wdata byte %0d differs: %02h vs %02h", i, wdata[i*8+:8], rhs_.wdata[i*8+:8]));
      return 1'b0;
    end
  end

  if (has_response && rhs_.has_response) begin
    if (resp !== rhs_.resp) begin
      comparer.print_msg($sformatf("resp differs: %s vs %s", resp.name(), rhs_.resp.name()));
      return 1'b0;
    end
    // A slave that errored has no data to return, so its RDATA is not
    // part of the transaction's content.
    if (!is_write() && (resp == AXI_LITE_OKAY) && (rdata !== rhs_.rdata)) begin
      comparer.print_msg($sformatf("rdata differs: 0x%0h vs 0x%0h", rdata, rhs_.rdata));
      return 1'b0;
    end
  end
  return 1'b1;
endfunction : do_compare

function void axi_lite_seq_item::do_print(uvm_printer printer);
  super.do_print(printer);
  printer.print_string("kind", kind.name());
  printer.print_field_int("addr", addr, addr_width, UVM_HEX);
  if (has_prot) printer.print_field_int("prot", prot, 3, UVM_BIN);
  if (is_write()) begin
    printer.print_field_int("wdata", wdata, data_width, UVM_HEX);
    printer.print_field_int("wstrb", wstrb, data_width / 8, UVM_BIN);
  end else if (has_response) begin
    printer.print_field_int("rdata", rdata, data_width, UVM_HEX);
  end
  if (has_response) printer.print_string("resp", resp.name());
  printer.print_field_int("addr_delay", addr_delay, 32, UVM_DEC);
  printer.print_field_int("wdata_delay", wdata_delay, 32, UVM_DEC);
endfunction : do_print

function string axi_lite_seq_item::convert2string();
  string s;
  s = $sformatf("%-5s addr=0x%0h", axi_lite_short_name(kind.name()), addr);
  if (has_prot && (prot != '0)) s = {s, $sformatf(" prot=0b%03b", prot)};
  if (is_write()) s = {s, $sformatf(" wdata=0x%0h wstrb=0b%0b", wdata, wstrb)};
  if (aborted) begin
    s = {s, " -> ABORTED BY RESET"};
  end else if (has_response) begin
    s = {s, $sformatf(" -> %s", axi_lite_short_name(resp.name()))};
    if (!is_write() && (resp == AXI_LITE_OKAY)) s = {s, $sformatf(" rdata=0x%0h", rdata)};
    if (latency_cycles != 0) s = {s, $sformatf(" (%0d cycles)", latency_cycles)};
  end else begin
    if (addr_delay != 0) s = {s, $sformatf(" addr_delay=%0d", addr_delay)};
    if (wdata_delay != 0) s = {s, $sformatf(" wdata_delay=%0d", wdata_delay)};
  end
  return s;
endfunction : convert2string
