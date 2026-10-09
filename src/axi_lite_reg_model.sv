///////////////////////////////////////////////////////////////////
// Filename: axi_lite_reg_model.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : A named register map -- registers, bit fields, access
//           modes and enumerated values -- so a test can say
//           "CTRL.MODE = STREAM" instead of computing an address, a
//           shift and a mask by hand.
///////////////////////////////////////////////////////////////////
//
// Why this exists
// ---------------
// Without it, driving a generated register block means writing the
// address, the shift and the mask out at every call site:
//
//   write(12'h004, (gain << 8), resp, .strb(4'b0010));
//
// Three magic numbers, each of which silently goes stale the moment the
// register map is regenerated. With it:
//
//   field_write("CTRL", "GAIN", gain, resp);
//
// and the addresses come from the map rather than from memory.
//
// Why it is a runtime object and not a package of parameters
// ----------------------------------------------------------
// Corsair's SystemVerilogPackage generator exports exactly that -- a flat
// list of `parameter CSR_CTRL_GAIN_LSB = 8;` and friends. Parameters are
// elaboration-time constants with no runtime identity: SystemVerilog
// cannot look one up by string, iterate them, or ask which fields a
// register has. A *named* API therefore needs a real data structure, and
// this is it. See docs/register-maps.md for the two ways to fill it in
// from Corsair output.
//
// This class is deliberately unparameterized, like the rest of the UVC's
// model layer: a register map describes a peripheral, not a bus width, so
// one map works against a 32-bit link and a 64-bit one.

// ---------------------------------------------------------------------
// Access modes.
//
// These are Corsair's ten modes verbatim (corsair/bitfield.py), not a
// reduced set, because the distinctions are exactly what decides whether
// a field can be written safely:
//
//   rw    read/write
//   rw1c  read, write 1 to clear
//   rw1s  read, write 1 to set
//   rw1t  read, write 1 to toggle
//   ro    read only
//   roc   read only, cleared by the read itself
//   roll  read only, latched low until read
//   rolh  read only, latched high until read
//   wo    write only
//   wosc  write only, self-clearing
//
// Collapsing rw1c into "rw" would be the expensive mistake: a
// read-modify-write of an rw1c register writes back the ones it just
// read, clearing every flag that happened to be set. The whole point of
// carrying the mode is to not do that.
// ---------------------------------------------------------------------
typedef enum {
  AXI_LITE_ACCESS_RW,
  AXI_LITE_ACCESS_RW1C,
  AXI_LITE_ACCESS_RW1S,
  AXI_LITE_ACCESS_RW1T,
  AXI_LITE_ACCESS_RO,
  AXI_LITE_ACCESS_ROC,
  AXI_LITE_ACCESS_ROLL,
  AXI_LITE_ACCESS_ROLH,
  AXI_LITE_ACCESS_WO,
  AXI_LITE_ACCESS_WOSC
} axi_lite_access_e;

// How a single-field write was carried out. Returned by the sequence
// layer so a test can assert on the strategy as well as the result --
// "this write took one bus transaction and no read" is often the thing
// actually under test.
typedef enum {
  AXI_LITE_FIELD_WR_MODAL,     // plain write, zeros elsewhere: 0 is a no-op for rw1c/rw1s/rw1t
  AXI_LITE_FIELD_WR_STROBE,    // byte-strobed write: the field exactly fills whole byte lanes
  AXI_LITE_FIELD_WR_RMW,       // read, substitute, write back
  AXI_LITE_FIELD_WR_SHADOW,    // unreadable or unsafe to read: substitute into the shadow value
  AXI_LITE_FIELD_WR_NONE       // not attempted (field is not writable)
} axi_lite_field_write_strategy_e;

// Can a read of a field with this access mode return anything meaningful?
function automatic bit axi_lite_access_is_readable(axi_lite_access_e access);
  return !(access inside {AXI_LITE_ACCESS_WO, AXI_LITE_ACCESS_WOSC});
endfunction

// Can a write to a field with this access mode change anything?
function automatic bit axi_lite_access_is_writable(axi_lite_access_e access);
  return !(access inside {AXI_LITE_ACCESS_RO, AXI_LITE_ACCESS_ROC,
                          AXI_LITE_ACCESS_ROLL, AXI_LITE_ACCESS_ROLH});
