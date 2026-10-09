///////////////////////////////////////////////////////////////////
// Filename: axi_lite_reg_seq.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Named register and bit-field access on top of the
//           AXI4-Lite sequence library. Extend this instead of
//           axi_lite_base_seq when the DUT has a register map.
///////////////////////////////////////////////////////////////////
//
// What this adds over axi_lite_base_seq
// -------------------------------------
//   write(12'h004, (gain << 8) | mode << 1 | enable, resp);
//
// becomes
//
//   axi_lite_data_t vals[string];
//   vals["ENABLE"] = 1; vals["MODE"] = CSR_CTRL_MODE_STREAM; vals["GAIN"] = gain;
//   reg_write_fields("CTRL", vals, resp);
//
// -- one bus transaction, with the address, the shifts and the masks
// taken from the register map rather than from the author's memory.
//
// Choosing how to write one field
// -------------------------------
// A single-field write is the interesting case, because the obvious
// implementation -- read the register, substitute, write it back -- is
// wrong on most of the access modes a real map contains. field_write()
// picks between four strategies and records which it used in
// `last_strategy`:
//
//   MODAL   the field is rw1c/rw1s/rw1t/wosc, where a written 0 means
//           "leave alone". Write the field value in place, zeros
//           elsewhere: one transaction, no read, and no effect on the
//           sibling flags. A read-modify-write here would write back the
//           ones it just read and clear every flag that was set.
//
//   STROBE  the field exactly fills whole byte lanes. Write those lanes
//           with WSTRB and leave the rest of the word untouched by the
//           bus itself: one transaction, no read, and nothing else in the
//           register can be disturbed, because a mask that fills its
//           lanes leaves no room in them for another field.
//
//   RMW     the register is readable, no field in it has a read side
//           effect, and no field in it is modal. Read, substitute, write.
//
//   SHADOW  everything else -- a write-only register, or one where
//           reading would itself change the DUT (roc/roll/rolh), or one
//           holding modal fields that a written-back 1 would trigger.
//           Build the word from the shadow value instead of from a read.
//           Modal fields are forced to 0 in that word, since 0 is their
//           no-op and a shadow cannot know what the hardware has set.
//
// The shadow is this testbench's belief about the register: its reset
// value, updated by every write made through this layer. It is exact for
// a register only this layer writes, and a guess for one the hardware
// also changes -- which is why it is the last resort rather than the
// default.

