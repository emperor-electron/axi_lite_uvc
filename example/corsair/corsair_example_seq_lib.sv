///////////////////////////////////////////////////////////////////
// Filename: corsair_example_seq_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Sequences driving the Corsair-generated block by name, and
//           checking that each field-write strategy did what it claims.
///////////////////////////////////////////////////////////////////
//
// Every sequence here extends axi_lite_reg_seq, so it has reg_write(),
// reg_read(), field_write(), field_read(), reg_write_fields() and the
// check tasks. None of them contains an address, a shift or a mask.

// ---------------------------------------------------------------------
// Common parent: holds the hardware-side interface, since several of
// these need to arrange a DUT state the bus cannot create.
// ---------------------------------------------------------------------
virtual class corsair_base_seq extends axi_lite_reg_seq;

  corsair_hw_vif_t hw_vif;

  extern function new(string name = "corsair_base_seq");

  // Reports a UVM_ERROR unless the last field_write used the strategy
  // the caller expected. The strategy is not an implementation detail
  // here: "this write cost one bus access and no read" is often the
  // property under test, and it is the difference between a correct and
  // a destructive write on a write-1-to-clear register.
  extern function void expect_strategy(string what,
                                       axi_lite_field_write_strategy_e expected,
                                       int unsigned expected_accesses = 0);

endclass : corsair_base_seq

function corsair_base_seq::new(string name = "corsair_base_seq");
  super.new(name);
endfunction : new

function void corsair_base_seq::expect_strategy(string what,
                                                axi_lite_field_write_strategy_e expected,
                                                int unsigned expected_accesses = 0);
  if (last_strategy != expected)
    `uvm_error("STRATEGY", $sformatf("%s used %s, expected %s", what,
                                     last_strategy.name(), expected.name()))
  else if ((expected_accesses != 0) && (last_num_bus_accesses != expected_accesses))
    `uvm_error("STRATEGY", $sformatf("%s took %0d bus access(es), expected %0d", what,
                                     last_num_bus_accesses, expected_accesses))
  else
    `uvm_info("STRATEGY", $sformatf("%s: %s, %0d bus access(es)", what,
                                    axi_lite_strategy_short(last_strategy),
                                    last_num_bus_accesses), UVM_LOW)
endfunction : expect_strategy


///////////////////////////////////////////////////////////////////
// Bring-up: everything you would do by hand the first time a generated
// block appears on the bus, written as named accesses.
///////////////////////////////////////////////////////////////////
class corsair_bringup_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_bringup_seq)

  extern function new(string name = "corsair_bringup_seq");
  extern virtual task body();

endclass : corsair_bringup_seq

function corsair_bringup_seq::new(string name = "corsair_bringup_seq");
  super.new(name);
endfunction : new

task corsair_bringup_seq::body();
  axi_lite_data_t value;
  axi_lite_resp_e resp;

  // The map, as the UVC understands it. Worth printing once: if a
  // register is at an address you did not expect, this is where it shows.
  reg_model.print_map(UVM_MEDIUM);

  // Every readable register against the reset value the map declares.
  // One call, and it covers registers nobody has written a test for yet.
  check_all_resets();

  // The identification register, by field. No shift, no mask.
  field_check("ID", "MAGIC", 16'hA711);
  field_check("ID", "VERSION", 16'h0001);

  // A plain read/write word.
  reg_write("SCRATCH", 32'hDEAD_BEEF, resp);
  reg_check("SCRATCH", 32'hDEAD_BEEF);

  // ...and the same thing through the field, which is the whole word.
  field_write("SCRATCH", "VALUE", 32'h5A5A_1234, resp);
  field_check("SCRATCH", "VALUE", 32'h5A5A_1234);

  // A field read returns the field, already shifted down.
  field_read("CTRL", "GAIN", value, resp);
  if (value !== 8'h80)
    `uvm_error("BRINGUP", $sformatf("CTRL.GAIN read 0x%0h out of reset, expected 0x80", value))
endtask : body


