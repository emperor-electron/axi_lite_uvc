///////////////////////////////////////////////////////////////////
// Filename: axi_lite_link.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : One complete AXI4-Lite link of the self-test: a source
//           interface into a register slice, a sink interface out of it,
//           and the config-DB plumbing that hands both to the matching
//           env.
///////////////////////////////////////////////////////////////////
//
// This module is what makes "test several parameter combinations in one
// simulation" cheap. Everything a link needs is behind one parameter
// list, so the top module adds a width by instantiating this again with
// different numbers -- no `define, no second compile, no second run.
//
// ENV_NAME must match the instance name of the env that drives this
// link, since that is the config-DB scope the two interfaces are
// published to.
//
// Note which end drives what. On `src`, the UVC's master agent drives
// AW/W/AR and the register slice drives AWREADY/WREADY/ARREADY and the
// responses; on `snk` it is the other way round, with the UVC's slave
// agent answering out of its memory model. Each signal therefore has
// exactly one driver, which is why the same interface type serves both
// ends -- and why one `axi_lite_if.sv` is all this testbench needs.

module axi_lite_link #(
  parameter string ENV_NAME   = "env",
  parameter int    ADDR_WIDTH = 32,
  parameter int    DATA_WIDTH = 32,
  parameter int    DEPTH      = 4
) (
  input logic aclk,
  input logic aresetn
);

  import uvm_pkg::*;

  typedef virtual axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) vif_t;

  // Into the DUT: driven by the UVC's master agent.
  axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) src (aclk, aresetn);
  // Out of the DUT: answered by the UVC's slave agent.
  axi_lite_if #(ADDR_WIDTH, DATA_WIDTH) snk (aclk, aresetn);

  axi_lite_reg_slice #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
  ) u_dut (
    .aclk           (aclk),
    .aresetn        (aresetn),

    .s_axil_awvalid (src.awvalid), .s_axil_awready (src.awready),
    .s_axil_awaddr  (src.awaddr),  .s_axil_awprot  (src.awprot),
    .s_axil_wvalid  (src.wvalid),  .s_axil_wready  (src.wready),
    .s_axil_wdata   (src.wdata),   .s_axil_wstrb   (src.wstrb),
    .s_axil_bvalid  (src.bvalid),  .s_axil_bready  (src.bready),
    .s_axil_bresp   (src.bresp),
    .s_axil_arvalid (src.arvalid), .s_axil_arready (src.arready),
    .s_axil_araddr  (src.araddr),  .s_axil_arprot  (src.arprot),
    .s_axil_rvalid  (src.rvalid),  .s_axil_rready  (src.rready),
    .s_axil_rdata   (src.rdata),   .s_axil_rresp   (src.rresp),

    .m_axil_awvalid (snk.awvalid), .m_axil_awready (snk.awready),
    .m_axil_awaddr  (snk.awaddr),  .m_axil_awprot  (snk.awprot),
    .m_axil_wvalid  (snk.wvalid),  .m_axil_wready  (snk.wready),
    .m_axil_wdata   (snk.wdata),   .m_axil_wstrb   (snk.wstrb),
    .m_axil_bvalid  (snk.bvalid),  .m_axil_bready  (snk.bready),
    .m_axil_bresp   (snk.bresp),
    .m_axil_arvalid (snk.arvalid), .m_axil_arready (snk.arready),
    .m_axil_araddr  (snk.araddr),  .m_axil_arprot  (snk.arprot),
    .m_axil_rvalid  (snk.rvalid),  .m_axil_rready  (snk.rready),
    .m_axil_rdata   (snk.rdata),   .m_axil_rresp   (snk.rresp)
  );

  initial begin
    uvm_config_db#(vif_t)::set(null, {"*.", ENV_NAME}, "vif_src", src);
    uvm_config_db#(vif_t)::set(null, {"*.", ENV_NAME}, "vif_snk", snk);
  end

endmodule : axi_lite_link