class axi_lite_reg_seq extends axi_lite_base_seq;

  // Taken from the agent's config in pre_start(). Assign it directly to
  // drive a map the config does not know about -- a second peripheral at
  // another base address, say.
  axi_lite_reg_model reg_model;

  // ---- Diagnostics for the most recent field access -------------------
  axi_lite_field_write_strategy_e last_strategy = AXI_LITE_FIELD_WR_NONE;
  int unsigned last_num_bus_accesses = 0;

  // ---- Census, reported by a test that wants to prove the access layer
  // did what it claimed.
  int unsigned num_reg_writes = 0;
  int unsigned num_reg_reads = 0;
  int unsigned num_field_writes = 0;
  int unsigned num_checks = 0;
  int unsigned num_check_failures = 0;

  // Raised on the first access, after the map's width has been compared
  // with the link's.
  protected bit m_geometry_checked = 1'b0;

  `uvm_object_utils(axi_lite_reg_seq)

  extern function new(string name = "axi_lite_reg_seq");
  extern virtual task pre_start();

  // ---- Whole-register access -----------------------------------------
  extern task reg_write(string reg_name, axi_lite_data_t value, output axi_lite_resp_e resp);
  extern task reg_read(string reg_name, output axi_lite_data_t value, output axi_lite_resp_e resp);

  // ---- Field access ---------------------------------------------------
  extern task field_write(string reg_name, string field_name, axi_lite_data_t value,
                          output axi_lite_resp_e resp);
  extern task field_read(string reg_name, string field_name, output axi_lite_data_t value,
                         output axi_lite_resp_e resp);

  // Several fields of one register in a single bus write. This is the
  // call that replaces a run of hand-built writes, and it is also the
  // only way to set two fields of the same register *atomically* as far
  // as the DUT is concerned.
  extern task reg_write_fields(string reg_name, axi_lite_data_t values[string],
                               output axi_lite_resp_e resp);

  // ---- Enumerated values ---------------------------------------------
  extern task field_write_enum(string reg_name, string field_name, string enum_name,
                               output axi_lite_resp_e resp);
  // Returns "" in `enum_name` if the value read back is not an enumerated
  // one, which is itself usually worth reporting.
  extern task field_read_enum(string reg_name, string field_name, output string enum_name,
                              output axi_lite_resp_e resp);

  // ---- Checks ---------------------------------------------------------
  // Each reports a UVM_ERROR on mismatch and counts it, so a sequence can
  // be used as a self-checking bring-up script.
  extern task reg_check(string reg_name, axi_lite_data_t expected);
  extern task field_check(string reg_name, string field_name, axi_lite_data_t expected);
  // Every readable register against its reset value. The natural first
  // test of a freshly generated block.
  extern task check_all_resets();

  // ---- Helpers --------------------------------------------------------
  extern function axi_lite_addr_t addr_of(string reg_name);
  extern protected function void check_geometry();
  extern protected function axi_lite_field_write_strategy_e strategy_for(axi_lite_reg r,
                                                                        axi_lite_field f);
  // The word to write when building from believed state rather than from
  // a read: the shadow, with modal fields neutralised.
  extern protected function axi_lite_data_t shadow_basis(axi_lite_reg r);

endclass : axi_lite_reg_seq

function axi_lite_reg_seq::new(string name = "axi_lite_reg_seq");
  super.new(name);
endfunction : new

task axi_lite_reg_seq::pre_start();
  super.pre_start();
  // The config is the normal source, but an explicit assignment wins, so
  // one sequence can drive a map the agent was never told about.
  if ((reg_model == null) && (agent_config != null)) reg_model = agent_config.reg_model;
  if (reg_model == null)
    `uvm_fatal("NOREGMODEL", {"no axi_lite_reg_model available. Set agent_config.reg_model, ",
                              "or assign this sequence's reg_model before starting it. ",
                              "See docs/register-maps.md."})
endtask : pre_start

// A map generated for one data width describes registers at addresses
// that assume that width. Driving it over a wider or narrower link is not
// a reinterpretation the UVC can make safely, so it is reported once.
function void axi_lite_reg_seq::check_geometry();
  axi_lite_seq_item probe;
  if (m_geometry_checked) return;
  m_geometry_checked = 1'b1;

  probe = new_item("geometry_probe");
  if (reg_model.data_width != probe.data_width)
    `uvm_warning("REGMODEL", $sformatf(
                 {"register map '%s' was generated for a %0d-bit bus but this link is %0d-bit; ",
                  "register offsets assume the generated width"}, reg_model.map_name,
                 reg_model.data_width, probe.data_width))

  foreach (reg_model.regs[i]) begin
    axi_lite_addr_t a = reg_model.base_address + reg_model.regs[i].offset;
    if ((a & probe.align_mask) != a)
      `uvm_error("REGMODEL", $sformatf(
                 "register '%s' is at 0x%0h, which is not aligned to this link's %0d-byte bus",
                 reg_model.regs[i].reg_name, a, probe.num_bytes()))
  end
endfunction : check_geometry

function axi_lite_addr_t axi_lite_reg_seq::addr_of(string reg_name);
  return reg_model.addr_of(reg_name);
endfunction : addr_of

task axi_lite_reg_seq::reg_write(string reg_name, axi_lite_data_t value,
                                 output axi_lite_resp_e resp);
  axi_lite_reg r;
  bit was_blocking = blocking;

  check_geometry();
  r = reg_model.get_reg(reg_name);
  if (r == null) begin
    resp = AXI_LITE_SLVERR;
    return;
  end

  if (!r.is_writable())
    `uvm_warning("REGMODEL", $sformatf(
                 "every field of '%s' is read-only; writing it anyway as asked", reg_name))

  blocking = 1'b1;
  write(reg_model.base_address + r.offset, value, resp);
  blocking = was_blocking;

  num_reg_writes++;
  if (resp == AXI_LITE_OKAY) r.set_shadow(value);
  `uvm_info("REGSEQ", $sformatf("write %s @ 0x%0h = 0x%0h -> %s", reg_name,
                                reg_model.base_address + r.offset, value, resp.name()), UVM_HIGH)
