///////////////////////////////////////////////////////////////////
// Filename: example_tb_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Testbench package for the integration example. Declares the
//           port's widths and the register map once, and names the two
//           parameterized types that depend on those widths, so no other
//           file has to repeat them.
///////////////////////////////////////////////////////////////////

package example_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // The UVC. This import plus axi_lite_if.sv is all a project needs.
  import axi_lite_pkg::*;

  // ---------------------------------------------------------------------
  // Your port's geometry, written down once.
  //
  // AXI4-Lite fixes the data bus at 32 or 64 bits and every access at the
  // full bus width, so the only width that really varies from design to
  // design is the address -- and it only needs to be as wide as the
  // aperture the slave decodes. 12 bits is a 4 KB window, which is what
  // a peripheral usually gets.
  // ---------------------------------------------------------------------
  parameter int EX_ADDR_WIDTH = 12;
  parameter int EX_DATA_WIDTH = 32;

  // ---------------------------------------------------------------------
  // The DUT's register map, also written down once. The scoreboard models
  // it and the tests address it, so it has to be stated somewhere both
  // can see.
  // ---------------------------------------------------------------------
  parameter int             EX_NUM_REGS = 16;
  parameter axi_lite_addr_t EX_ID_ADDR  = 64'h0000;                     // read-only
  parameter axi_lite_addr_t EX_REG_LO   = 64'h0004;                     // first scratch register
  parameter axi_lite_addr_t EX_REG_HI   = 64'h003C;                     // last scratch register
  parameter axi_lite_addr_t EX_MAP_HI   = 64'h003F;                     // last decoded byte
  parameter axi_lite_data_t EX_ID_VALUE = 64'hA711_0001;

  // ---------------------------------------------------------------------
  // Names for the two parameterized types that carry those widths.
  //
  // This is the single most useful habit when integrating the UVC.
  // `virtual axi_lite_if #(12,32)` and `#(32,32)` are different
  // SystemVerilog types, so a config-DB set() and get() that disagree by
  // one parameter fail silently -- the agent just reports NOVIF. Writing
  // the widths once and using these names everywhere makes that
  // impossible rather than merely unlikely.
  // ---------------------------------------------------------------------
  typedef virtual axi_lite_if #(EX_ADDR_WIDTH, EX_DATA_WIDTH) example_vif_t;
  typedef axi_lite_agent      #(EX_ADDR_WIDTH, EX_DATA_WIDTH) example_agent_t;

  `include "example_scoreboard.sv"
  `include "example_env.sv"
  `include "example_base_test.sv"

endpackage : example_tb_pkg
