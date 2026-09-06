///////////////////////////////////////////////////////////////////
// Filename: axi_lite_tb_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Local package for the AXI4-Lite UVC's self-test:
//           scoreboard, per-link environment, and the test library.
///////////////////////////////////////////////////////////////////
//
// Kept separate from axi_lite_pkg (the reusable UVC) on purpose:
// axi_lite_uvc.f pulls in only the UVC, so a project reusing it never
// compiles this file, the register slice, or these tests.

package axi_lite_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;

  `include "axi_lite_scoreboard.sv"
  `include "axi_lite_env.sv"
  `include "axi_lite_test_lib.sv"

endpackage : axi_lite_tb_pkg
