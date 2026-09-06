///////////////////////////////////////////////////////////////////
// Filename: axi_lite_seq_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Reusable AXI4-Lite master sequences: single writes and
//           reads, a self-checking write/read-back, an address sweep
//           across a register map, and randomised mixed traffic.
///////////////////////////////////////////////////////////////////
//
// None of these sequences is parameterized, and none of them mentions a
// width. They read the port's geometry and its address window from the
// agent's config through the sequencer, so the very same sequence object
// -- started with the very same constraints -- produces 32-bit accesses
// on one port and 64-bit accesses on another, each inside its own
// aperture.
//
// Blocking or not
// ---------------
// By default every sequence waits for each transaction's response before
// issuing the next, which is what makes a read's data available to the
// line after it and what most AXI4-Lite peripherals expect anyway.
// Clearing `blocking` lets a sequence run ahead, which -- together with
// axi_lite_config::max_outstanding above 1 -- is how a slave that claims
// to pipeline gets tested:
//
//   agent_config.max_outstanding = 4;
//   random_sequence.blocking     = 1'b0;

virtual class axi_lite_base_seq extends uvm_sequence #(axi_lite_seq_item);

  `uvm_declare_p_sequencer(axi_lite_sequencer)

  axi_lite_config agent_config;

  // Wait for each transaction's response before issuing the next.
  bit blocking = 1'b1;

  // Non-rand mirrors of the port's geometry, refreshed by
  // pre_randomize(). Constraints cannot safely dereference `agent_config`
  // (it may still be null when a test randomizes a sequence before
  // starting it), so the numbers are copied out first and the
  // constraints use these. With no config yet they describe a small
  // 32-bit port, which keeps every constraint below solvable.
  protected axi_lite_addr_t m_addr_lo    = '0;
  protected axi_lite_addr_t m_addr_hi    = 64'hFF;
  protected axi_lite_addr_t m_align_mask = ~axi_lite_addr_t'(3);
  protected axi_lite_strb_t m_strb_mask  = 8'h0F;
  protected bit             m_has_prot   = 1'b1;

  extern function new(string name = "axi_lite_base_seq");
  extern virtual task pre_start();
  extern function void pre_randomize();

  // A transaction already bound to this port's geometry, ready to fill
  // in and send.
  extern function axi_lite_seq_item new_item(string name = "item");

  // Send a transaction whose request fields are already decided. Only
  // the pacing knobs are randomized, so the solver never has to
  // reconsider an address or a payload the caller chose deliberately.
  extern task send(axi_lite_seq_item item);

  // The two one-line calls most user sequences actually want.
  extern task write(axi_lite_addr_t addr, axi_lite_data_t data,
                    output axi_lite_resp_e resp,
                    input axi_lite_strb_t strb = '1,
                    input axi_lite_prot_t prot = 3'b000);
  extern task read(axi_lite_addr_t addr,
                   output axi_lite_data_t data, output axi_lite_resp_e resp,
                   input axi_lite_prot_t prot = 3'b000);

endclass : axi_lite_base_seq

function axi_lite_base_seq::new(string name = "axi_lite_base_seq");
  super.new(name);
endfunction : new

task axi_lite_base_seq::pre_start();
  super.pre_start();
  if (agent_config == null) begin
    if (p_sequencer == null)
      `uvm_fatal("NOSQR", "sequence needs an axi_lite_sequencer to learn the port geometry")
    agent_config = p_sequencer.agent_config;
  end
  if (agent_config == null)
    `uvm_fatal("NOCFG", "the sequencer has no axi_lite_config")
endtask : pre_start

// The mirrors are taken from a throwaway transaction rather than
// recomputed here, so a sequence's own address constraints and the
// item's can never drift apart -- there is only one implementation of
// "which addresses are legal on this port", and it lives in
// axi_lite_seq_item::set_geometry.
function void axi_lite_base_seq::pre_randomize();
  axi_lite_seq_item probe;
  probe = axi_lite_seq_item::type_id::create("geometry_probe");
  probe.set_geometry(agent_config);       // a no-op while agent_config is null
  m_addr_lo    = probe.addr_lo;
  m_addr_hi    = probe.addr_hi;
  m_align_mask = probe.align_mask;
  m_strb_mask  = probe.strb_mask;
  m_has_prot   = probe.has_prot;
endfunction : pre_randomize

function axi_lite_seq_item axi_lite_base_seq::new_item(string name = "item");
  axi_lite_seq_item item;
  item              = axi_lite_seq_item::type_id::create(name);
  item.agent_config = agent_config;    // pre_randomize() adopts the geometry
  item.set_geometry(agent_config);     // ...and so does an item built by hand
  return item;
endfunction : new_item

task axi_lite_base_seq::send(axi_lite_seq_item item);
  start_item(item);

  // Only the pacing is drawn here; the address, payload and strobe were
  // chosen by the caller. The constraints that *generate* those fields
  // are switched off rather than left to be re-checked against the
  // caller's values, because as checks they are both wrong and opaque:
  // a directed access outside the configured window is a perfectly
  // reasonable thing to want -- probing an unmapped address to see the
  // slave answer DECERR is a test, not a mistake -- and if it were
  // rejected, the only symptom would be "pacing randomization failed",
  // which says nothing about the address that caused it.
  item.c_window.constraint_mode(0);
  item.c_alignment.constraint_mode(0);
  item.c_addr_width.constraint_mode(0);
  item.full_strobe = 1'b0;

  // Misalignment is different: AXI4-Lite has no sub-word access, so an
  // unaligned address is a protocol violation rather than an unusual
  // choice. It is still driven -- a directed negative test may want
  // exactly that, and the interface's own assertion will catch it -- but
  // it is named here, where the address is still attributable to the
  // line of sequence code that asked for it.
  if ((item.addr & item.align_mask) != item.addr)
    `uvm_warning("ALIGN", $sformatf(
        "0x%0h is not aligned to this port's %0d-byte data bus; driving it anyway",
        item.addr, item.num_bytes()))

  // Bits above the port's address width are a different kind of mistake
  // again: they cannot reach the wire at all, so an address carrying
  // them will silently arrive somewhere else. Worth naming plainly,
  // since the symptom is otherwise a read of the wrong location.
  if ((item.addr & ~item.addr_mask) != '0)
    `uvm_warning("ADDRW", $sformatf(
        "0x%0h does not fit in this port's %0d address bits; it will be driven as 0x%0h",
        item.addr, item.addr_width, item.addr & item.addr_mask))

  if (!item.randomize(addr_delay, wdata_delay))
    `uvm_fatal("RAND", $sformatf("pacing randomization failed for %s", item.convert2string()))
  finish_item(item);
  if (blocking)
    item.wait_done();
endtask : send

task axi_lite_base_seq::write(axi_lite_addr_t addr, axi_lite_data_t data,
                              output axi_lite_resp_e resp,
                              input axi_lite_strb_t strb = '1,
                              input axi_lite_prot_t prot = 3'b000);
  axi_lite_seq_item item = new_item("write");
  item.kind  = AXI_LITE_WRITE;
  item.addr  = addr;
  item.wdata = data & item.data_mask;
  item.wstrb = strb & item.strb_mask;
  item.prot  = item.has_prot ? prot : 3'b000;
  send(item);
  resp = item.resp;
endtask : write

task axi_lite_base_seq::read(axi_lite_addr_t addr,
                             output axi_lite_data_t data, output axi_lite_resp_e resp,
                             input axi_lite_prot_t prot = 3'b000);
  axi_lite_seq_item item = new_item("read");
  item.kind  = AXI_LITE_READ;
  item.addr  = addr;
  item.wdata = '0;
  item.wstrb = '0;
  item.prot  = item.has_prot ? prot : 3'b000;
  send(item);
  data = item.rdata;
  resp = item.resp;
endtask : read


///////////////////////////////////////////////////////////////////
// One write. The fields are rand and constrained to the port's window,
// so the natural thing works:
//
//   assert (write_sequence.randomize() with { addr == 'h10; wdata == 32'hCAFE; });
///////////////////////////////////////////////////////////////////
class axi_lite_write_seq extends axi_lite_base_seq;

  rand axi_lite_addr_t addr;
  rand axi_lite_data_t wdata;
  rand axi_lite_strb_t wstrb;
  rand axi_lite_prot_t prot;

  // Clear to let the solver pick a partial strobe.
  bit full_strobe = 1'b1;

  // Filled in after the sequence has run.
  axi_lite_resp_e resp    = AXI_LITE_OKAY;
  bit             aborted = 1'b0;

  constraint c_addr  { addr inside {[m_addr_lo:m_addr_hi]};
                       (addr & m_align_mask) == addr; }
  constraint c_strb  { (wstrb & ~m_strb_mask) == '0;
                       full_strobe -> (wstrb == m_strb_mask); }
  constraint c_prot  { (!m_has_prot) -> (prot == '0); }

  `uvm_object_utils(axi_lite_write_seq)

  extern function new(string name = "axi_lite_write_seq");
  extern virtual task body();

endclass : axi_lite_write_seq

function axi_lite_write_seq::new(string name = "axi_lite_write_seq");
  super.new(name);
endfunction : new

task axi_lite_write_seq::body();
  axi_lite_seq_item item = new_item("write");
  item.kind  = AXI_LITE_WRITE;
  item.addr  = addr;
  item.wdata = wdata;
  item.wstrb = wstrb;
  item.prot  = prot;
  send(item);
  resp    = item.resp;
  aborted = item.aborted;
endtask : body


///////////////////////////////////////////////////////////////////
// One read. `rdata` and `resp` are valid once the sequence has finished,
// which for a blocking sequence is as soon as start() returns.
///////////////////////////////////////////////////////////////////
class axi_lite_read_seq extends axi_lite_base_seq;

  rand axi_lite_addr_t addr;
  rand axi_lite_prot_t prot;

  axi_lite_data_t rdata   = '0;
  axi_lite_resp_e resp    = AXI_LITE_OKAY;
  bit             aborted = 1'b0;

  constraint c_addr { addr inside {[m_addr_lo:m_addr_hi]};
                      (addr & m_align_mask) == addr; }
  constraint c_prot { (!m_has_prot) -> (prot == '0); }

  `uvm_object_utils(axi_lite_read_seq)

  extern function new(string name = "axi_lite_read_seq");
  extern virtual task body();

endclass : axi_lite_read_seq

function axi_lite_read_seq::new(string name = "axi_lite_read_seq");
  super.new(name);
endfunction : new

task axi_lite_read_seq::body();
  axi_lite_seq_item item = new_item("read");
  item.kind  = AXI_LITE_READ;
  item.addr  = addr;
  item.wdata = '0;
  item.wstrb = '0;
  item.prot  = prot;
  send(item);
  rdata   = item.rdata;
  resp    = item.resp;
  aborted = item.aborted;
endtask : body


///////////////////////////////////////////////////////////////////
// Write a value, then read the same address back and check it came
// back. The one sequence that is worth reaching for first on a new
// register map: it needs no scoreboard and no model, and it fails
// loudly on the two mistakes that dominate early bring-up -- an address
// decode that lands somewhere else, and a byte lane wired the wrong way
// round.
//
// Only the lanes WSTRB enabled are checked. AXI leaves a disabled lane's
// write data undefined, and whatever was already at that address is the
// DUT's business, so comparing those bytes would manufacture failures.
///////////////////////////////////////////////////////////////////
class axi_lite_write_read_seq extends axi_lite_base_seq;

  rand axi_lite_addr_t addr;
  rand axi_lite_data_t wdata;
  rand axi_lite_strb_t wstrb;

  bit full_strobe = 1'b1;

  // Cleared for a DUT whose registers do not read back what was written
  // -- a write-only register, or one with side effects. The traffic
  // still runs; only the comparison is skipped.
  bit check_readback = 1'b1;

  axi_lite_data_t rdata     = '0;
  axi_lite_resp_e write_resp = AXI_LITE_OKAY;
  axi_lite_resp_e read_resp  = AXI_LITE_OKAY;

  constraint c_addr { addr inside {[m_addr_lo:m_addr_hi]};
                      (addr & m_align_mask) == addr; }
  constraint c_strb { (wstrb & ~m_strb_mask) == '0;
                      full_strobe -> (wstrb == m_strb_mask); }

  `uvm_object_utils(axi_lite_write_read_seq)

  extern function new(string name = "axi_lite_write_read_seq");
  extern virtual task body();

endclass : axi_lite_write_read_seq

function axi_lite_write_read_seq::new(string name = "axi_lite_write_read_seq");
  super.new(name);
endfunction : new

task axi_lite_write_read_seq::body();
  axi_lite_seq_item write_item;
  axi_lite_seq_item read_item;

  // The read must not be issued before the write has been answered, or
  // it could legally overtake it on a pipelined slave and read the old
  // value -- which would be the sequence's bug, not the DUT's.
  bit was_blocking = blocking;
  blocking = 1'b1;

  write_item       = new_item("write");
  write_item.kind  = AXI_LITE_WRITE;
  write_item.addr  = addr;
  write_item.wdata = wdata;
  write_item.wstrb = wstrb;
  send(write_item);
  write_resp = write_item.resp;

  read_item       = new_item("read");
  read_item.kind  = AXI_LITE_READ;
  read_item.addr  = addr;
  read_item.wdata = '0;
  read_item.wstrb = '0;
  send(read_item);
  read_resp = read_item.resp;
  rdata     = read_item.rdata;

  blocking = was_blocking;

  if (!check_readback)
    return;
  // A transaction the slave refused, or one reset cut short, has nothing
  // to compare.
  if (write_item.aborted || read_item.aborted)
    return;
  if ((write_resp != AXI_LITE_OKAY) || (read_resp != AXI_LITE_OKAY))
    return;

  for (int unsigned i = 0; i < read_item.num_bytes(); i++)
    if (wstrb[i] && (rdata[i*8 +: 8] !== wdata[i*8 +: 8]))
      `uvm_error("READBACK", $sformatf(
          "byte %0d at 0x%0h read back as 0x%02h after writing 0x%02h (wrote 0x%0h, read 0x%0h)",
          i, addr, rdata[i*8 +: 8], wdata[i*8 +: 8], wdata, rdata))
endtask : body


///////////////////////////////////////////////////////////////////
// Walk the whole address window one aligned location at a time, writing
// a value derived from the address and reading it straight back. Where
// the random sequence samples a register map, this one covers it: if a
// decode collapses two addresses onto one register, the second write
// overwrites the first and the sweep sees it.
//
// The pattern written is a function of the address on purpose. A
// constant would still pass if every address decoded to the same
// register.
///////////////////////////////////////////////////////////////////
class axi_lite_sweep_seq extends axi_lite_base_seq;

  // Cap on how many locations to visit, so a sweep of a 4 GB aperture
  // is bounded rather than eternal. 0 means "the whole window".
  rand int unsigned max_locations;

  bit check_readback = 1'b1;

  int unsigned num_visited = 0;
  int unsigned num_errors  = 0;

  constraint c_max { soft max_locations == 64; max_locations <= 65536; }

  `uvm_object_utils(axi_lite_sweep_seq)

  extern function new(string name = "axi_lite_sweep_seq");
  extern virtual task body();

  // The value this sweep expects to find at an address.
  extern virtual function axi_lite_data_t pattern_for(axi_lite_addr_t addr);

endclass : axi_lite_sweep_seq

function axi_lite_sweep_seq::new(string name = "axi_lite_sweep_seq");
  super.new(name);
endfunction : new

function axi_lite_data_t axi_lite_sweep_seq::pattern_for(axi_lite_addr_t addr);
  // Both halves depend on the address, and the complement in the upper
  // half means a bus stuck at all-ones or all-zeros cannot pass.
  axi_lite_data_t low  = axi_lite_data_t'(addr) ^ 64'h5A5A_5A5A_5A5A_5A5A;
  return low;
endfunction : pattern_for

task axi_lite_sweep_seq::body();
  int unsigned    step  = agent_config.bytes_per_beat();
  axi_lite_addr_t addr  = m_addr_lo;
  int unsigned    limit = (max_locations == 0) ? 65536 : max_locations;

  // The geometry mirrors are normally filled in by pre_randomize(); a
  // sweep started without being randomized still needs them.
  if (m_addr_hi == m_addr_lo)
    pre_randomize();

  num_visited = 0;
  num_errors  = 0;

  while ((addr <= m_addr_hi) && (num_visited < limit)) begin
    axi_lite_seq_item write_item;
    axi_lite_seq_item read_item;
    axi_lite_data_t   expected = pattern_for(addr);
    bit               was_blocking = blocking;

    blocking = 1'b1;   // a sweep is a read-after-write by definition

    write_item       = new_item($sformatf("sweep_write_%0d", num_visited));
    write_item.kind  = AXI_LITE_WRITE;
    write_item.addr  = addr;
    write_item.wdata = expected;
    write_item.wstrb = write_item.strb_mask;
    send(write_item);

    read_item       = new_item($sformatf("sweep_read_%0d", num_visited));
    read_item.kind  = AXI_LITE_READ;
    read_item.addr  = addr;
    read_item.wdata = '0;
    read_item.wstrb = '0;
    send(read_item);

    blocking = was_blocking;

    if (check_readback && !write_item.aborted && !read_item.aborted &&
        (write_item.resp == AXI_LITE_OKAY) && (read_item.resp == AXI_LITE_OKAY)) begin
      for (int unsigned i = 0; i < read_item.num_bytes(); i++)
        if (read_item.rdata[i*8 +: 8] !== expected[i*8 +: 8]) begin
          `uvm_error("SWEEP", $sformatf(
              "0x%0h read back as 0x%0h, expected 0x%0h (byte %0d differs)",
              addr, read_item.rdata, expected, i))
          num_errors++;
          break;
        end
    end

    num_visited++;
    // Stop before wrapping: a window that ends at the top of the address
    // space would otherwise sweep forever.
    if ((addr + step) < addr) break;
    addr += step;
  end

  `uvm_info("SWEEP", $sformatf("swept %0d location(s) from 0x%0h, %0d mismatch(es)",
                               num_visited, m_addr_lo, num_errors), UVM_LOW)
endtask : body


///////////////////////////////////////////////////////////////////
// A stream of randomly shaped transactions: the default workhorse. Mix,
// addresses, payloads, strobes and pacing are all re-drawn per
// transaction, so a long run covers the space without the test having to
// enumerate it.
///////////////////////////////////////////////////////////////////
class axi_lite_random_seq extends axi_lite_base_seq;

  rand int unsigned num_transactions;

  // Fraction of transactions, in percent, that are reads.
  rand int unsigned read_percent;

  // Fraction of *writes*, in percent, that use a partial byte strobe
  // rather than enabling the whole bus.
  rand int unsigned partial_strobe_percent;

  // Fraction of transactions, in percent, that carry a non-zero AxPROT.
  rand int unsigned prot_percent;

  constraint c_count  { soft num_transactions inside {[8:32]}; num_transactions > 0; }
  constraint c_mix    { soft read_percent == 50; read_percent inside {[0:100]}; }
  constraint c_strobe { soft partial_strobe_percent == 25;
                        partial_strobe_percent inside {[0:100]}; }
  constraint c_prot   { soft prot_percent == 20; prot_percent inside {[0:100]}; }

  `uvm_object_utils(axi_lite_random_seq)

  extern function new(string name = "axi_lite_random_seq");
  extern virtual task body();

endclass : axi_lite_random_seq

function axi_lite_random_seq::new(string name = "axi_lite_random_seq");
  super.new(name);
endfunction : new

task axi_lite_random_seq::body();
  for (int t = 0; t < num_transactions; t++) begin
    axi_lite_seq_item item = new_item($sformatf("random_%0d", t));
    bit is_read = ($urandom_range(99, 0) < read_percent);

    // Drawn into a variable of the enum's own type rather than written
    // as `kind == (is_read ? AXI_LITE_READ : AXI_LITE_WRITE)` inside the
    // constraint. XSIM 2023.2 gets a conditional expression yielding an
    // enum wrong in a `randomize() with` clause -- it solved the read
    // case to WRITE and declared the write case unsatisfiable -- so the
    // choice is made in procedural code, where it means what it says.
    axi_lite_kind_e wanted_kind = is_read ? AXI_LITE_READ : AXI_LITE_WRITE;

    // Everything the transaction carries is drawn here, in one
    // randomize() against the item's own constraints -- so the address
    // is aligned and inside the window, and the strobe fits the bus,
    // without this sequence restating any of those rules.
    item.full_strobe = !(!is_read && ($urandom_range(99, 0) < partial_strobe_percent));
    if (!item.randomize() with { kind == wanted_kind; })
      `uvm_fatal("RAND", $sformatf("random %s randomization failed",
                                   axi_lite_short_name(wanted_kind.name())))

    if (item.has_prot && ($urandom_range(99, 0) >= prot_percent))
      item.prot = 3'b000;

    start_item(item);
    finish_item(item);
    if (blocking)
      item.wait_done();
  end
endtask : body