///////////////////////////////////////////////////////////////////
// One write per strategy, each checked two ways: the strategy the UVC
// picked, and whether the fields it was not asked to touch survived.
//
// Sibling preservation is the real test. Every one of these writes is a
// single field of a register holding three others, and getting it wrong
// is silent -- the write succeeds, the response is OKAY, and some other
// field is quietly zero.
///////////////////////////////////////////////////////////////////
class corsair_strategy_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_strategy_seq)

  extern function new(string name = "corsair_strategy_seq");
  extern virtual task body();

endclass : corsair_strategy_seq

function corsair_strategy_seq::new(string name = "corsair_strategy_seq");
  super.new(name);
endfunction : new

task corsair_strategy_seq::body();
  axi_lite_resp_e resp;
  axi_lite_data_t vals[string];

  // ---- Put CTRL into a known, fully non-zero state, so that a field
  // write that clobbers a sibling cannot hide behind a zero.
  vals["ENABLE"] = 1'b1;
  vals["MODE"]   = CSR_CTRL_MODE_SINGLE;
  vals["GAIN"]   = 8'h3C;
  vals["THRESH"] = 12'h7A5;
  reg_write_fields("CTRL", vals, resp);
  if (resp != AXI_LITE_OKAY) `uvm_fatal("STRATEGY", "setting up CTRL failed")

  field_check("CTRL", "ENABLE", 1'b1);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_SINGLE);
  field_check("CTRL", "GAIN", 8'h3C);
  field_check("CTRL", "THRESH", 12'h7A5);

  // ---- STROBE: GAIN is bits 15:8, exactly byte lane 1. One write, no
  // read, and the bus itself cannot disturb the other lanes.
  field_write("CTRL", "GAIN", 8'hC7, resp);
  expect_strategy("CTRL.GAIN", AXI_LITE_FIELD_WR_STROBE, 1);
  field_check("CTRL", "GAIN", 8'hC7);
  field_check("CTRL", "ENABLE", 1'b1);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_SINGLE);
  field_check("CTRL", "THRESH", 12'h7A5);

  // ---- RMW: THRESH is bits 27:16, which fills lane 2 but only half of
  // lane 3, so strobes alone would clobber bits 31:28. CTRL is readable
  // and holds nothing modal, so a read-modify-write is safe.
  field_write("CTRL", "THRESH", 12'h123, resp);
  expect_strategy("CTRL.THRESH", AXI_LITE_FIELD_WR_RMW, 2);
  field_check("CTRL", "THRESH", 12'h123);
  field_check("CTRL", "GAIN", 8'hC7);
  field_check("CTRL", "ENABLE", 1'b1);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_SINGLE);

  // ---- RMW on a single bit in a shared lane.
  field_write("CTRL", "ENABLE", 1'b0, resp);
  expect_strategy("CTRL.ENABLE", AXI_LITE_FIELD_WR_RMW, 2);
  field_check("CTRL", "ENABLE", 1'b0);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_SINGLE);
  field_check("CTRL", "GAIN", 8'hC7);

  // ---- SHADOW: EVENT.ARM is writable, but reading EVENT clears
  // EVENT.COUNT, so a read-modify-write would destroy the counter as a
  // side effect of servicing an unrelated field.
  field_write("EVENT", "ARM", 1'b1, resp);
  expect_strategy("EVENT.ARM", AXI_LITE_FIELD_WR_SHADOW, 1);
  if (hw_vif.event_arm !== 1'b1)
    `uvm_error("STRATEGY", "EVENT.ARM was written but the DUT's output did not follow")
endtask : body


///////////////////////////////////////////////////////////////////
// The write-1-to-clear hazard, which is the reason the access mode is
// carried at all.
//
// Hardware sets IRQ.DONE and IRQ.ERROR in the same cycle. The test
// clears only DONE. A read-modify-write would read 0b11, write 0b11
// back, and clear both -- succeeding, reporting OKAY, and losing an
// interrupt. The correct access writes 0b01 and leaves ERROR alone.
///////////////////////////////////////////////////////////////////
class corsair_irq_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_irq_seq)

  extern function new(string name = "corsair_irq_seq");
  extern virtual task body();

