///////////////////////////////////////////////////////////////////
// Filename: axi_lite_chan_fifo.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : A small, protocol-correct buffer for one VALID/READY
//           channel. Five of these make the AXI4-Lite register slice the
//           self-test talks to.
///////////////////////////////////////////////////////////////////
//
// Every AXI4-Lite channel is the same handshake carrying a different
// payload, so one parameterized buffer serves all five and the register
// slice above it is just wiring.
//
// Deliberately written to be correct rather than clever, because the
// self-test uses it as a reference: every transfer that goes in comes
// out unchanged and in order, so any difference the scoreboard sees is
// the UVC's fault, not the DUT's.
//
// The two handshake rules it has to respect, and how:
//
//   m_valid is (count != 0). Once asserted, count cannot fall without a
//   transfer, so VALID is never withdrawn, and the payload is mem[rd],
//   which only moves on a transfer -- so the payload is stable while
//   stalled. Neither expression mentions m_ready, so VALID never
//   depends on READY.
//
//   s_ready is (count != DEPTH), which does not mention s_valid either.
//   A receiver is allowed to look at VALID; not doing so just means this
//   buffer's READY is honest about its capacity.
//
// Reset is asynchronous, so VALID drops the instant ARESETn does --
// what real AXI hardware does, and what the interface's reset assertions
// expect.

module axi_lite_chan_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 4    // must be a power of two >= 2
) (
  input  logic             aclk,
  input  logic             aresetn,

  input  logic             s_valid,
  output logic             s_ready,
  input  logic [WIDTH-1:0] s_data,

  output logic             m_valid,
  input  logic             m_ready,
  output logic [WIDTH-1:0] m_data
);

  localparam int PTR_W = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PTR_W-1:0] wr_ptr;
  logic [PTR_W-1:0] rd_ptr;
  logic [PTR_W:0]   count;
  logic             push;
  logic             pop;

  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0))
      $fatal(1, "axi_lite_chan_fifo: DEPTH must be a power of two >= 2, got %0d", DEPTH);
  end

  assign s_ready = (count != DEPTH[PTR_W:0]);
  assign m_valid = (count != '0);
  assign m_data  = mem[rd_ptr];

  assign push = s_valid && s_ready;
  assign pop  = m_valid && m_ready;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end
    else begin
      if (push) begin
        mem[wr_ptr] <= s_data;
        wr_ptr      <= wr_ptr + 1'b1;
      end
      if (pop)
        rd_ptr <= rd_ptr + 1'b1;

      case ({push, pop})
        2'b10   : count <= count + 1'b1;
        2'b01   : count <= count - 1'b1;
        default : count <= count;
      endcase
    end
  end

endmodule : axi_lite_chan_fifo
