///////////////////////////////////////////////////////////////////
// Filename: axi_lite_tb_ctrl_if.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Testbench control interface: owns ARESETn for every port and
//           gives a UVM test the two things it cannot do from a class --
//           pulse reset, and wait a number of ACLK cycles.
///////////////////////////////////////////////////////////////////
//
// ARESETn has exactly one driver, here, so the power-on reset and any
// mid-run reset a test asks for cannot fight each other.
//
// Reset moves on the falling edge of ACLK deliberately: deasserting it
// away from a rising edge makes $rose(aresetn) land unambiguously on the
// next one, which is the edge AXI4-Lite's reset rule is written about.

interface axi_lite_tb_ctrl_if #(
  parameter int RESET_CYCLES = 5   // length of the power-on reset
) (
  input logic aclk
);

  logic aresetn = 1'b0;

  // Power-on reset, applied before any driver can offer a transfer.
  initial begin
    aresetn = 1'b0;
    repeat (RESET_CYCLES) @(negedge aclk);
    aresetn = 1'b1;
  end

  // Pulse reset in the middle of a run. Returns once reset has been
  // released and one further edge has passed, so the caller resumes at a
  // point where drivers are legally allowed to assert VALID again.
  task automatic assert_reset(int unsigned cycles = 5);
    @(negedge aclk);
    aresetn <= 1'b0;
    repeat (cycles) @(negedge aclk);
    aresetn <= 1'b1;
    @(negedge aclk);
  endtask

  task automatic wait_cycles(int unsigned n);
    repeat (n) @(posedge aclk);
  endtask

endinterface : axi_lite_tb_ctrl_if
