///////////////////////////////////////////////////////////////////
// Filename: corsair_example_macro_model.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : The same register map again, built the other way: from
//           exported SystemVerilog parameters, through the macros in
//           src/axi_lite_corsair.svh.
///////////////////////////////////////////////////////////////////
//
// This exists to keep the second integration path honest. The generated
// model (corsair_example_reg_pkg.sv) is the recommended one and is what
// every other test here uses; this one shows what the macro path costs
// and proves it produces the same map.
//
// What it costs is visible below: the access mode is stated at every
// field, because Corsair's SystemVerilogPackage export carries WIDTH,
// LSB, MASK and RESET but not `access`. Everything else -- every
// address, offset, width and reset value -- comes from the parameters,
// so nothing here can go stale when the map changes. Rename a field and
// this file stops compiling, which is the point.
//
// corsair_example_macro_test compares the two models field by field.

`include "axi_lite_corsair.svh"

class corsair_example_macro_model extends axi_lite_reg_model;

  `uvm_object_utils(corsair_example_macro_model)

  function new(string name = "corsair_example_macro_model");
    super.new(name);
    build_map();
  endfunction : new

  virtual function void build_map();
    axi_lite_field f;

    `AXI_LITE_CORSAIR_MAP(this, "corsair_example_macro", CSR)

    `AXI_LITE_CORSAIR_REG(this, CSR, ID)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, ID, VERSION, AXI_LITE_ACCESS_RO)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, ID, MAGIC, AXI_LITE_ACCESS_RO)

    `AXI_LITE_CORSAIR_REG(this, CSR, CTRL)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CTRL, ENABLE, AXI_LITE_ACCESS_RW)
    // Keeping the handle lets the enumerated values be registered too,
    // so the model can print names in its own check failures.
    `AXI_LITE_CORSAIR_FIELD_H(f, this, CSR, CTRL, MODE, AXI_LITE_ACCESS_RW)
    `AXI_LITE_CORSAIR_ENUM(f, CSR, CTRL, MODE, IDLE)
    `AXI_LITE_CORSAIR_ENUM(f, CSR, CTRL, MODE, STREAM)
    `AXI_LITE_CORSAIR_ENUM(f, CSR, CTRL, MODE, SINGLE)
    `AXI_LITE_CORSAIR_ENUM(f, CSR, CTRL, MODE, LOOPBACK)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CTRL, GAIN, AXI_LITE_ACCESS_RW)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CTRL, THRESH, AXI_LITE_ACCESS_RW)

    `AXI_LITE_CORSAIR_REG(this, CSR, STATUS)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, STATUS, BUSY, AXI_LITE_ACCESS_RO)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, STATUS, ERRCODE, AXI_LITE_ACCESS_RO)

    `AXI_LITE_CORSAIR_REG(this, CSR, IRQ)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, IRQ, DONE, AXI_LITE_ACCESS_RW1C)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, IRQ, ERROR, AXI_LITE_ACCESS_RW1C)

    `AXI_LITE_CORSAIR_REG(this, CSR, CMD)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CMD, OPCODE, AXI_LITE_ACCESS_WO)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CMD, ARG, AXI_LITE_ACCESS_WO)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CMD, FLAG, AXI_LITE_ACCESS_WO)

    `AXI_LITE_CORSAIR_REG(this, CSR, SCRATCH)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, SCRATCH, VALUE, AXI_LITE_ACCESS_RW)

    `AXI_LITE_CORSAIR_REG(this, CSR, EVENT)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, EVENT, COUNT, AXI_LITE_ACCESS_ROC)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, EVENT, ARM, AXI_LITE_ACCESS_RW)
  endfunction : build_map

endclass : corsair_example_macro_model