endclass : corsair_irq_seq

function corsair_irq_seq::new(string name = "corsair_irq_seq");
  super.new(name);
endfunction : new

task corsair_irq_seq::body();
  axi_lite_resp_e resp;

  // Both flags raised by hardware at once.
  hw_vif.set_irq_both();

  field_check("IRQ", "DONE", 1'b1);
  field_check("IRQ", "ERROR", 1'b1);

  // Clear exactly one of them.
  field_write("IRQ", "DONE", 1'b1, resp);
  expect_strategy("IRQ.DONE", AXI_LITE_FIELD_WR_MODAL, 1);

  field_check("IRQ", "DONE", 1'b0);
  // The assertion that matters: a read-modify-write would have cleared
  // this one too, and nothing about the bus traffic would have looked
  // wrong.
  field_check("IRQ", "ERROR", 1'b1);

  // Now clear the other one, the same way.
  field_write("IRQ", "ERROR", 1'b1, resp);
  field_check("IRQ", "ERROR", 1'b0);
  field_check("IRQ", "DONE", 1'b0);

  // Writing 0 to a write-1-to-clear field is a no-op, not a set.
  hw_vif.set_irq_done();
  field_check("IRQ", "DONE", 1'b1);
  field_write("IRQ", "DONE", 1'b0, resp);
  field_check("IRQ", "DONE", 1'b1);
  field_write("IRQ", "DONE", 1'b1, resp);
  field_check("IRQ", "DONE", 1'b0);
endtask : body


///////////////////////////////////////////////////////////////////
// A write-only register, where no read-modify-write is possible at all.
//
// CMD cannot be read back, so the only way to write one of its fields
// without destroying the others is to remember what was written. The
// checks here read the DUT's own output ports rather than the bus,
// because the bus cannot answer the question.
///////////////////////////////////////////////////////////////////
class corsair_cmd_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_cmd_seq)

  extern function new(string name = "corsair_cmd_seq");
  extern virtual task body();

endclass : corsair_cmd_seq

function corsair_cmd_seq::new(string name = "corsair_cmd_seq");
  super.new(name);
endfunction : new

task corsair_cmd_seq::body();
  axi_lite_resp_e resp;

  // OPCODE is bits 7:0 -- exactly byte lane 0, so it goes out with
  // strobes and touches nothing else even though the register is
  // write-only.
  field_write("CMD", "OPCODE", 8'hA5, resp);
  expect_strategy("CMD.OPCODE", AXI_LITE_FIELD_WR_STROBE, 1);
  if (hw_vif.cmd_opcode !== 8'hA5)
    `uvm_error("CMD", $sformatf("CMD.OPCODE drove 0x%0h, expected 0xA5", hw_vif.cmd_opcode))

  // ARG is bits 23:8 -- lanes 1 and 2, also exactly filled.
  field_write("CMD", "ARG", 16'h1234, resp);
  expect_strategy("CMD.ARG", AXI_LITE_FIELD_WR_STROBE, 1);
  if (hw_vif.cmd_arg !== 16'h1234)
    `uvm_error("CMD", $sformatf("CMD.ARG drove 0x%0h, expected 0x1234", hw_vif.cmd_arg))
  if (hw_vif.cmd_opcode !== 8'hA5)
    `uvm_error("CMD", "writing CMD.ARG disturbed CMD.OPCODE")

  // FLAG is bit 24 alone: it shares lane 3 with nothing, but does not
  // fill it, so strobes cannot isolate it and the register cannot be
  // read. The shadow is the only thing that knows OPCODE and ARG are
  // already set, and this is what it is for.
  field_write("CMD", "FLAG", 1'b1, resp);
  expect_strategy("CMD.FLAG", AXI_LITE_FIELD_WR_SHADOW, 1);
  if (hw_vif.cmd_flag !== 1'b1)
    `uvm_error("CMD", "CMD.FLAG drove 0, expected 1")

  // The point of the whole exercise: the two fields written earlier are
  // still there. A naive whole-word write of FLAG would have zeroed both.
  if (hw_vif.cmd_opcode !== 8'hA5)
    `uvm_error("CMD", $sformatf("writing CMD.FLAG lost CMD.OPCODE (0x%0h, expected 0xA5)",
                                hw_vif.cmd_opcode))
  if (hw_vif.cmd_arg !== 16'h1234)
    `uvm_error("CMD", $sformatf("writing CMD.FLAG lost CMD.ARG (0x%0h, expected 0x1234)",
                                hw_vif.cmd_arg))
endtask : body


///////////////////////////////////////////////////////////////////
// Enumerated values and multi-field writes -- the two things that make a
// register sequence read like the datasheet it came from.
///////////////////////////////////////////////////////////////////
class corsair_enum_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_enum_seq)

  extern function new(string name = "corsair_enum_seq");
  extern virtual task body();

endclass : corsair_enum_seq

function corsair_enum_seq::new(string name = "corsair_enum_seq");
  super.new(name);
endfunction : new

task corsair_enum_seq::body();
  axi_lite_resp_e resp;
  axi_lite_data_t vals[string];
  string          mode_name;

  // By the name in the register map, as a string. The map knows the
  // value, so the test does not.
  field_write_enum("CTRL", "MODE", "STREAM", resp);
  field_read_enum("CTRL", "MODE", mode_name, resp);
  if (mode_name != "STREAM")
    `uvm_error("ENUM", $sformatf("CTRL.MODE read back as '%s', expected 'STREAM'", mode_name))

  // Or by Corsair's own exported constant, which the compiler checks.
  // Same register map, two spellings; use whichever suits the test.
  field_write("CTRL", "MODE", CSR_CTRL_MODE_LOOPBACK, resp);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_LOOPBACK);
  if (hw_vif.ctrl_mode !== 2'd3)
    `uvm_error("ENUM", $sformatf("CTRL.MODE drove %0d, expected 3", hw_vif.ctrl_mode))

  // Four fields, one bus write. Writing them one at a time would be four
  // transactions and would let the DUT see three intermediate states
  // that the test never intended.
  vals.delete();
  vals["ENABLE"] = 1'b1;
  vals["MODE"]   = CSR_CTRL_MODE_STREAM;
  vals["GAIN"]   = 8'hFF;
  vals["THRESH"] = 12'hABC;
  reg_write_fields("CTRL", vals, resp);
  if (resp != AXI_LITE_OKAY) `uvm_error("ENUM", "multi-field write of CTRL failed")

  field_check("CTRL", "ENABLE", 1'b1);
  field_check("CTRL", "MODE", CSR_CTRL_MODE_STREAM);
  field_check("CTRL", "GAIN", 8'hFF);
  field_check("CTRL", "THRESH", 12'hABC);

  // The DUT's own outputs agree, which is what proves the masks and
  // shifts were right rather than merely self-consistent.
  if (hw_vif.ctrl_enable !== 1'b1) `uvm_error("ENUM", "CTRL.ENABLE did not reach the DUT output")
  if (hw_vif.ctrl_gain !== 8'hFF) `uvm_error("ENUM", "CTRL.GAIN did not reach the DUT output")
  if (hw_vif.ctrl_thresh !== 12'hABC)
    `uvm_error("ENUM", "CTRL.THRESH did not reach the DUT output")

  // A status register the hardware owns, read by name and reported by
  // the name of the value rather than the number.
  hw_vif.set_status(1'b1, 4'h2);
  field_check("STATUS", "BUSY", 1'b1);
  field_read_enum("STATUS", "ERRCODE", mode_name, resp);
  if (mode_name != "UNDERFLOW")
    `uvm_error("ENUM", $sformatf("STATUS.ERRCODE read back as '%s', expected 'UNDERFLOW'",
                                 mode_name))
endtask : body
