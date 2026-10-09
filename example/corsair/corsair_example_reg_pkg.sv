///////////////////////////////////////////////////////////////////
// GENERATED FILE -- DO NOT EDIT.
//
// Produced by tools/corsair_uvc_gen.py from:
//   register map : regs.json
//   Corsair cfg  : csrconfig
//
// Regenerate it whenever the register map changes -- the map is the
// source of truth and anything edited here is lost on the next run.
//
// 7 register(s), 16 field(s).
///////////////////////////////////////////////////////////////////

package corsair_example_reg_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;

  // ---- Map constants. Same names as Corsair's
  // SystemVerilogPackage export, so this package can be used in
  // place of it.
  localparam int CSR_BASE_ADDR  = 0;
  localparam int CSR_DATA_WIDTH = 32;
  localparam int CSR_ADDR_WIDTH = 12;

  // ID
  localparam int CSR_ID_ADDR = 0;
  localparam logic [31:0] CSR_ID_RESET = 32'hA7110001;
  localparam int CSR_ID_MAGIC_WIDTH = 16;
  localparam int CSR_ID_MAGIC_LSB = 16;
  localparam logic [31:0] CSR_ID_MAGIC_MASK = 32'hFFFF0000;
  localparam logic [15:0] CSR_ID_MAGIC_RESET = 16'hA711;
  localparam int CSR_ID_VERSION_WIDTH = 16;
  localparam int CSR_ID_VERSION_LSB = 0;
  localparam logic [31:0] CSR_ID_VERSION_MASK = 32'hFFFF;
  localparam logic [15:0] CSR_ID_VERSION_RESET = 16'h1;

  // CTRL
  localparam int CSR_CTRL_ADDR = 4;
  localparam logic [31:0] CSR_CTRL_RESET = 32'h8000;
  localparam int CSR_CTRL_ENABLE_WIDTH = 1;
  localparam int CSR_CTRL_ENABLE_LSB = 0;
  localparam logic [31:0] CSR_CTRL_ENABLE_MASK = 32'h1;
  localparam logic [0:0] CSR_CTRL_ENABLE_RESET = 1'h0;
  localparam int CSR_CTRL_MODE_WIDTH = 2;
  localparam int CSR_CTRL_MODE_LSB = 1;
  localparam logic [31:0] CSR_CTRL_MODE_MASK = 32'h6;
  localparam logic [1:0] CSR_CTRL_MODE_RESET = 2'h0;
  localparam logic [1:0] CSR_CTRL_MODE_IDLE = 2'h0;
  localparam logic [1:0] CSR_CTRL_MODE_STREAM = 2'h1;
  localparam logic [1:0] CSR_CTRL_MODE_SINGLE = 2'h2;
  localparam logic [1:0] CSR_CTRL_MODE_LOOPBACK = 2'h3;
  localparam int CSR_CTRL_GAIN_WIDTH = 8;
  localparam int CSR_CTRL_GAIN_LSB = 8;
  localparam logic [31:0] CSR_CTRL_GAIN_MASK = 32'hFF00;
  localparam logic [7:0] CSR_CTRL_GAIN_RESET = 8'h80;
  localparam int CSR_CTRL_THRESH_WIDTH = 12;
  localparam int CSR_CTRL_THRESH_LSB = 16;
  localparam logic [31:0] CSR_CTRL_THRESH_MASK = 32'hFFF0000;
  localparam logic [11:0] CSR_CTRL_THRESH_RESET = 12'h0;

  // STATUS
  localparam int CSR_STATUS_ADDR = 8;
  localparam logic [31:0] CSR_STATUS_RESET = 32'h0;
  localparam int CSR_STATUS_BUSY_WIDTH = 1;
  localparam int CSR_STATUS_BUSY_LSB = 0;
  localparam logic [31:0] CSR_STATUS_BUSY_MASK = 32'h1;
  localparam logic [0:0] CSR_STATUS_BUSY_RESET = 1'h0;
  localparam int CSR_STATUS_ERRCODE_WIDTH = 4;
  localparam int CSR_STATUS_ERRCODE_LSB = 4;
  localparam logic [31:0] CSR_STATUS_ERRCODE_MASK = 32'hF0;
  localparam logic [3:0] CSR_STATUS_ERRCODE_RESET = 4'h0;
  localparam logic [3:0] CSR_STATUS_ERRCODE_NONE = 4'h0;
  localparam logic [3:0] CSR_STATUS_ERRCODE_OVERFLOW = 4'h1;
  localparam logic [3:0] CSR_STATUS_ERRCODE_UNDERFLOW = 4'h2;

  // IRQ
  localparam int CSR_IRQ_ADDR = 12;
  localparam logic [31:0] CSR_IRQ_RESET = 32'h0;
  localparam int CSR_IRQ_DONE_WIDTH = 1;
  localparam int CSR_IRQ_DONE_LSB = 0;
  localparam logic [31:0] CSR_IRQ_DONE_MASK = 32'h1;
  localparam logic [0:0] CSR_IRQ_DONE_RESET = 1'h0;
  localparam int CSR_IRQ_ERROR_WIDTH = 1;
  localparam int CSR_IRQ_ERROR_LSB = 1;
  localparam logic [31:0] CSR_IRQ_ERROR_MASK = 32'h2;
  localparam logic [0:0] CSR_IRQ_ERROR_RESET = 1'h0;

  // CMD
  localparam int CSR_CMD_ADDR = 16;
  localparam logic [31:0] CSR_CMD_RESET = 32'h0;
  localparam int CSR_CMD_OPCODE_WIDTH = 8;
  localparam int CSR_CMD_OPCODE_LSB = 0;
  localparam logic [31:0] CSR_CMD_OPCODE_MASK = 32'hFF;
  localparam logic [7:0] CSR_CMD_OPCODE_RESET = 8'h0;
  localparam int CSR_CMD_ARG_WIDTH = 16;
  localparam int CSR_CMD_ARG_LSB = 8;
  localparam logic [31:0] CSR_CMD_ARG_MASK = 32'hFFFF00;
  localparam logic [15:0] CSR_CMD_ARG_RESET = 16'h0;
  localparam int CSR_CMD_FLAG_WIDTH = 1;
  localparam int CSR_CMD_FLAG_LSB = 24;
  localparam logic [31:0] CSR_CMD_FLAG_MASK = 32'h1000000;
  localparam logic [0:0] CSR_CMD_FLAG_RESET = 1'h0;

  // SCRATCH
  localparam int CSR_SCRATCH_ADDR = 20;
  localparam logic [31:0] CSR_SCRATCH_RESET = 32'h0;
  localparam int CSR_SCRATCH_VALUE_WIDTH = 32;
  localparam int CSR_SCRATCH_VALUE_LSB = 0;
  localparam logic [31:0] CSR_SCRATCH_VALUE_MASK = 32'hFFFFFFFF;
  localparam logic [31:0] CSR_SCRATCH_VALUE_RESET = 32'h0;

  // EVENT
  localparam int CSR_EVENT_ADDR = 24;
  localparam logic [31:0] CSR_EVENT_RESET = 32'h0;
  localparam int CSR_EVENT_COUNT_WIDTH = 8;
  localparam int CSR_EVENT_COUNT_LSB = 0;
  localparam logic [31:0] CSR_EVENT_COUNT_MASK = 32'hFF;
  localparam logic [7:0] CSR_EVENT_COUNT_RESET = 8'h0;
  localparam int CSR_EVENT_ARM_WIDTH = 1;
  localparam int CSR_EVENT_ARM_LSB = 16;
  localparam logic [31:0] CSR_EVENT_ARM_MASK = 32'h10000;
  localparam logic [0:0] CSR_EVENT_ARM_RESET = 1'h0;

  class corsair_example_reg_model extends axi_lite_reg_model;

    `uvm_object_utils(corsair_example_reg_model)

    function new(string name = "corsair_example_reg_model");
      super.new(name);
      configure(.map_name("corsair_example"), .base_address(64'h0), .data_width(32));
      build_map();
    endfunction : new

    // One call per register and per field, in map order.
    virtual function void build_map();

      // ---- ID @ 0x0 ----
      // Identification. Constant, so a correct read proves the AXI4-Lite
      // path reaches this block.
      void'(create_reg("ID", 64'h0, "Identification. Constant, so a correct read proves the AXI4-Lite path reaches this block."));
      void'(create_field("ID", "MAGIC", 16, 16, AXI_LITE_ACCESS_RO, 64'hA711, "Always 0xA711."));
      void'(create_field("ID", "VERSION", 0, 16, AXI_LITE_ACCESS_RO, 64'h1, "Map version."));

      // ---- CTRL @ 0x4 ----
      // Main control. Deliberately mixes a byte-aligned field, an
      // unaligned field and an enumerated field, so every field-write
      // strategy the UVC can pick is exercised by one register.
      void'(create_reg("CTRL", 64'h4, "Main control. Deliberately mixes a byte-aligned field, an unaligned field and an enumerated field, so every field-write strategy the UVC can pick is exercise..."));
      void'(create_field("CTRL", "ENABLE", 0, 1, AXI_LITE_ACCESS_RW, 64'h0, "Enable the block."));
      begin : ctrl_mode
        axi_lite_field f = create_field("CTRL", "MODE", 1, 2, AXI_LITE_ACCESS_RW, 64'h0, "Operating mode.");
        f.add_enum("IDLE", 64'h0, "Do nothing.");
        f.add_enum("STREAM", 64'h1, "Continuous streaming.");
        f.add_enum("SINGLE", 64'h2, "One frame then stop.");
        f.add_enum("LOOPBACK", 64'h3, "Echo input to output.");
      end : ctrl_mode
      void'(create_field("CTRL", "GAIN", 8, 8, AXI_LITE_ACCESS_RW, 64'h80, "Byte-aligned on purpose: a write to this field alone needs no read."));
      void'(create_field("CTRL", "THRESH", 16, 12, AXI_LITE_ACCESS_RW, 64'h0, "Straddles byte lane 2 and 3, so a write to this field alone needs a read-modify-write."));

      // ---- STATUS @ 0x8 ----
      // Read-only status driven by hardware.
      void'(create_reg("STATUS", 64'h8, "Read-only status driven by hardware."));
      void'(create_field("STATUS", "BUSY", 0, 1, AXI_LITE_ACCESS_RO, 64'h0, "Block is busy."));
      begin : status_errcode
        axi_lite_field f = create_field("STATUS", "ERRCODE", 4, 4, AXI_LITE_ACCESS_RO, 64'h0, "Last error.");
        f.add_enum("NONE", 64'h0, "No error.");
        f.add_enum("OVERFLOW", 64'h1, "Input overflowed.");
        f.add_enum("UNDERFLOW", 64'h2, "Input underflowed.");
      end : status_errcode

      // ---- IRQ @ 0xC ----
      // Write-1-to-clear interrupt flags. A read-modify-write here would
      // clear flags nobody asked to clear, which is the hazard the UVC's
      // field_write() avoids.
      void'(create_reg("IRQ", 64'hC, "Write-1-to-clear interrupt flags. A read-modify-write here would clear flags nobody asked to clear, which is the hazard the UVC's field_write() avoids."));
      void'(create_field("IRQ", "DONE", 0, 1, AXI_LITE_ACCESS_RW1C, 64'h0, "Operation completed."));
      void'(create_field("IRQ", "ERROR", 1, 1, AXI_LITE_ACCESS_RW1C, 64'h0, "Error occurred."));

      // ---- CMD @ 0x10 ----
      // Write-only command. Cannot be read back, so a field write here
      // cannot read-modify-write and must use the shadow value.
      void'(create_reg("CMD", 64'h10, "Write-only command. Cannot be read back, so a field write here cannot read-modify-write and must use the shadow value."));
      void'(create_field("CMD", "OPCODE", 0, 8, AXI_LITE_ACCESS_WO, 64'h0, "Command opcode."));
      void'(create_field("CMD", "ARG", 8, 16, AXI_LITE_ACCESS_WO, 64'h0, "Command argument."));
      void'(create_field("CMD", "FLAG", 24, 1, AXI_LITE_ACCESS_WO, 64'h0, "Single bit at the top of the word. Write-only and not byte-aligned, so writing it alone can only be done from the shadow value."));

      // ---- SCRATCH @ 0x14 ----
      // Plain read/write word, for a whole-register access that needs no
      // field handling at all.
      void'(create_reg("SCRATCH", 64'h14, "Plain read/write word, for a whole-register access that needs no field handling at all."));
      void'(create_field("SCRATCH", "VALUE", 0, 32, AXI_LITE_ACCESS_RW, 64'h0, "Anything you like."));

      // ---- EVENT @ 0x18 ----
      // Event counter that clears when read. Reading it to service one
      // field is destructive, so the UVC will not read-modify-write this
      // register.
      void'(create_reg("EVENT", 64'h18, "Event counter that clears when read. Reading it to service one field is destructive, so the UVC will not read-modify-write this register."));
      void'(create_field("EVENT", "COUNT", 0, 8, AXI_LITE_ACCESS_ROC, 64'h0, "Events since the last read. Cleared by the read itself."));
      void'(create_field("EVENT", "ARM", 16, 1, AXI_LITE_ACCESS_RW, 64'h0, "Plain control bit sharing the register with a read-clear field."));
    endfunction : build_map

  endclass : corsair_example_reg_model

endpackage : corsair_example_reg_pkg
