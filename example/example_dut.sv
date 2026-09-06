///////////////////////////////////////////////////////////////////
// Filename: example_dut.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Stand-in DUT for the integration example: a small AXI4-Lite
//           register file with a read-only ID register and a decode
//           error above its aperture.
///////////////////////////////////////////////////////////////////
//
// Replace this with your own design. It is here so the example is
// runnable, and it is a register file rather than a wire because that is
// what an AXI4-Lite port is almost always attached to -- and because it
// gives the scoreboard something worth modelling: three behaviours, not
// one.
//
//   0x00          ID register. Reads a constant; writes are accepted and
//                 ignored, which is what most status registers do.
//   0x04 .. 0x3C  15 scratch registers, read/write, byte-strobed.
//   0x40 and up   nothing there: answered with DECERR.
//
// The two handshake rules it has to respect, and how:
//
//   BVALID is only ever *asserted* when the write actually completes,
//   and completion is qualified on B being free -- never on BREADY -- so
//   VALID never depends on READY. Once high it holds until BREADY, since
//   the only thing that clears it is a completed handshake.
//
//   AWREADY and WREADY are simply "I have nowhere to put it yet", so
//   the two halves of a write may arrive in either order and at
//   unrelated rates, which AXI4-Lite explicitly permits.
//
// Reset is asynchronous, so every VALID drops the instant ARESETn does
// -- what real AXI hardware does, and what the interface's reset
// assertions expect.

module example_dut #(
  parameter int ADDR_WIDTH = 12,
  parameter int DATA_WIDTH = 32,
  parameter int NUM_REGS   = 16,

  // Derived. Do not override.
  parameter int STRB_WIDTH = DATA_WIDTH / 8
) (
  input  logic aclk,
  input  logic aresetn,

  input  logic                  s_axil_awvalid,
  output logic                  s_axil_awready,
  input  logic [ADDR_WIDTH-1:0] s_axil_awaddr,
  input  logic [2:0]            s_axil_awprot,

  input  logic                  s_axil_wvalid,
  output logic                  s_axil_wready,
  input  logic [DATA_WIDTH-1:0] s_axil_wdata,
  input  logic [STRB_WIDTH-1:0] s_axil_wstrb,

  output logic                  s_axil_bvalid,
  input  logic                  s_axil_bready,
  output logic [1:0]            s_axil_bresp,

  input  logic                  s_axil_arvalid,
  output logic                  s_axil_arready,
  input  logic [ADDR_WIDTH-1:0] s_axil_araddr,
  input  logic [2:0]            s_axil_arprot,

  output logic                  s_axil_rvalid,
  input  logic                  s_axil_rready,
  output logic [DATA_WIDTH-1:0] s_axil_rdata,
  output logic [1:0]            s_axil_rresp
);

  localparam int ADDR_LSB  = $clog2(STRB_WIDTH);          // byte-within-word bits
  localparam int INDEX_W   = $clog2(NUM_REGS);
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // Value of the read-only register at offset 0.
  localparam logic [31:0] ID_VALUE = 32'hA711_0001;

  logic [DATA_WIDTH-1:0] regs [NUM_REGS];

  // ---- Captured request phases ---------------------------------------
  logic                  aw_have, w_have, ar_have;
  logic [ADDR_WIDTH-1:0] aw_addr, ar_addr;
  logic [DATA_WIDTH-1:0] w_data;
  logic [STRB_WIDTH-1:0] w_strb;

  // A phase is accepted whenever there is no un-serviced one already
  // held. Neither expression mentions the matching VALID, so this slave
  // never makes its READY conditional on being offered something.
  assign s_axil_awready = !aw_have;
  assign s_axil_wready  = !w_have;
  assign s_axil_arready = !ar_have;

  // Service a write once both halves are in *and* the response channel
  // is free. Qualifying on !s_axil_bvalid rather than on s_axil_bready is
  // what keeps BVALID from depending on BREADY.
  wire do_write = aw_have && w_have && !s_axil_bvalid;
  wire do_read  = ar_have && !s_axil_rvalid;

  // ---- Decode ---------------------------------------------------------
  function automatic bit in_range(logic [ADDR_WIDTH-1:0] addr);
    return (addr >> ADDR_LSB) < NUM_REGS;
  endfunction

  function automatic logic [INDEX_W-1:0] reg_index(logic [ADDR_WIDTH-1:0] addr);
    return addr[ADDR_LSB +: INDEX_W];
  endfunction

  // ---- Write path -----------------------------------------------------
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_have       <= 1'b0;
      w_have        <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp  <= RESP_OKAY;
      for (int i = 0; i < NUM_REGS; i++)
        regs[i] <= '0;
    end
    else begin
      if (do_write) begin
        aw_have       <= 1'b0;
        w_have        <= 1'b0;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= in_range(aw_addr) ? RESP_OKAY : RESP_DECERR;

        // Register 0 is read-only: the write is accepted and answered
        // OKAY, it simply does not land. Everything else takes the write
        // one enabled byte lane at a time.
        if (in_range(aw_addr) && (reg_index(aw_addr) != '0))
          for (int b = 0; b < STRB_WIDTH; b++)
            if (w_strb[b])
              regs[reg_index(aw_addr)][b*8 +: 8] <= w_data[b*8 +: 8];
      end
      else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      // Accepting comes after servicing, so a phase arriving in the same
      // cycle one is consumed is kept rather than lost. It cannot clash:
      // AWREADY is low exactly when aw_have is high, which is what
      // do_write needed in the first place.
      if (s_axil_awvalid && s_axil_awready) begin
        aw_have <= 1'b1;
        aw_addr <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_have <= 1'b1;
        w_data <= s_axil_wdata;
        w_strb <= s_axil_wstrb;
      end
    end
  end

  // ---- Read path ------------------------------------------------------
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      ar_have       <= 1'b0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
      s_axil_rresp  <= RESP_OKAY;
    end
    else begin
      if (do_read) begin
        ar_have       <= 1'b0;
        s_axil_rvalid <= 1'b1;
        s_axil_rresp  <= in_range(ar_addr) ? RESP_OKAY : RESP_DECERR;
        if (!in_range(ar_addr))
          s_axil_rdata <= '0;
        else if (reg_index(ar_addr) == '0)
          s_axil_rdata <= DATA_WIDTH'(ID_VALUE);
        else
          s_axil_rdata <= regs[reg_index(ar_addr)];
      end
      else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        ar_have <= 1'b1;
        ar_addr <= s_axil_araddr;
      end
    end
  end

endmodule : example_dut
