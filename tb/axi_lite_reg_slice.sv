///////////////////////////////////////////////////////////////////
// Filename: axi_lite_reg_slice.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : An AXI4-Lite register slice: a slave port on one side, a
//           master port on the other, and a buffer on each of the five
//           channels. It is not the thing under test -- the UVC is --
//           but it is what gives the UVC something real on both sides.
///////////////////////////////////////////////////////////////////
//
// Why this shape of DUT
// ---------------------
// A register file would only exercise half the UVC: the master agent
// would have something to drive, and the slave agent nothing to do. A
// register slice has both a slave port and a master port, so one
// instance puts the UVC's master driver on one end and its slave driver
// -- memory model, response delays and all -- on the other, with the
// scoreboard checking that what went in came out.
//
// It is buffered rather than a bare wire on purpose. A pass-through with
// no storage cannot decouple the two ends, so source pacing and sink
// backpressure would never genuinely interact and half the interesting
// timing would be unreachable.
//
// The five channels are independent, so buffering them independently
// preserves the protocol, including the response-ordering rules the
// interface asserts:
//
//   The far slave only issues B after it has been given AW and W, and
//   AW and W only reach it after being accepted here -- so a B arriving
//   at this module's slave port always follows the AW and W that were
//   accepted there. The same argument runs the other way for R.
//
// Note which way each channel flows: AW, W and AR travel from the slave
// port to the master port, while B and R travel back.

module axi_lite_reg_slice #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 4,   // per-channel buffering; power of two >= 2

  // Derived. Do not override.
  parameter int STRB_WIDTH = DATA_WIDTH / 8
) (
  input  logic aclk,
  input  logic aresetn,

  // Slave port: driven by an AXI4-Lite master (here, the UVC's master agent).
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
  output logic [1:0]            s_axil_rresp,

  // Master port: driven into an AXI4-Lite slave (the UVC's slave agent).
  output logic                  m_axil_awvalid,
  input  logic                  m_axil_awready,
  output logic [ADDR_WIDTH-1:0] m_axil_awaddr,
  output logic [2:0]            m_axil_awprot,
  output logic                  m_axil_wvalid,
  input  logic                  m_axil_wready,
  output logic [DATA_WIDTH-1:0] m_axil_wdata,
  output logic [STRB_WIDTH-1:0] m_axil_wstrb,
  input  logic                  m_axil_bvalid,
  output logic                  m_axil_bready,
  input  logic [1:0]            m_axil_bresp,
  output logic                  m_axil_arvalid,
  input  logic                  m_axil_arready,
  output logic [ADDR_WIDTH-1:0] m_axil_araddr,
  output logic [2:0]            m_axil_arprot,
  input  logic                  m_axil_rvalid,
  output logic                  m_axil_rready,
  input  logic [DATA_WIDTH-1:0] m_axil_rdata,
  input  logic [1:0]            m_axil_rresp
);

  localparam int AW_W = ADDR_WIDTH + 3;
  localparam int W_W  = DATA_WIDTH + STRB_WIDTH;
  localparam int B_W  = 2;
  localparam int AR_W = ADDR_WIDTH + 3;
  localparam int R_W  = DATA_WIDTH + 2;

  // ---- Forward: write address ----------------------------------------
  axi_lite_chan_fifo #(.WIDTH(AW_W), .DEPTH(DEPTH)) u_aw (
    .aclk, .aresetn,
    .s_valid (s_axil_awvalid), .s_ready (s_axil_awready),
    .s_data  ({s_axil_awprot, s_axil_awaddr}),
    .m_valid (m_axil_awvalid), .m_ready (m_axil_awready),
    .m_data  ({m_axil_awprot, m_axil_awaddr})
  );

  // ---- Forward: write data -------------------------------------------
  axi_lite_chan_fifo #(.WIDTH(W_W), .DEPTH(DEPTH)) u_w (
    .aclk, .aresetn,
    .s_valid (s_axil_wvalid), .s_ready (s_axil_wready),
    .s_data  ({s_axil_wstrb, s_axil_wdata}),
    .m_valid (m_axil_wvalid), .m_ready (m_axil_wready),
    .m_data  ({m_axil_wstrb, m_axil_wdata})
  );

  // ---- Backward: write response --------------------------------------
  axi_lite_chan_fifo #(.WIDTH(B_W), .DEPTH(DEPTH)) u_b (
    .aclk, .aresetn,
    .s_valid (m_axil_bvalid), .s_ready (m_axil_bready),
    .s_data  (m_axil_bresp),
    .m_valid (s_axil_bvalid), .m_ready (s_axil_bready),
    .m_data  (s_axil_bresp)
  );

  // ---- Forward: read address ------------------------------------------
  axi_lite_chan_fifo #(.WIDTH(AR_W), .DEPTH(DEPTH)) u_ar (
    .aclk, .aresetn,
    .s_valid (s_axil_arvalid), .s_ready (s_axil_arready),
    .s_data  ({s_axil_arprot, s_axil_araddr}),
    .m_valid (m_axil_arvalid), .m_ready (m_axil_arready),
    .m_data  ({m_axil_arprot, m_axil_araddr})
  );

  // ---- Backward: read data --------------------------------------------
  axi_lite_chan_fifo #(.WIDTH(R_W), .DEPTH(DEPTH)) u_r (
    .aclk, .aresetn,
    .s_valid (m_axil_rvalid), .s_ready (m_axil_rready),
    .s_data  ({m_axil_rresp, m_axil_rdata}),
    .m_valid (s_axil_rvalid), .m_ready (s_axil_rready),
    .m_data  ({s_axil_rresp, s_axil_rdata})
  );

endmodule : axi_lite_reg_slice
