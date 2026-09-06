///////////////////////////////////////////////////////////////////
// Filename: example_tb_top.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Worked example of hooking the AXI4-Lite UVC up to a DUT.
//           Read this file and example_base_test.sv together and you
//           have everything needed to drop the UVC into your own
//           testbench.
///////////////////////////////////////////////////////////////////
//
// ============================================================
//  WHAT THIS FILE HAS TO DO
// ============================================================
// A UVM component cannot reach into the design hierarchy on its own, so
// the top module has exactly three jobs:
//
//   1. instantiate one axi_lite_if per AXI4-Lite port of the DUT
//   2. wire that interface to the DUT
//   3. publish it to the config DB so the agent can find it
//
// Everything else -- role, backpressure, stimulus -- is in the test.
//
// The DUT here is a peripheral, so it has one slave port and there is
// one interface and one agent. A DUT that also has a *master* port needs
// a second interface and a second agent, configured with
// `role = AXI_LITE_SLAVE`; tb/axi_lite_link.sv shows that wiring.
//
// ============================================================
//  THE ONE THING THAT CATCHES PEOPLE OUT
// ============================================================
// `virtual axi_lite_if #(12,32)` and `virtual axi_lite_if #(32,32)` are
// *different SystemVerilog types*. The type you set into the config DB
// must match the type the agent gets out of it, parameter for parameter,
// or the get() silently fails and the agent issues a NOVIF fatal.
//
// The fix is not to be careful -- it is to write the widths down once.
// example_tb_pkg.sv declares them as parameters and gives the two
// parameterized types names (example_vif_t, example_agent_t), and every
// other file uses those names. Do the same in your testbench and the
// mismatch cannot happen.

`timescale 1ns/1ps

module example_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // The UVC package. This plus axi_lite_if.sv is the entire component;
  // see src/axi_lite_uvc.f for the filelist that pulls both in.
  import axi_lite_pkg::*;

  // Your own testbench package: port widths, register map, env,
  // scoreboard, tests.
  import example_tb_pkg::*;

  // ---------------------------------------------------------------------
  // STEP 1 -- clock and reset.
  //
  // Ordinary testbench plumbing; the UVC does not care how they are
  // generated. Reset is released on a falling edge on purpose: keeping
  // it away from the rising edge makes the reset-release rule the UVC
  // asserts ("every VALID must be low on the first ACLK edge after
  // ARESETn goes high") unambiguous.
  // ---------------------------------------------------------------------
  logic aclk;
  logic aresetn;

  initial aclk = 1'b0;
  always #(5ns) aclk = ~aclk;          // 100 MHz

  initial begin
    aresetn = 1'b0;
    repeat (5) @(negedge aclk);
    aresetn = 1'b1;
  end

  // ---------------------------------------------------------------------
  // STEP 2 -- one interface per AXI4-Lite port of the DUT.
  //
  // The widths come from example_tb_pkg so they are stated once. Note
  // that this is the same axi_lite_if.sv you would instantiate inside
  // the design itself: everything the UVC needs from it is behind
  // `ifdef AXI_LITE_IF_SIM, so there is no separate "verification
  // interface" to keep in step with a synthesizable one.
  // ---------------------------------------------------------------------
  axi_lite_if #(EX_ADDR_WIDTH, EX_DATA_WIDTH) axil (.aclk(aclk), .aresetn(aresetn));

  // ---------------------------------------------------------------------
  // STEP 3 -- wire the DUT to the interface.
  //
  // Signal by signal, which works with any DUT whatever its port names.
  // If your DUT is written against the interface instead, the
  // synthesizable modport does the same job in one line:
  //
  //     example_dut u_dut (.aclk, .aresetn, .s_axil(axil.dut_slave));
  //
  // Either way, note who drives what: the UVC drives AW, W, AR and the
  // two response READYs; the DUT drives the three request READYs and the
  // B and R channels. Every signal ends up with exactly one driver,
  // which is why one interface type serves both ends of a link.
  // ---------------------------------------------------------------------
  example_dut #(
    .ADDR_WIDTH (EX_ADDR_WIDTH),
    .DATA_WIDTH (EX_DATA_WIDTH),
    .NUM_REGS   (EX_NUM_REGS)
  ) u_dut (
    .aclk           (aclk),
    .aresetn        (aresetn),

    .s_axil_awvalid (axil.awvalid),
    .s_axil_awready (axil.awready),
    .s_axil_awaddr  (axil.awaddr),
    .s_axil_awprot  (axil.awprot),

    .s_axil_wvalid  (axil.wvalid),
    .s_axil_wready  (axil.wready),
    .s_axil_wdata   (axil.wdata),
    .s_axil_wstrb   (axil.wstrb),

    .s_axil_bvalid  (axil.bvalid),
    .s_axil_bready  (axil.bready),
    .s_axil_bresp   (axil.bresp),

    .s_axil_arvalid (axil.arvalid),
    .s_axil_arready (axil.arready),
    .s_axil_araddr  (axil.araddr),
    .s_axil_arprot  (axil.arprot),

    .s_axil_rvalid  (axil.rvalid),
    .s_axil_rready  (axil.rready),
    .s_axil_rdata   (axil.rdata),
    .s_axil_rresp   (axil.rresp)
  );

  // ---------------------------------------------------------------------
  // STEP 4 -- hand the interface to the testbench.
  //
  // example_vif_t is the typedef from example_tb_pkg; using it here and
  // in the env guarantees the set and the get agree. The scope "*" makes
  // it visible everywhere, and the field name ("vif") is what the env
  // asks for -- see example_env.sv, STEP 1.
  //
  // With more than one port, give each its own field name, or narrow the
  // scope to the env instance that should receive it.
  // ---------------------------------------------------------------------
  initial begin
    uvm_config_db#(example_vif_t)::set(null, "*", "vif", axil);

    // STEP 5 -- start UVM. Override on the command line with
    // +UVM_TESTNAME=<test>; the Makefile's TEST= does exactly that.
    run_test("example_base_test");
  end

  // ---------------------------------------------------------------------
  // Pass/fail banner. Not part of UVC integration, but worth copying:
  // XSIM exits 0 even after a UVM_FATAL (the test called $finish, it did
  // not crash), so a script that only checks the exit status will call a
  // failing test a pass. The Makefile greps for this line instead.
  // ---------------------------------------------------------------------
  final begin
    uvm_report_server svr;
    int n_fatals, n_errors, n_warnings;
    string test_name;
    svr        = uvm_report_server::get_server();
    n_fatals   = svr.get_severity_count(UVM_FATAL);
    n_errors   = svr.get_severity_count(UVM_ERROR);
    n_warnings = svr.get_severity_count(UVM_WARNING);
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name)) test_name = "example_base_test";
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: example_dut  |  top: example_tb_top");
    $display(" test    : %s", test_name);
    $display(" result  : %s", ((n_fatals == 0) && (n_errors == 0)) ? "PASSED" : "FAILED");
    $display(" fatals=%0d errors=%0d warnings=%0d", n_fatals, n_errors, n_warnings);
    $display("============================================================");
  end

endmodule : example_tb_top
