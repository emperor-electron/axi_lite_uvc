///////////////////////////////////////////////////////////////////
// Filename: corsair_example_tb_top.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Top module for the Corsair integration example. The DUT is
//           a register block Corsair generated from the same regs.json
//           the UVC's register model was generated from.
///////////////////////////////////////////////////////////////////
//
// Everything here comes out of one file. `make regs` runs Corsair to
// produce the RTL, its SystemVerilog package and the markdown
// documentation, then runs tools/corsair_uvc_gen.py to produce the UVC's
// register model. The DUT and the testbench's idea of the DUT therefore
// cannot drift apart: a register moved in regs.json moves in both.
//
// Note what the top module does NOT have to do: nothing here mentions a
// register address. The UVC learns the map from the generated model and
// the DUT decodes it from the generated RTL.

`timescale 1ns / 1ps

module corsair_example_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import axi_lite_pkg::*;
  import corsair_example_tb_pkg::*;

  // ---- Clock and reset -------------------------------------------------
  logic aclk;
  logic aresetn;

  initial aclk = 1'b0;
  always #(5ns) aclk = ~aclk;  // 100 MHz

  initial begin
    aresetn = 1'b0;
    repeat (5) @(negedge aclk);
    aresetn = 1'b1;
  end

  // ---- The AXI4-Lite port, and the hardware side of the block ---------
  axi_lite_if #(EX_ADDR_WIDTH, EX_DATA_WIDTH) axil (
      .aclk(aclk),
      .aresetn(aresetn)
  );

  corsair_example_hw_if hw (
      .aclk(aclk),
      .aresetn(aresetn)
  );

  // ---- The DUT ---------------------------------------------------------
  // Corsair's generated block. Its reset is active low, so ARESETn wires
  // straight to it.
  corsair_example_regs #(
      .ADDR_W(EX_ADDR_WIDTH),
      .DATA_W(EX_DATA_WIDTH)
  ) u_dut (
      .clk(aclk),
      .rst(aresetn),

      // Hardware side, by field.
      .csr_ctrl_enable_out(hw.ctrl_enable),
      .csr_ctrl_mode_out(hw.ctrl_mode),
      .csr_ctrl_gain_out(hw.ctrl_gain),
      .csr_ctrl_thresh_out(hw.ctrl_thresh),
      .csr_status_busy_in(hw.status_busy),
      .csr_status_errcode_in(hw.status_errcode),
      .csr_irq_done_set(hw.irq_done_set),
      .csr_irq_error_set(hw.irq_error_set),
      .csr_cmd_opcode_out(hw.cmd_opcode),
      .csr_cmd_arg_out(hw.cmd_arg),
      .csr_cmd_flag_out(hw.cmd_flag),
      .csr_event_count_in(hw.event_count),
      .csr_event_arm_out(hw.event_arm),

      // AXI4-Lite side, straight off the interface.
      .axil_awaddr(axil.awaddr),
      .axil_awprot(axil.awprot),
      .axil_awvalid(axil.awvalid),
      .axil_awready(axil.awready),
      .axil_wdata(axil.wdata),
      .axil_wstrb(axil.wstrb),
      .axil_wvalid(axil.wvalid),
      .axil_wready(axil.wready),
      .axil_bresp(axil.bresp),
      .axil_bvalid(axil.bvalid),
      .axil_bready(axil.bready),
      .axil_araddr(axil.araddr),
      .axil_arprot(axil.arprot),
      .axil_arvalid(axil.arvalid),
      .axil_arready(axil.arready),
      .axil_rdata(axil.rdata),
      .axil_rresp(axil.rresp),
      .axil_rvalid(axil.rvalid),
      .axil_rready(axil.rready)
  );

  // ---- Hand both interfaces to the testbench --------------------------
  initial begin
    uvm_config_db#(corsair_vif_t)::set(null, "*", "vif", axil);
    uvm_config_db#(corsair_hw_vif_t)::set(null, "*", "hw_vif", hw);
    run_test("corsair_example_base_test");
  end

  // ---- Pass/fail banner -----------------------------------------------
  // XSIM exits 0 even after a UVM_FATAL, so the Makefile greps for this
  // line rather than trusting the exit status.
  final begin
    uvm_report_server svr;
    int n_fatals, n_errors, n_warnings;
    string test_name;
    svr        = uvm_report_server::get_server();
    n_fatals   = svr.get_severity_count(UVM_FATAL);
    n_errors   = svr.get_severity_count(UVM_ERROR);
    n_warnings = svr.get_severity_count(UVM_WARNING);
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name))
      test_name = "corsair_example_base_test";
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: corsair_example_regs  |  top: corsair_example_tb_top");
    $display(" test    : %s", test_name);
    $display(" result  : %s", ((n_fatals == 0) && (n_errors == 0)) ? "PASSED" : "FAILED");
    $display(" fatals=%0d errors=%0d warnings=%0d", n_fatals, n_errors, n_warnings);
    $display("============================================================");
  end

endmodule : corsair_example_tb_top