endtask : reg_write

task axi_lite_reg_seq::reg_read(string reg_name, output axi_lite_data_t value,
                                output axi_lite_resp_e resp);
  axi_lite_reg r;
  bit was_blocking = blocking;

  check_geometry();
  r = reg_model.get_reg(reg_name);
  if (r == null) begin
    value = '0;
    resp  = AXI_LITE_SLVERR;
    return;
  end

  if (!r.is_readable())
    `uvm_warning("REGMODEL", $sformatf(
                 "every field of '%s' is write-only; the value read back is not meaningful",
                 reg_name))

  blocking = 1'b1;
  read(reg_model.base_address + r.offset, value, resp);
  blocking = was_blocking;

  num_reg_reads++;
  // A read tells us what is actually there, so it is at least as good a
  // basis for a later read-modify-write as a write was.
  if ((resp == AXI_LITE_OKAY) && !r.read_has_side_effects()) r.set_shadow(value);
  `uvm_info("REGSEQ", $sformatf("read  %s @ 0x%0h = 0x%0h -> %s", reg_name,
                                reg_model.base_address + r.offset, value, resp.name()), UVM_HIGH)
endtask : reg_read

// The decision described at the top of this file. Kept as its own
// function so a test can ask what would happen without doing it, and so
// the ordering of the cases is in one readable place.
function axi_lite_field_write_strategy_e axi_lite_reg_seq::strategy_for(axi_lite_reg r,
                                                                       axi_lite_field f);
  if (!axi_lite_access_is_writable(f.access)) return AXI_LITE_FIELD_WR_NONE;

  // Modal first: for these modes writing the field in place is both the
  // cheapest option and the only correct one.
  if (axi_lite_access_write_is_modal(f.access)) return AXI_LITE_FIELD_WR_MODAL;

  // Byte strobes next: one transaction, no read, and provably no effect
  // outside the field.
  if (f.fills_whole_byte_lanes()) return AXI_LITE_FIELD_WR_STROBE;

  // A read-modify-write is only safe if the read is free of side effects
  // and nothing in the register would act on a written-back 1.
  if (r.is_readable() && !r.read_has_side_effects() && !r.has_modal_fields())
    return AXI_LITE_FIELD_WR_RMW;

  return AXI_LITE_FIELD_WR_SHADOW;
endfunction : strategy_for

function axi_lite_data_t axi_lite_reg_seq::shadow_basis(axi_lite_reg r);
  axi_lite_data_t basis = r.shadow;
  // A modal field's shadow value is not knowledge -- the hardware sets
  // those bits -- and writing a 1 into one would act on it. 0 is the
  // no-op for every modal mode, so that is what goes in.
  foreach (r.fields[i])
    if (axi_lite_access_write_is_modal(r.fields[i].access)) basis &= ~r.fields[i].mask;
  return basis;
endfunction : shadow_basis

