///////////////////////////////////////////////////////////////////
// Filename: axi_lite_corsair.svh
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Build an axi_lite_reg_model out of the parameters in a
//           Corsair SystemVerilogPackage export, without retyping a
//           single address, offset or mask.
///////////////////////////////////////////////////////////////////
//
// When to use this, and when not to
// ---------------------------------
// There are two ways to get a Corsair map into the UVC, and this is the
// second one. Prefer tools/corsair_uvc_gen.py: it reads the register map
// itself, so it carries the per-field access modes and enumerated values
// and needs no maintenance when the map changes.
//
// Use these macros when you would rather consume Corsair's exported
// SystemVerilog package -- because it is already in your filelist, or
// because your flow cannot run an extra script. Every number then comes
// from that package, so nothing is retyped and nothing can go stale: a
// field that is renamed or moved becomes a compile error at the macro,
// not a wrong address at runtime.
//
// The one thing the package does not carry is the access mode. Corsair's
// SystemVerilogPackage generator exports WIDTH, LSB, MASK and RESET but
// not `access`, so you state it at the macro. That is the cost of this
// path, and it is why the generator is the recommended one.
//
// Usage
// -----
//   import axi_lite_pkg::*;
//   import corsair_example_regs_pkg::*;   // Corsair's own export
//   `include "axi_lite_corsair.svh"
//
//   function void build_my_map(axi_lite_reg_model m);
//     `AXI_LITE_CORSAIR_MAP(m, "my_periph", CSR)
//
//     `AXI_LITE_CORSAIR_REG(m, CSR, ID)
//       `AXI_LITE_CORSAIR_FIELD(m, CSR, ID, MAGIC,   AXI_LITE_ACCESS_RO)
//       `AXI_LITE_CORSAIR_FIELD(m, CSR, ID, VERSION, AXI_LITE_ACCESS_RO)
//
//     `AXI_LITE_CORSAIR_REG(m, CSR, CTRL)
//       `AXI_LITE_CORSAIR_FIELD(m, CSR, CTRL, ENABLE, AXI_LITE_ACCESS_RW)
//       `AXI_LITE_CORSAIR_FIELD(m, CSR, CTRL, GAIN,   AXI_LITE_ACCESS_RW)
//   endfunction
//
// `AXI_LITE_CORSAIR_MAP` takes the base address and data width from the
// package's own CSR_BASE_ADDR and CSR_DATA_WIDTH, so those are not
// restated either.
//
// A note on the enumerated values: Corsair *does* export those, as a
// typedef'd enum (CSR_CTRL_MODE_STREAM and so on). They are already
// usable without being registered into the model --
//
//   field_write("CTRL", "MODE", CSR_CTRL_MODE_STREAM, resp);
//
// -- which is type-checked by the compiler, so it is a better way to name
// a value than a string would be. Register them with
// `AXI_LITE_CORSAIR_ENUM` only if you want the model to print names in
// its own check failures.

`ifndef AXI_LITE_CORSAIR_SVH
`define AXI_LITE_CORSAIR_SVH

// Configure the model from the package's global parameters.
// PREFIX is the `prefix` given to Corsair's SystemVerilogPackage
// generator -- "CSR" unless you changed it.
`define AXI_LITE_CORSAIR_MAP(MODEL, MAP_NAME, PREFIX) \
  MODEL.configure(.map_name(MAP_NAME), \
                  .base_address(PREFIX``_BASE_ADDR), \
                  .data_width(PREFIX``_DATA_WIDTH));

// One register. REG is its name exactly as it appears in the map, which
// is also how it appears in the parameter names.
`define AXI_LITE_CORSAIR_REG(MODEL, PREFIX, REG) \
  void'(MODEL.create_reg(`"REG`", PREFIX``_``REG``_ADDR));

// One field. ACCESS is one of the axi_lite_access_e values and is the
// only thing here not taken from the package.
`define AXI_LITE_CORSAIR_FIELD(MODEL, PREFIX, REG, FIELD, ACCESS) \
  void'(MODEL.create_field(`"REG`", `"FIELD`", \
                           PREFIX``_``REG``_``FIELD``_LSB, \
                           PREFIX``_``REG``_``FIELD``_WIDTH, \
                           ACCESS, \
                           PREFIX``_``REG``_``FIELD``_RESET));

// Same, but keeps the handle so enumerated values can be hung off it.
// HANDLE must be an axi_lite_field variable already declared.
`define AXI_LITE_CORSAIR_FIELD_H(HANDLE, MODEL, PREFIX, REG, FIELD, ACCESS) \
  HANDLE = MODEL.create_field(`"REG`", `"FIELD`", \
                              PREFIX``_``REG``_``FIELD``_LSB, \
                              PREFIX``_``REG``_``FIELD``_WIDTH, \
                              ACCESS, \
                              PREFIX``_``REG``_``FIELD``_RESET);

// One enumerated value, by the name Corsair gave the constant.
`define AXI_LITE_CORSAIR_ENUM(HANDLE, PREFIX, REG, FIELD, ENUM) \
  HANDLE.add_enum(`"ENUM`", PREFIX``_``REG``_``FIELD``_``ENUM);

`endif  // AXI_LITE_CORSAIR_SVH