endfunction

// Does reading this field change the state of the DUT? If so, a
// read-modify-write aimed at a *sibling* field in the same register is
// destructive even though it never mentions this one -- the read is the
// side effect.
function automatic bit axi_lite_access_read_has_side_effects(axi_lite_access_e access);
  return access inside {AXI_LITE_ACCESS_ROC, AXI_LITE_ACCESS_ROLL, AXI_LITE_ACCESS_ROLH};
endfunction

// For these modes a written 0 means "leave this bit alone" and a written
// 1 means "act on it", so a field can be written in place with no read
// and no strobes -- and a read-modify-write would be actively wrong.
function automatic bit axi_lite_access_write_is_modal(axi_lite_access_e access);
  return access inside {AXI_LITE_ACCESS_RW1C, AXI_LITE_ACCESS_RW1S,
                        AXI_LITE_ACCESS_RW1T, AXI_LITE_ACCESS_WOSC};
endfunction

// Right-pad a string to `width` with spaces.
//
// Two XSIM 2023.2 bugs meet in this four-line function, and both are
// silent, so it is written the way it is on purpose.
//
// 1. It exists at all because XSIM ignores the '-' (left-justify) flag in
//    $display and $sformatf completely -- for %s and %d alike -- and
//    right-justifies regardless. A column built with "%-12s" comes out
//    jumbled rather than aligned.
//
// 2. It builds the padding in a separate string and concatenates once,
//    rather than the obvious
//
//        string out = s;
//        while (out.len() < width) out = {out, " "};
//
//    because XSIM aliases a `string` formal to the caller's actual
//    instead of copying it. Assigning that formal to a local and then
//    growing the local writes *through* to the caller: calling the
//    obvious version on a class member silently replaces that member
//    with the padded text, or with a single space. A register map
//    printed its own names correctly and then could not find any of
//    them, because printing it had destroyed them.
//
//    `s` is therefore only ever read, never assigned to a local that is
//    later modified.
function automatic string axi_lite_pad(string s, int unsigned width);
  string spaces = "";
  for (int unsigned i = s.len(); i < width; i++) spaces = {spaces, " "};
  return {s, spaces};
endfunction

// Readable short names for the two enumerations above.
//
// The prefix length is taken from the prefix itself rather than written
// as a number: passing the wrong count silently eats the first letter of
// the name ("STROBE" printed as "TROBE"), which is a mistake that looks
// like a typo in the enum rather than a bug in the formatting.
function automatic string axi_lite_access_short(axi_lite_access_e access);
  string prefix = "AXI_LITE_ACCESS_";
  return axi_lite_short_name(access.name(), prefix.len());
endfunction

function automatic string axi_lite_strategy_short(axi_lite_field_write_strategy_e strategy);
  string prefix = "AXI_LITE_FIELD_WR_";
  return axi_lite_short_name(strategy.name(), prefix.len());
endfunction