task axi_lite_reg_seq::field_write(string reg_name, string field_name, axi_lite_data_t value,
                                   output axi_lite_resp_e resp);
  axi_lite_reg    r;
  axi_lite_field  f;
  axi_lite_seq_item probe;
  axi_lite_data_t word;
  axi_lite_strb_t strb;
  bit             was_blocking = blocking;

  check_geometry();
  last_num_bus_accesses = 0;
  last_strategy         = AXI_LITE_FIELD_WR_NONE;
  resp                  = AXI_LITE_SLVERR;

  r = reg_model.get_reg(reg_name);
  if (r == null) return;
  f = r.get_field(field_name);
  if (f == null) return;

  if (!f.fits(value)) begin
    `uvm_error("REGMODEL", $sformatf("0x%0h does not fit in %s.%s, which is %0d bit(s) wide",
                                     value, reg_name, field_name, f.width))
    return;
  end

  last_strategy = strategy_for(r, f);
  if (last_strategy == AXI_LITE_FIELD_WR_NONE) begin
    `uvm_error("REGMODEL", $sformatf("%s.%s is %s and cannot be written", reg_name, field_name,
                                     axi_lite_access_short(f.access)))
    return;
  end

  // The field has to be inside the link's data bus, whatever the map says.
  probe = new_item("field_probe");
  if ((f.mask & ~probe.data_mask) != '0) begin
    `uvm_error("REGMODEL", $sformatf("%s.%s occupies bits %0d:%0d, past this link's %0d-bit bus",
                                     reg_name, field_name, f.msb(), f.lsb, probe.data_width))
    return;
  end

  blocking = 1'b1;

  case (last_strategy)
    AXI_LITE_FIELD_WR_MODAL: begin
      // Zeros everywhere else, which the modal modes ignore.
      word = f.pack(value);
      strb = probe.strb_mask;
      write(reg_model.base_address + r.offset, word, resp, .strb(strb));
      last_num_bus_accesses = 1;
    end

    AXI_LITE_FIELD_WR_STROBE: begin
      // Only the field's own lanes are enabled, so the value of every
      // other bit in the word is irrelevant.
      word = f.pack(value);
      strb = f.byte_lanes() & probe.strb_mask;
      write(reg_model.base_address + r.offset, word, resp, .strb(strb));
      last_num_bus_accesses = 1;
      if (resp == AXI_LITE_OKAY) r.set_shadow((r.shadow & ~f.mask) | f.pack(value));
    end

    AXI_LITE_FIELD_WR_RMW: begin
      axi_lite_data_t current;
      read(reg_model.base_address + r.offset, current, resp);
      last_num_bus_accesses = 1;
      if (resp != AXI_LITE_OKAY) begin
        `uvm_error("REGMODEL", $sformatf(
                   "read-modify-write of %s.%s: the read answered %s, so the write was abandoned",
                   reg_name, field_name, resp.name()))
        blocking = was_blocking;
        return;
      end
      word = (current & ~f.mask) | f.pack(value);
      strb = probe.strb_mask;
      write(reg_model.base_address + r.offset, word, resp, .strb(strb));
      last_num_bus_accesses = 2;
      if (resp == AXI_LITE_OKAY) r.set_shadow(word);
    end

    AXI_LITE_FIELD_WR_SHADOW: begin
      word = (shadow_basis(r) & ~f.mask) | f.pack(value);
      strb = probe.strb_mask;
      if (r.shadow_is_reset && !r.is_readable())
        `uvm_info("REGSEQ", $sformatf(
                  {"%s.%s: writing from the reset value, because '%s' cannot be read and has not ",
                   "been written through this layer yet"}, reg_name, field_name, reg_name),
                  UVM_MEDIUM)
      write(reg_model.base_address + r.offset, word, resp, .strb(strb));
      last_num_bus_accesses = 1;
      if (resp == AXI_LITE_OKAY) r.set_shadow(word);
    end

    default: `uvm_fatal("REGSEQ", $sformatf("unhandled strategy %s", last_strategy.name()))
  endcase

  blocking = was_blocking;
  num_field_writes++;

  `uvm_info("REGSEQ", $sformatf("write %s.%s = 0x%0h via %s (%0d bus access%s) -> %s", reg_name,
                                field_name, value,
                                axi_lite_strategy_short(last_strategy),
                                last_num_bus_accesses, (last_num_bus_accesses == 1) ? "" : "es",
                                resp.name()), UVM_HIGH)
endtask : field_write

task axi_lite_reg_seq::field_read(string reg_name, string field_name, output axi_lite_data_t value,
                                  output axi_lite_resp_e resp);
  axi_lite_reg    r;
  axi_lite_field  f;
  axi_lite_data_t word;

  value = '0;
  resp  = AXI_LITE_SLVERR;

  r = reg_model.get_reg(reg_name);
  if (r == null) return;
  f = r.get_field(field_name);
  if (f == null) return;

  if (!axi_lite_access_is_readable(f.access)) begin
    `uvm_error("REGMODEL", $sformatf("%s.%s is %s and cannot be read", reg_name, field_name,
                                     axi_lite_access_short(f.access)))
    return;
  end

  reg_read(reg_name, word, resp);
  if (resp == AXI_LITE_OKAY) value = f.unpack(word);
endtask : field_read

task axi_lite_reg_seq::reg_write_fields(string reg_name, axi_lite_data_t values[string],
                                        output axi_lite_resp_e resp);
  axi_lite_reg      r;
  axi_lite_seq_item probe;
  axi_lite_data_t   word;
  axi_lite_data_t   touched = '0;
  axi_lite_strb_t   strb;
  bit               need_read;
  bit               was_blocking = blocking;

  check_geometry();
  resp = AXI_LITE_SLVERR;

  r = reg_model.get_reg(reg_name);
  if (r == null) return;
  if (values.size() == 0) begin
    `uvm_error("REGMODEL", $sformatf("reg_write_fields('%s') was given no fields", reg_name))
    return;
  end

  // Validate every name and value before touching the bus, so a typo in
  // the third field does not leave the first two already written.
  foreach (values[fname]) begin
    axi_lite_field f = r.get_field(fname);
    if (f == null) return;
    if (!axi_lite_access_is_writable(f.access)) begin
      `uvm_error("REGMODEL", $sformatf("%s.%s is %s and cannot be written", reg_name, fname,
                                       axi_lite_access_short(f.access)))
      return;
    end
    if (!f.fits(values[fname])) begin
      `uvm_error("REGMODEL", $sformatf("0x%0h does not fit in %s.%s, which is %0d bit(s) wide",
                                       values[fname], reg_name, fname, f.width))
      return;
    end
    touched |= f.mask;
  end

  probe = new_item("fields_probe");
  if ((touched & ~probe.data_mask) != '0) begin
    `uvm_error("REGMODEL", $sformatf("the named fields of '%s' reach past this link's %0d-bit bus",
                                     reg_name, probe.data_width))
    return;
  end

  blocking = 1'b1;

  // A read is needed only if the named fields leave implemented bits
  // behind that a plain write would clobber -- and only if reading is
  // safe. Writing every implemented bit of the register needs no read at
  // all, which is the common case for a control register being set up.
  need_read = ((r.implemented_mask() & ~touched) != '0) && r.is_readable() &&
      !r.read_has_side_effects() && !r.has_modal_fields();

  if (need_read) begin
    axi_lite_data_t current;
    read(reg_model.base_address + r.offset, current, resp);
    if (resp != AXI_LITE_OKAY) begin
      `uvm_error("REGMODEL", $sformatf(
                 "reg_write_fields('%s'): the read answered %s, so the write was abandoned",
                 reg_name, resp.name()))
      blocking = was_blocking;
      return;
    end
    word = current;
  end else begin
    word = shadow_basis(r);
  end

  foreach (values[fname]) begin
    axi_lite_field f = r.get_field(fname);
    word = (word & ~f.mask) | f.pack(values[fname]);
  end

  strb = probe.strb_mask;
  write(reg_model.base_address + r.offset, word, resp, .strb(strb));
  blocking = was_blocking;

  num_reg_writes++;
  if (resp == AXI_LITE_OKAY) r.set_shadow(word);

  `uvm_info("REGSEQ", $sformatf("write %s = 0x%0h (%0d field(s)%s) -> %s", reg_name, word,
                                values.size(), need_read ? ", read-modify-write" : "",
                                resp.name()), UVM_HIGH)
endtask : reg_write_fields

task axi_lite_reg_seq::field_write_enum(string reg_name, string field_name, string enum_name,
                                        output axi_lite_resp_e resp);
  axi_lite_field f = reg_model.get_field(reg_name, field_name);
  resp = AXI_LITE_SLVERR;
  if (f == null) return;
  if (!f.has_enum(enum_name)) begin
    `uvm_error("REGMODEL", $sformatf("%s.%s has no enumerated value '%s'. It has: %s", reg_name,
                                     field_name, enum_name, f.enum_list()))
    return;
  end
  field_write(reg_name, field_name, f.enum_value(enum_name), resp);
endtask : field_write_enum

task axi_lite_reg_seq::field_read_enum(string reg_name, string field_name, output string enum_name,
                                       output axi_lite_resp_e resp);
  axi_lite_field  f = reg_model.get_field(reg_name, field_name);
  axi_lite_data_t value;
  enum_name = "";
  resp      = AXI_LITE_SLVERR;
  if (f == null) return;
  field_read(reg_name, field_name, value, resp);
  if (resp != AXI_LITE_OKAY) return;
  enum_name = f.enum_name_of(value);
  if (enum_name == "")
    `uvm_info("REGSEQ", $sformatf("%s.%s read 0x%0h, which is not one of its enumerated values {%s}",
                                  reg_name, field_name, value, f.enum_list()), UVM_MEDIUM)
endtask : field_read_enum

task axi_lite_reg_seq::reg_check(string reg_name, axi_lite_data_t expected);
  axi_lite_data_t got;
  axi_lite_resp_e resp;

  num_checks++;
  reg_read(reg_name, got, resp);
  if (resp != AXI_LITE_OKAY) begin
    num_check_failures++;
    `uvm_error("REGCHECK", $sformatf("reading '%s' answered %s", reg_name, resp.name()))
    return;
  end
  if (got !== expected) begin
    num_check_failures++;
    `uvm_error("REGCHECK", $sformatf("%s read 0x%0h, expected 0x%0h (differing bits 0x%0h)",
                                     reg_name, got, expected, got ^ expected))
  end
endtask : reg_check

task axi_lite_reg_seq::field_check(string reg_name, string field_name, axi_lite_data_t expected);
  axi_lite_data_t got;
  axi_lite_resp_e resp;
  axi_lite_field  f = reg_model.get_field(reg_name, field_name);

  num_checks++;
  if (f == null) begin
    num_check_failures++;
    return;
  end
  field_read(reg_name, field_name, got, resp);
  if (resp != AXI_LITE_OKAY) begin
    num_check_failures++;
    `uvm_error("REGCHECK", $sformatf("reading %s.%s answered %s", reg_name, field_name,
                                     resp.name()))
    return;
  end
  if (got !== expected) begin
    string got_enum = f.enum_name_of(got);
    string exp_enum = f.enum_name_of(expected);
    num_check_failures++;
    `uvm_error("REGCHECK", $sformatf("%s.%s read 0x%0h%s, expected 0x%0h%s", reg_name, field_name,
                                     got, (got_enum == "") ? "" : {" (", got_enum, ")"}, expected,
                                     (exp_enum == "") ? "" : {" (", exp_enum, ")"}))
  end
endtask : field_check

// Reads every register that can be read and compares it with the reset
// value the map declares, ignoring bits no field implements -- a
// generated block returns zero there, but that is its choice rather than
// something the map states.
//
// Registers with a read side effect are skipped and named: reading them
// to check a reset value would destroy the thing being checked.
task axi_lite_reg_seq::check_all_resets();
  foreach (reg_model.regs[i]) begin
    axi_lite_reg    r = reg_model.regs[i];
    axi_lite_data_t got;
    axi_lite_resp_e resp;

    if (!r.is_readable()) continue;
    if (r.read_has_side_effects()) begin
      `uvm_info("REGCHECK", $sformatf(
                "skipping '%s': reading it clears or unlatches a field, so the check would be the side effect",
                r.reg_name), UVM_MEDIUM)
      continue;
    end

    num_checks++;
    reg_read(r.reg_name, got, resp);
    if (resp != AXI_LITE_OKAY) begin
      num_check_failures++;
      `uvm_error("REGCHECK", $sformatf("reading '%s' answered %s", r.reg_name, resp.name()))
      continue;
    end
    if ((got & r.implemented_mask()) !== (r.reset_value() & r.implemented_mask())) begin
      num_check_failures++;
      `uvm_error("REGCHECK", $sformatf("%s read 0x%0h out of reset, expected 0x%0h (mask 0x%0h)",
                                       r.reg_name, got, r.reset_value(), r.implemented_mask()))
    end
  end
endtask : check_all_resets
