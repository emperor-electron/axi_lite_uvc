///////////////////////////////////////////////////////////////////
// Filename: corsair_example_hw_if.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : The hardware side of the Corsair-generated register block,
//           so a test can drive the inputs the DUT reports and observe
//           the outputs it drives.
///////////////////////////////////////////////////////////////////
//
// Corsair gives every field with a hardware option a port of its own, and
// those ports are what make this example able to *prove* the register
// layer did the right thing rather than merely report that it did:
//
//   - CMD is write-only, so its value cannot be read back over the bus.
//     Watching csr_cmd_opcode_out tells us whether writing CMD.ARG
//     disturbed CMD.OPCODE, which is the thing the shadow strategy
//     exists to get right.
//   - IRQ is write-1-to-clear and set by hardware, so driving
//     csr_irq_*_set here is how the test arranges the exact situation a
//     read-modify-write would corrupt.

interface corsair_example_hw_if (
    input logic aclk,
    input logic aresetn
);

  // Driven by the testbench, read by the DUT's STATUS register.
  logic       status_busy = 1'b0;
  logic [3:0] status_errcode = 4'h0;

  // Pulsed by the testbench to set an IRQ flag, exactly as real hardware
  // would.
  logic       irq_done_set = 1'b0;
  logic       irq_error_set = 1'b0;

  // EVENT.COUNT is read-only and cleared by the read itself, so the DUT
  // reloads it from this input on every other cycle.
  logic [7:0] event_count = 8'h00;

  // Driven by the DUT, observed by the testbench.
  logic        ctrl_enable;
  logic [1:0]  ctrl_mode;
  logic [7:0]  ctrl_gain;
  logic [11:0] ctrl_thresh;
  logic [7:0]  cmd_opcode;
  logic [15:0] cmd_arg;
  logic        cmd_flag;
  logic        event_arm;

  // Raise an IRQ the way hardware does: one ACLK cycle of the set input.
  task automatic set_irq_done();
    @(posedge aclk);
    irq_done_set <= 1'b1;
    @(posedge aclk);
    irq_done_set <= 1'b0;
  endtask

  task automatic set_irq_error();
    @(posedge aclk);
    irq_error_set <= 1'b1;
    @(posedge aclk);
    irq_error_set <= 1'b0;
  endtask

  // Both in the same cycle, which is the case that separates a correct
  // write-1-to-clear from a read-modify-write.
  task automatic set_irq_both();
    @(posedge aclk);
    irq_done_set  <= 1'b1;
    irq_error_set <= 1'b1;
    @(posedge aclk);
    irq_done_set  <= 1'b0;
    irq_error_set <= 1'b0;
  endtask

  task automatic set_event_count(logic [7:0] value);
    @(posedge aclk);
    event_count <= value;
    @(posedge aclk);
  endtask

  task automatic set_status(logic busy, logic [3:0] errcode);
    @(posedge aclk);
    status_busy    <= busy;
    status_errcode <= errcode;
    @(posedge aclk);
  endtask

endinterface : corsair_example_hw_if