// Parse Corsair's spelling. Kept here rather than in the generator so
// that a hand-written map and a generated one agree on what "rw1c" means.
function automatic axi_lite_access_e axi_lite_access_from_string(string s);
  case (s)
    "rw":   return AXI_LITE_ACCESS_RW;
    "rw1c": return AXI_LITE_ACCESS_RW1C;
    "rw1s": return AXI_LITE_ACCESS_RW1S;
    "rw1t": return AXI_LITE_ACCESS_RW1T;
    "ro":   return AXI_LITE_ACCESS_RO;
    "roc":  return AXI_LITE_ACCESS_ROC;
    "roll": return AXI_LITE_ACCESS_ROLL;
    "rolh": return AXI_LITE_ACCESS_ROLH;
    "wo":   return AXI_LITE_ACCESS_WO;
    "wosc": return AXI_LITE_ACCESS_WOSC;
    default: begin
      `uvm_error("REGMODEL", $sformatf("unknown access mode '%s'; treating it as 'rw'", s))
      return AXI_LITE_ACCESS_RW;
    end
  endcase
endfunction


///////////////////////////////////////////////////////////////////
// One bit field.
///////////////////////////////////////////////////////////////////
class axi_lite_field extends uvm_object;

  string            field_name;
  int unsigned      lsb = 0;
  int unsigned      width = 1;
  axi_lite_data_t   mask = 1;      // (2**width - 1) << lsb, precomputed
  axi_lite_data_t   reset_value = 0;
  axi_lite_access_e access = AXI_LITE_ACCESS_RW;
  string            description = "";

  // Enumerated values, as parallel queues rather than an assoc array so
  // that both directions (name -> value, value -> name) are cheap and the
  // declaration order is preserved for reporting.
  string          enum_names[$];
  axi_lite_data_t enum_values[$];

  // Set by axi_lite_reg::add_field, so a field can name its own parent in
  // an error message without the caller having to supply it.
  string reg_name = "";

  `uvm_object_utils(axi_lite_field)

  extern function new(string name = "axi_lite_field");

  // The one call that builds a usable field. `mask` is derived rather
  // than passed, so a generator cannot emit a mask that disagrees with
  // its own lsb/width.
  extern function void configure(string field_name, int unsigned lsb, int unsigned width,
                                 axi_lite_access_e access = AXI_LITE_ACCESS_RW,
                                 axi_lite_data_t reset_value = 0, string description = "");

  extern function void add_enum(string enum_name, axi_lite_data_t value, string description = "");
  extern function bit has_enum(string enum_name);
  extern function axi_lite_data_t enum_value(string enum_name);
  // Name for a value, or "" if the value is not enumerated.
  extern function string enum_name_of(axi_lite_data_t value);
  extern function string enum_list();

  extern function int unsigned msb();
  // Does this field's mask exactly fill the byte lanes it touches? If so
  // it can be written with byte strobes alone -- no read, and no risk to
  // any sibling, because a mask that fills its lanes leaves no room in
  // them for one.
  extern function bit fills_whole_byte_lanes();
  // Byte-lane enables covering this field.
  extern function axi_lite_strb_t byte_lanes();

  // value -> register word, and register word -> value.
  extern function axi_lite_data_t pack(axi_lite_data_t value);
  extern function axi_lite_data_t unpack(axi_lite_data_t reg_value);
  // Does `value` fit in this field?
  extern function bit fits(axi_lite_data_t value);

  extern virtual function string convert2string();

endclass : axi_lite_field

function axi_lite_field::new(string name = "axi_lite_field");
  super.new(name);
endfunction : new

