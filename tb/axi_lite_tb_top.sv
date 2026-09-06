///////////////////////////////////////////////////////////////////
// Filename: axi_lite_tb_top.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Top level of the AXI4-Lite UVC self-test. Instantiates five
//           differently parameterized links side by side under one clock
//           and one reset, and starts the UVM test that drives all of
//           them at once.
///////////////////////////////////////////////////////////////////
//
// The five instantiations below are the whole answer to "does the UVC
// handle the AXI4-Lite parameter combinations that occur in practice?".
// They are module parameters, not `defines, so all five elaborate into a
// single snapshot and one simulation exercises the lot -- rather than
// five recompiles of the same testbench with a different macro each time.
//
// Each ENV_NAME matches an env instance name in axi_lite_base_test; that
// string is the config-DB scope the link's interfaces are published to,
// and is the only coupling between this file and the test.

`timescale 1ns/1ps

module axi_lite_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_lite_pkg::*;
  import axi_lite_tb_pkg::*;

  // 100 MHz free-running clock.
  logic aclk;
  initial aclk = 1'b0;
  always #(5ns) aclk = ~aclk;

  // Sole owner of ARESETn for every link.
  axi_lite_tb_ctrl_if #(.RESET_CYCLES(5)) ctrl (.aclk(aclk));

  // ---------------------------------------------------------------------
  //  name         ADDR  DATA   notes
  //  ----------   ----  ----   -------------------------------------------
  //  env_a32d32    32    32    the common case
  //  env_a32d64    32    64    the other data width AXI4-Lite allows
  //  env_a64d64    64    64    full 64-bit addressing
  //  env_a12d32    12    32    a peripheral's own 4 KB aperture
  //  env_a16d64    16    64    a 64 KB window on a wide bus
  //
  // AXI4-Lite fixes the data bus at 32 or 64 bits, so the width that
  // actually varies from design to design is the address -- which is why
  // three of the five differ only there.
  // ---------------------------------------------------------------------
  axi_lite_link #(.ENV_NAME("env_a32d32"), .ADDR_WIDTH(32), .DATA_WIDTH(32),
                  .DEPTH(4)) u_link_a32d32 (aclk, ctrl.aresetn);

  axi_lite_link #(.ENV_NAME("env_a32d64"), .ADDR_WIDTH(32), .DATA_WIDTH(64),
                  .DEPTH(4)) u_link_a32d64 (aclk, ctrl.aresetn);

  axi_lite_link #(.ENV_NAME("env_a64d64"), .ADDR_WIDTH(64), .DATA_WIDTH(64),
                  .DEPTH(8)) u_link_a64d64 (aclk, ctrl.aresetn);

  axi_lite_link #(.ENV_NAME("env_a12d32"), .ADDR_WIDTH(12), .DATA_WIDTH(32),
                  .DEPTH(2)) u_link_a12d32 (aclk, ctrl.aresetn);

  axi_lite_link #(.ENV_NAME("env_a16d64"), .ADDR_WIDTH(16), .DATA_WIDTH(64),
                  .DEPTH(8)) u_link_a16d64 (aclk, ctrl.aresetn);

  initial begin
    uvm_config_db#(virtual axi_lite_tb_ctrl_if)::set(null, "*", "ctrl", ctrl);
    run_test("axi_lite_multiwidth_test");
  end

  // ---------------------------------------------------------------------
  // Pass/fail banner, printed once at the end of simulation. XSIM exits 0
  // even after a UVM_FATAL, so the Makefile greps this instead.
  // ---------------------------------------------------------------------
  function automatic void print_summary(
      bit pass, int n_fatals, int n_errors, int n_warnings, string test_name
  );
    string status = pass ? "PASSED" : "FAILED";
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: axi_lite  |  top: axi_lite_tb_top");
    $display(" test    : %s", test_name);
    $display(" result  : %s", status);
    $display(" fatals=%0d errors=%0d warnings=%0d", n_fatals, n_errors, n_warnings);
    $display("============================================================");
  endfunction

  final begin
    uvm_report_server svr;
    int n_fatals, n_errors, n_warnings;
    string test_name;
    svr        = uvm_report_server::get_server();
    n_fatals   = svr.get_severity_count(UVM_FATAL);
    n_errors   = svr.get_severity_count(UVM_ERROR);
    n_warnings = svr.get_severity_count(UVM_WARNING);
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name)) test_name = "axi_lite_multiwidth_test";
    print_summary((n_fatals == 0) && (n_errors == 0), n_fatals, n_errors, n_warnings, test_name);
  end

endmodule : axi_lite_tb_top