function void axi_lite_field::configure(string field_name, int unsigned lsb, int unsigned width,
                                        axi_lite_access_e access = AXI_LITE_ACCESS_RW,
                                        axi_lite_data_t reset_value = 0, string description = "");
  if (width == 0) `uvm_fatal("REGMODEL", $sformatf("field '%s' has zero width", field_name))
  if ((lsb + width) > AXI_LITE_MAX_DATA_WIDTH)
    `uvm_fatal("REGMODEL", $sformatf(
               "field '%s' occupies bits %0d:%0d, past the %0d the transaction can carry",
               field_name, lsb + width - 1, lsb, AXI_LITE_MAX_DATA_WIDTH))

  this.field_name  = field_name;
  this.lsb         = lsb;
  this.width       = width;
  this.access      = access;
  this.description = description;

  // ((1 << width) - 1) << lsb, computed in a wide enough type that a
  // 64-bit-wide field does not shift its own top bit off the end.
  this.mask = (((axi_lite_data_t'(1) << width) - 1) << lsb);
  this.reset_value = reset_value & ((axi_lite_data_t'(1) << width) - 1);
endfunction : configure

function void axi_lite_field::add_enum(string enum_name, axi_lite_data_t value,
                                       string description = "");
  if (has_enum(enum_name))
    `uvm_warning("REGMODEL", $sformatf("%s.%s already has an enum '%s'; overwriting it",
                                       reg_name, field_name, enum_name))
  enum_names.push_back(enum_name);
  enum_values.push_back(value);
endfunction : add_enum

function bit axi_lite_field::has_enum(string enum_name);
  foreach (enum_names[i]) if (enum_names[i] == enum_name) return 1'b1;
  return 1'b0;
endfunction : has_enum

function axi_lite_data_t axi_lite_field::enum_value(string enum_name);
  foreach (enum_names[i]) if (enum_names[i] == enum_name) return enum_values[i];
  `uvm_error("REGMODEL", $sformatf("%s.%s has no enumerated value '%s'. It has: %s",
                                   reg_name, field_name, enum_name, enum_list()))
  return 0;
endfunction : enum_value

function string axi_lite_field::enum_name_of(axi_lite_data_t value);
  foreach (enum_values[i]) if (enum_values[i] == value) return enum_names[i];
  return "";
endfunction : enum_name_of

function string axi_lite_field::enum_list();
  string s = "";
  foreach (enum_names[i]) s = {s, (i == 0) ? "" : ", ", enum_names[i]};
  return (s == "") ? "(none)" : s;
endfunction : enum_list

function int unsigned axi_lite_field::msb();
  return lsb + width - 1;
endfunction : msb

function bit axi_lite_field::fills_whole_byte_lanes();
  // Equivalent to "lsb is byte aligned and width is a whole number of
  // bytes", but written as a mask comparison so there is one definition
  // of the property and byte_lanes() below cannot drift from it.
  axi_lite_data_t lane_mask = '0;
  axi_lite_strb_t lanes = byte_lanes();
  foreach (lanes[i]) if (lanes[i]) lane_mask |= (axi_lite_data_t'(8'hFF) << (i * 8));
  return (lane_mask == mask);
endfunction : fills_whole_byte_lanes

function axi_lite_strb_t axi_lite_field::byte_lanes();
  axi_lite_strb_t lanes = '0;
  for (int unsigned b = 0; b < AXI_LITE_MAX_STRB_WIDTH; b++)
    if ((mask >> (b * 8)) & 8'hFF) lanes[b] = 1'b1;
  return lanes;
endfunction : byte_lanes

function axi_lite_data_t axi_lite_field::pack(axi_lite_data_t value);
  return (value << lsb) & mask;
endfunction : pack

function axi_lite_data_t axi_lite_field::unpack(axi_lite_data_t reg_value);
  return (reg_value & mask) >> lsb;
endfunction : unpack

function bit axi_lite_field::fits(axi_lite_data_t value);
  return (value >> width) == '0;
endfunction : fits

function string axi_lite_field::convert2string();
  string s = $sformatf("%s bits %2d:%2d %4s  reset 0x%0h",
                       axi_lite_pad($sformatf("%s.%s", reg_name, field_name), 22), msb(), lsb,
                       axi_lite_access_short(access), reset_value);
  if (enum_names.size() > 0) s = {s, $sformatf("  {%s}", enum_list())};
  return s;
endfunction : convert2string


///////////////////////////////////////////////////////////////////
// One register: an address, and the fields inside it.
///////////////////////////////////////////////////////////////////
class axi_lite_reg extends uvm_object;

  string          reg_name;
  axi_lite_addr_t offset = 0;      // relative to the model's base_address
  string          description = "";

  axi_lite_field  fields[$];
  string          description_of_map = "";

  // Last value this testbench is entitled to believe is in the register:
  // the reset value, updated by every write the sequence layer performs.
  // It is what makes a field write possible on a register that cannot be
  // read -- see axi_lite_reg_seq::field_write.
  axi_lite_data_t shadow = 0;

  // Cleared once the register has been written or read, so the sequence
  // layer can tell "the shadow is the reset value because nothing has
  // happened yet" from "the shadow reflects a write we did".
  bit shadow_is_reset = 1'b1;

  protected int m_field_index[string];

  `uvm_object_utils(axi_lite_reg)

  extern function new(string name = "axi_lite_reg");

  extern function void configure(string reg_name, axi_lite_addr_t offset, string description = "");
  extern function void add_field(axi_lite_field field);

  extern function bit has_field(string field_name);
  // Errors and returns null on a name that is not in the register. The
  // message lists the fields that are, since a typo is the likeliest
  // cause and the answer is almost always visible in that list.
  extern function axi_lite_field get_field(string field_name);
  extern function string field_list();

  // Reset value of the whole word, assembled from the fields.
  extern function axi_lite_data_t reset_value();
  // Bits covered by at least one field. Bits outside it are unimplemented
  // and read as zero on most generated blocks.
  extern function axi_lite_data_t implemented_mask();

  extern function bit is_readable();
  extern function bit is_writable();
  // Any field whose *read* changes DUT state, which makes a
  // read-modify-write of any field in this register destructive.
  extern function bit read_has_side_effects();
  // Any field for which a written 1 acts rather than stores, which makes
  // writing back a read value destructive.
  extern function bit has_modal_fields();

  extern function void set_shadow(axi_lite_data_t value);

  extern virtual function string convert2string();

endclass : axi_lite_reg

function axi_lite_reg::new(string name = "axi_lite_reg");
  super.new(name);
endfunction : new

function void axi_lite_reg::configure(string reg_name, axi_lite_addr_t offset,
                                      string description = "");
  this.reg_name    = reg_name;
  this.offset      = offset;
  this.description = description;
endfunction : configure

function void axi_lite_reg::add_field(axi_lite_field field);
  if (field == null) `uvm_fatal("REGMODEL", $sformatf("null field added to register '%s'", reg_name))
  if (has_field(field.field_name))
    `uvm_fatal("REGMODEL", $sformatf("register '%s' already has a field '%s'", reg_name,
                                     field.field_name))

  // Overlap is worth a fatal rather than a warning: two fields sharing a
  // bit makes every masking decision below ambiguous, and a generated map
  // should never produce one, so it means the map is wrong.
  foreach (fields[i])
    if (fields[i].mask & field.mask)
      `uvm_fatal("REGMODEL", $sformatf("%s.%s (bits %0d:%0d) overlaps %s.%s (bits %0d:%0d)",
                                       reg_name, field.field_name, field.msb(), field.lsb,
                                       reg_name, fields[i].field_name, fields[i].msb(),
                                       fields[i].lsb))

  field.reg_name = reg_name;
  m_field_index[field.field_name] = fields.size();
  fields.push_back(field);

  shadow = reset_value();
endfunction : add_field

function bit axi_lite_reg::has_field(string field_name);
  return m_field_index.exists(field_name);
endfunction : has_field

function axi_lite_field axi_lite_reg::get_field(string field_name);
  if (!has_field(field_name)) begin
    `uvm_error("REGMODEL", $sformatf("register '%s' has no field '%s'. It has: %s", reg_name,
                                     field_name, field_list()))
    return null;
  end
  return fields[m_field_index[field_name]];
endfunction : get_field

function string axi_lite_reg::field_list();
  string s = "";
  foreach (fields[i]) s = {s, (i == 0) ? "" : ", ", fields[i].field_name};
  return (s == "") ? "(none)" : s;
endfunction : field_list

function axi_lite_data_t axi_lite_reg::reset_value();
  axi_lite_data_t v = '0;
  foreach (fields[i]) v |= fields[i].pack(fields[i].reset_value);
  return v;
endfunction : reset_value

function axi_lite_data_t axi_lite_reg::implemented_mask();
  axi_lite_data_t v = '0;
  foreach (fields[i]) v |= fields[i].mask;
  return v;
endfunction : implemented_mask

function bit axi_lite_reg::is_readable();
  foreach (fields[i]) if (axi_lite_access_is_readable(fields[i].access)) return 1'b1;
  return 1'b0;
endfunction : is_readable

function bit axi_lite_reg::is_writable();
  foreach (fields[i]) if (axi_lite_access_is_writable(fields[i].access)) return 1'b1;
  return 1'b0;
endfunction : is_writable

function bit axi_lite_reg::read_has_side_effects();
  foreach (fields[i]) if (axi_lite_access_read_has_side_effects(fields[i].access)) return 1'b1;
  return 1'b0;
endfunction : read_has_side_effects

function bit axi_lite_reg::has_modal_fields();
  foreach (fields[i]) if (axi_lite_access_write_is_modal(fields[i].access)) return 1'b1;
  return 1'b0;
endfunction : has_modal_fields

function void axi_lite_reg::set_shadow(axi_lite_data_t value);
  shadow          = value;
  shadow_is_reset = 1'b0;
endfunction : set_shadow

function string axi_lite_reg::convert2string();
  string s = $sformatf("%s @ 0x%-4h  reset 0x%0h", axi_lite_pad(reg_name, 10), offset,
                       reset_value());
  foreach (fields[i]) s = {s, "\n    ", fields[i].convert2string()};
  return s;
endfunction : convert2string


///////////////////////////////////////////////////////////////////
// The map: a base address, and the registers in it by name.
///////////////////////////////////////////////////////////////////
class axi_lite_reg_model extends uvm_object;

  // Added to every register's offset to get the bus address. Kept
  // separate from the offsets so the same map can be instantiated twice
  // at two base addresses -- which is what happens the moment a design
  // has two of the same peripheral.
  axi_lite_addr_t base_address = 0;

  // Width the map was generated for, from Corsair's globcfg. Checked
  // against the link's real width when a sequence first uses the map,
  // because a 32-bit map driven over a 64-bit bus needs its addresses
  // reconsidered, not silently reinterpreted.
  int unsigned data_width = 32;

  string map_name = "";

  axi_lite_reg regs[$];

  protected int m_reg_index[string];

  `uvm_object_utils(axi_lite_reg_model)

  extern function new(string name = "axi_lite_reg_model");

  extern function void configure(string map_name, axi_lite_addr_t base_address = 0,
                                 int unsigned data_width = 32);
  extern function void add_reg(axi_lite_reg r);

  // Build and register in one call, so a generated map reads as a flat
  // list rather than as object plumbing.
  extern function axi_lite_reg create_reg(string reg_name, axi_lite_addr_t offset,
                                          string description = "");
  extern function axi_lite_field create_field(string reg_name, string field_name,
                                              int unsigned lsb, int unsigned width,
                                              axi_lite_access_e access = AXI_LITE_ACCESS_RW,
                                              axi_lite_data_t reset_value = 0,
                                              string description = "");

  extern function bit has_reg(string reg_name);
  // Errors and returns null on an unknown name, naming the closest match
  // it can find. A mistyped string would otherwise be a null dereference
  // several frames away from the typo.
  extern function axi_lite_reg get_reg(string reg_name);
  extern function axi_lite_field get_field(string reg_name, string field_name);

  // Bus address of a register, base address included.
  extern function axi_lite_addr_t addr_of(string reg_name);

  extern function string reg_list();
  extern protected function string nearest_reg_name(string reg_name);

  // Every register's shadow back to its reset value. Call it from a
  // test's reset handling: the shadow is this testbench's belief about
  // the DUT, and a reset invalidates it.
  extern function void reset_shadows();

  extern function int unsigned num_fields();
  extern function void print_map(int unsigned verbosity = UVM_LOW);
  extern virtual function string convert2string();

endclass : axi_lite_reg_model

function axi_lite_reg_model::new(string name = "axi_lite_reg_model");
  super.new(name);
  map_name = name;
endfunction : new

function void axi_lite_reg_model::configure(string map_name, axi_lite_addr_t base_address = 0,
                                            int unsigned data_width = 32);
  this.map_name     = map_name;
  this.base_address = base_address;
  this.data_width   = data_width;
endfunction : configure

function void axi_lite_reg_model::add_reg(axi_lite_reg r);
  if (r == null) `uvm_fatal("REGMODEL", "null register added to the map")
  if (has_reg(r.reg_name))
    `uvm_fatal("REGMODEL", $sformatf("map '%s' already has a register '%s'", map_name, r.reg_name))

  // Two registers at one address is a map error, not a usable
  // configuration: a read of that address cannot mean both.
  foreach (regs[i])
    if (regs[i].offset == r.offset)
      `uvm_fatal("REGMODEL", $sformatf("'%s' and '%s' are both at offset 0x%0h in map '%s'",
                                       r.reg_name, regs[i].reg_name, r.offset, map_name))

  m_reg_index[r.reg_name] = regs.size();
  regs.push_back(r);
endfunction : add_reg

function axi_lite_reg axi_lite_reg_model::create_reg(string reg_name, axi_lite_addr_t offset,
                                                     string description = "");
  axi_lite_reg r = axi_lite_reg::type_id::create(reg_name);
  r.configure(reg_name, offset, description);
  add_reg(r);
  return r;
endfunction : create_reg

function axi_lite_field axi_lite_reg_model::create_field(string reg_name, string field_name,
                                                         int unsigned lsb, int unsigned width,
                                                         axi_lite_access_e access = AXI_LITE_ACCESS_RW,
                                                         axi_lite_data_t reset_value = 0,
                                                         string description = "");
  axi_lite_reg   r = get_reg(reg_name);
  axi_lite_field f;
  if (r == null) return null;
  f = axi_lite_field::type_id::create(field_name);
  f.configure(field_name, lsb, width, access, reset_value, description);
  r.add_field(f);
  return f;
endfunction : create_field

function bit axi_lite_reg_model::has_reg(string reg_name);
  return m_reg_index.exists(reg_name);
endfunction : has_reg

function axi_lite_reg axi_lite_reg_model::get_reg(string reg_name);
  if (!has_reg(reg_name)) begin
    string near = nearest_reg_name(reg_name);
    if (near != "")
      `uvm_error("REGMODEL", $sformatf("map '%s' has no register '%s'. Did you mean '%s'?",
                                       map_name, reg_name, near))
    else
      `uvm_error("REGMODEL", $sformatf("map '%s' has no register '%s'. It has: %s", map_name,
                                       reg_name, reg_list()))
    return null;
  end
  return regs[m_reg_index[reg_name]];
endfunction : get_reg

function axi_lite_field axi_lite_reg_model::get_field(string reg_name, string field_name);
  axi_lite_reg r = get_reg(reg_name);
  if (r == null) return null;
  return r.get_field(field_name);
endfunction : get_field

function axi_lite_addr_t axi_lite_reg_model::addr_of(string reg_name);
  axi_lite_reg r = get_reg(reg_name);
  if (r == null) return '0;
  return base_address + r.offset;
endfunction : addr_of

function string axi_lite_reg_model::reg_list();
  string s = "";
  foreach (regs[i]) s = {s, (i == 0) ? "" : ", ", regs[i].reg_name};
  return (s == "") ? "(none)" : s;
endfunction : reg_list

// A deliberately crude suggestion: an exact match ignoring case, else the
// longest shared prefix of at least three characters. It is not an edit
// distance and does not need to be -- it exists to turn "no such
// register" into "no such register, did you mean CTRL", which covers the
// case/typo mistakes that actually happen.
function string axi_lite_reg_model::nearest_reg_name(string reg_name);
  string best       = "";
  int    best_score = 0;

  foreach (regs[i]) begin
    string cand = regs[i].reg_name;
    if (cand.tolower() == reg_name.tolower()) return cand;
  end

  foreach (regs[i]) begin
    string cand  = regs[i].reg_name;
    string lc    = cand.tolower();
    string lr    = reg_name.tolower();
    int    score = 0;
    int    limit = (lc.len() < lr.len()) ? lc.len() : lr.len();
    while ((score < limit) && (lc[score] == lr[score])) score++;
    if (score > best_score) begin
      best_score = score;
      best       = cand;
    end
  end

  return (best_score >= 3) ? best : "";
endfunction : nearest_reg_name

function void axi_lite_reg_model::reset_shadows();
  foreach (regs[i]) begin
    regs[i].shadow          = regs[i].reset_value();
    regs[i].shadow_is_reset = 1'b1;
  end
endfunction : reset_shadows

function int unsigned axi_lite_reg_model::num_fields();
  int unsigned n = 0;
  foreach (regs[i]) n += regs[i].fields.size();
  return n;
endfunction : num_fields

function void axi_lite_reg_model::print_map(int unsigned verbosity = UVM_LOW);
  `uvm_info("REGMODEL", convert2string(), verbosity)
endfunction : print_map

function string axi_lite_reg_model::convert2string();
  string s = $sformatf("register map '%s': %0d registers, %0d fields, base 0x%0h, %0d-bit",
                       map_name, regs.size(), num_fields(), base_address, data_width);
  foreach (regs[i]) s = {s, "\n  ", regs[i].convert2string()};
  return s;
endfunction : convert2string
