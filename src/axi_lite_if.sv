///////////////////////////////////////////////////////////////////
// Filename: axi_lite_if.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Parameterizable AMBA AXI4-Lite interface (ARM IHI 0022).
//           One file serving two masters: a synthesizable interface to
//           wire up inside a design, and -- under a simulation-only
//           guard -- the clocking blocks, protocol assertions and
//           configuration API that make it the UVC's virtual interface.
///////////////////////////////////////////////////////////////////
//
// Synthesizable and verification content in one file
// --------------------------------------------------
// Everything a synthesis tool would reject -- clocking blocks,
// assertions, the handshake counters, the string/`%m` reporting helpers
// -- lives inside `ifdef AXI_LITE_IF_SIM. What is left outside it is
// just the signal set and the DUT-facing modports, so the same file can
// be instantiated in RTL and elaborated by Vivado synthesis:
//
//   axi_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cfg (.aclk(clk), .aresetn(rstn));
//   my_cpu       u_cpu  (.m_axil(cfg.dut_master));
//   my_periph    u_regs (.s_axil(cfg.dut_slave));
//
// AXI_LITE_IF_SIM is set automatically from XILINX_SIMULATOR, which
// xvlog/xelab predefine and Vivado synthesis does not, so nothing has to
// be passed on the command line for either flow. On a simulator that
// does not define it, ask for it explicitly:
//
//   vlog +define+AXI_LITE_IF_SIM ...
//
// The UVC needs the simulation half (its drivers and monitor talk to the
// clocking blocks), so a UVC compile without that macro will not build --
// loudly, at the first reference to `mst_cb`, rather than subtly.
//
// Parameterization
// ----------------
// Both widths are SystemVerilog *parameters*, never compile-time
// `defines, so a single compilation can hold as many differently sized
// AXI4-Lite ports as it likes:
//
//   axi_lite_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) regs (aclk, aresetn);
//   axi_lite_if #(.ADDR_WIDTH(64), .DATA_WIDTH(64)) host (aclk, aresetn);
//
// AXI4-Lite fixes the data bus at 32 or 64 bits and every access at the
// full bus width, so WSTRB is DATA_WIDTH/8 bits and there is no burst,
// no ID, and no exclusive access to parameterize. A width outside
// {32, 64} still elaborates -- narrow control buses are common in
// practice -- but says so at time 0 rather than pretending to be AMBA.
//
// `checks_enable` and friends are plain variables, so a testbench with
// no UVM in it can set them directly:
//
//   initial regs.configure(.en_checks(1), .en_addr_alignment(0));
//

// Derive the simulation gate from the simulator's own macro, unless the
// user has already asked for it. `ifndef first, so an explicit
// +define+AXI_LITE_IF_SIM on any other simulator wins.
`ifndef AXI_LITE_IF_SIM
`ifdef XILINX_SIMULATOR
`define AXI_LITE_IF_SIM
`endif
`endif

interface axi_lite_if #(
    // AWADDR/ARADDR width in bits. Only the bits a slave actually decodes
    // need to be present, so a peripheral with a 4 KB aperture is happy
    // with 12.
    parameter int ADDR_WIDTH = 32,
    // WDATA/RDATA width in bits. AXI4-Lite permits 32 or 64.
    parameter int DATA_WIDTH = 32
) (
    input logic aclk,
    input logic aresetn
);

  // WSTRB has one bit per byte lane of the data bus, and the address
  // bits below STRB_WIDTH are the ones a full-width access must have
  // clear.
  localparam int STRB_WIDTH = DATA_WIDTH / 8;
  localparam int ADDR_LSB = (STRB_WIDTH > 1) ? $clog2(STRB_WIDTH) : 0;

  // ---------------------------------------------------------------------
  // AXI4-Lite signals, by channel. Each is driven by exactly one side:
  // the master sources AW, W, AR (and BREADY/RREADY); the slave sources
  // B, R (and AWREADY/WREADY/ARREADY).
  // ---------------------------------------------------------------------

  // Write address channel
  logic                  awvalid;
  logic                  awready;
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [           2:0] awprot;

  // Write data channel
  logic                  wvalid;
  logic                  wready;
  logic [DATA_WIDTH-1:0] wdata;
  logic [STRB_WIDTH-1:0] wstrb;

  // Write response channel
  logic                  bvalid;
  logic                  bready;
  logic [           1:0] bresp;

  // Read address channel
  logic                  arvalid;
  logic                  arready;
  logic [ADDR_WIDTH-1:0] araddr;
  logic [           2:0] arprot;

  // Read data channel
  logic                  rvalid;
  logic                  rready;
  logic [DATA_WIDTH-1:0] rdata;
  logic [           1:0] rresp;

  // ---------------------------------------------------------------------
  // DUT-facing modports. A DUT written against these gets the signal
  // directions checked at elaboration; a DUT with plain ports can just
  // be wired to the signals by name instead. Both are synthesizable.
  // ---------------------------------------------------------------------
  modport dut_slave(
      input aclk, aresetn,
      input awvalid, awaddr, awprot,
      output awready,
      input wvalid, wdata, wstrb,
      output wready,
      output bvalid, bresp,
      input bready,
      input arvalid, araddr, arprot,
      output arready,
      output rvalid, rdata, rresp,
      input rready
  );

  modport dut_master(
      input aclk, aresetn,
      output awvalid, awaddr, awprot,
      input awready,
      output wvalid, wdata, wstrb,
      input wready,
      input bvalid, bresp,
      output bready,
      output arvalid, araddr, arprot,
      input arready,
      input rvalid, rdata, rresp,
      output rready
  );

  // =====================================================================
  // Everything below here is simulation-only: clocking blocks, the
  // verification configuration API, the handshake counters and the
  // protocol assertions. None of it is synthesizable, and none of it is
  // compiled unless AXI_LITE_IF_SIM is set (see the header).
  //
  // New coverpoints or formal properties belong inside this guard too.
  // =====================================================================
`ifdef AXI_LITE_IF_SIM

  // ---------------------------------------------------------------------
  // Run-time description of what this link checks. Defaults are the
  // strict reading of the spec; the agent overwrites them from its
  // config.
  // ---------------------------------------------------------------------
  bit          checks_enable = 1'b1;
  // AXI4-Lite accesses are always the full width of the data bus, so an
  // address with any of its low ADDR_LSB bits set describes an access
  // that cannot happen. Clear this for a DUT that deliberately decodes
  // sub-word addresses.
  bit          check_addr_alignment = 1'b1;
  // AXI4-Lite has no exclusive access, so EXOKAY on BRESP/RRESP is out
  // of spec wherever it appears.
  bit          check_exokay = 1'b1;
  // Whether AWPROT/ARPROT are real on this link. A DUT that ties them
  // off is common enough to be worth not failing over.
  bit          has_prot = 1'b1;

  // Every assertion failure below bumps this counter as well as printing.
  // The monitor's check_phase turns a non-zero count into a UVM_ERROR, so
  // protocol violations fail the test even though the assertions
  // themselves know nothing about UVM.
  int unsigned protocol_error_count = 0;

  // Rule name of the most recent failure, so a checker testbench can
  // report which rule fired without having to scrape the log.
  string       last_protocol_error_rule = "";

  // Formals are prefixed so they cannot shadow the variables of the same
  // name declared above.
  function automatic void configure(bit en_checks = 1'b1, bit en_addr_alignment = 1'b1,
                                    bit en_exokay = 1'b1, bit en_prot = 1'b1);
    checks_enable        = en_checks;
    check_addr_alignment = en_addr_alignment;
    check_exokay         = en_exokay;
    has_prot             = en_prot;
  endfunction

  // Hierarchical path of this interface instance, so a UVM component
  // holding only a virtual handle can still name it in a report.
  function automatic string path();
    return $sformatf("%m");
  endfunction

  function automatic void protocol_error(string rule, string msg);
    protocol_error_count++;
    last_protocol_error_rule = rule;
    $error("%m: AXI4-Lite protocol violation [%s]: %s", rule, msg);
  endfunction

  // AXI4-Lite fixes the data bus at 32 or 64 bits (IHI 0022 B1.1). A
  // narrower bus is a common local convention rather than AMBA, so this
  // is a note at time 0, not a fatal -- but it is said out loud, since a
  // UVC that quietly accepted 8 bits would be claiming compliance it
  // cannot deliver.
  //
  // The ceiling is restated here rather than imported from
  // axi_lite_types.sv on purpose: the interface must not depend on the
  // UVC package, so that a testbench with no UVM in it can use it alone.
  localparam int MAX_TRANSACTION_ADDR_WIDTH = 64;

  initial begin
    if ((DATA_WIDTH != 32) && (DATA_WIDTH != 64))
      $warning(
          "%m: DATA_WIDTH=%0d; AXI4-Lite permits only 32 or 64. Elaborating anyway.", DATA_WIDTH
      );
    if (ADDR_WIDTH > MAX_TRANSACTION_ADDR_WIDTH)
      $warning(
          "%m: ADDR_WIDTH=%0d exceeds the %0d bits the UVC's transaction can carry.",
          ADDR_WIDTH,
          MAX_TRANSACTION_ADDR_WIDTH
      );
  end

  // ---------------------------------------------------------------------
  // Clocking blocks.
  //
  // `input #1step` samples each signal in the Preponed region, i.e. the
  // value that settled *before* the clock edge -- exactly what a real
  // flop sees. `output #0` drives in the Re-NBA region *after* the edge,
  // so a DUT's always_ff sampling the same edge still sees the old value.
  // Together they make driving and sampling race-free without depending
  // on the timescale, which matters here because a UVC gets reused at
  // whatever clock period the host testbench happens to run.
  // ---------------------------------------------------------------------
  clocking mst_cb @(posedge aclk);
    default input #1step output #0;
    output awvalid, awaddr, awprot;
    output wvalid, wdata, wstrb;
    output bready;
    output arvalid, araddr, arprot;
    output rready;
    input awready, wready;
    input bvalid, bresp;
    input arready;
    input rvalid, rdata, rresp;
    input aresetn;
  endclocking : mst_cb

  clocking slv_cb @(posedge aclk);
    default input #1step output #0;
    output awready, wready;
    output bvalid, bresp;
    output arready;
    output rvalid, rdata, rresp;
    input awvalid, awaddr, awprot;
    input wvalid, wdata, wstrb;
    input bready;
    input arvalid, araddr, arprot;
    input rready;
    input aresetn;
  endclocking : slv_cb

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awvalid, awready, awaddr, awprot;
    input wvalid, wready, wdata, wstrb;
    input bvalid, bready, bresp;
    input arvalid, arready, araddr, arprot;
    input rvalid, rready, rdata, rresp;
    input aresetn;
  endclocking : mon_cb

  // UVC-facing modports, for testbenches that prefer to pass modports
  // around. The UVC itself takes the whole interface, since it needs
  // both a clocking block and the configure()/protocol_error_count API.
  modport mst_mp(clocking mst_cb, input aclk, aresetn);
  modport slv_mp(clocking slv_cb, input aclk, aresetn);
  modport mon_mp(clocking mon_cb, input aclk, aresetn);

  // ---------------------------------------------------------------------
  // Handshake census. Kept here rather than in the monitor because the
  // response-ordering rules below are about *counts* of completed
  // handshakes, and an assertion cannot call into a class to get one.
  // A testbench can read them too -- the checker testbench does.
  // ---------------------------------------------------------------------
  wire aw_handshake = (awvalid === 1'b1) && (awready === 1'b1);
  wire w_handshake = (wvalid === 1'b1) && (wready === 1'b1);
  wire b_handshake = (bvalid === 1'b1) && (bready === 1'b1);
  wire ar_handshake = (arvalid === 1'b1) && (arready === 1'b1);
  wire r_handshake = (rvalid === 1'b1) && (rready === 1'b1);

  int unsigned aw_accepted = 0;
  int unsigned w_accepted = 0;
  int unsigned b_accepted = 0;
  int unsigned ar_accepted = 0;
  int unsigned r_accepted = 0;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_accepted <= 0;
      w_accepted  <= 0;
      b_accepted  <= 0;
      ar_accepted <= 0;
      r_accepted  <= 0;
    end else begin
      if (aw_handshake) aw_accepted <= aw_accepted + 1;
      if (w_handshake) w_accepted <= w_accepted + 1;
      if (b_handshake) b_accepted <= b_accepted + 1;
      if (ar_handshake) ar_accepted <= ar_accepted + 1;
      if (r_handshake) r_accepted <= r_accepted + 1;
    end
  end

  // =====================================================================
  // Protocol checks -- AMBA AXI and AXI4-Lite Protocol Specification
  // (IHI 0022), section A3.2 (handshake), A3.3 (channel dependencies),
  // A3.4 (responses) and section B (the AXI4-Lite subset). These police
  // the UVC and the DUT equally: whichever side drives the signal that
  // breaks a rule is the side the failure points at.
  //
  // Every property uses `aresetn !== 1'b1` rather than `!aresetn` in its
  // disable condition so that an X on reset disables the check instead
  // of evaluating to X and (in some tools) letting it run anyway.
  //
  // Each rule is written out one signal at a time rather than as a
  // single property taking the signal as an argument: property formal
  // arguments are legal SystemVerilog but XSIM silently *ignores*
  // properties that use them, which would leave these checks looking
  // present and doing nothing. One property per signal also means a
  // failure names the offending signal without having to decode an
  // argument.
  // =====================================================================

  // ---- A3.2.1: once VALID is asserted it must stay asserted until the
  // handshake occurs. Neither side may withdraw an offered transfer.
  property p_awvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (awvalid === 1'b1 && awready !== 1'b1) |=> (awvalid === 1'b1);
  endproperty
  a_awvalid_held :
  assert property (p_awvalid_held)
  else
    protocol_error("AWVALID_HELD", "AWVALID was deasserted before AWREADY completed the handshake");

  property p_wvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (wvalid === 1'b1 && wready !== 1'b1) |=> (wvalid === 1'b1);
  endproperty
  a_wvalid_held :
  assert property (p_wvalid_held)
  else protocol_error("WVALID_HELD", "WVALID was deasserted before WREADY completed the handshake");

  property p_bvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (bvalid === 1'b1 && bready !== 1'b1) |=> (bvalid === 1'b1);
  endproperty
  a_bvalid_held :
  assert property (p_bvalid_held)
  else protocol_error("BVALID_HELD", "BVALID was deasserted before BREADY completed the handshake");

  property p_arvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (arvalid === 1'b1 && arready !== 1'b1) |=> (arvalid === 1'b1);
  endproperty
  a_arvalid_held :
  assert property (p_arvalid_held)
  else
    protocol_error("ARVALID_HELD", "ARVALID was deasserted before ARREADY completed the handshake");

  property p_rvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (rvalid === 1'b1 && rready !== 1'b1) |=> (rvalid === 1'b1);
  endproperty
  a_rvalid_held :
  assert property (p_rvalid_held)
  else protocol_error("RVALID_HELD", "RVALID was deasserted before RREADY completed the handshake");

  // ---- A3.2.1: the payload must not change while a transfer is stalled.
  property p_awaddr_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (awvalid === 1'b1 && awready !== 1'b1) |=> $stable(
        awaddr
    );
  endproperty
  a_awaddr_stable :
  assert property (p_awaddr_stable)
  else protocol_error("AWADDR_STABLE", "AWADDR changed while AWVALID was asserted and AWREADY low");

  property p_awprot_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_prot)
      (awvalid === 1'b1 && awready !== 1'b1) |=> $stable(
        awprot
    );
  endproperty
  a_awprot_stable :
  assert property (p_awprot_stable)
  else protocol_error("AWPROT_STABLE", "AWPROT changed while AWVALID was asserted and AWREADY low");

  property p_wdata_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (wvalid === 1'b1 && wready !== 1'b1) |=> $stable(
        wdata
    );
  endproperty
  a_wdata_stable :
  assert property (p_wdata_stable)
  else protocol_error("WDATA_STABLE", "WDATA changed while WVALID was asserted and WREADY low");

  property p_wstrb_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (wvalid === 1'b1 && wready !== 1'b1) |=> $stable(
        wstrb
    );
  endproperty
  a_wstrb_stable :
  assert property (p_wstrb_stable)
  else protocol_error("WSTRB_STABLE", "WSTRB changed while WVALID was asserted and WREADY low");

  property p_bresp_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (bvalid === 1'b1 && bready !== 1'b1) |=> $stable(
        bresp
    );
  endproperty
  a_bresp_stable :
  assert property (p_bresp_stable)
  else protocol_error("BRESP_STABLE", "BRESP changed while BVALID was asserted and BREADY low");

  property p_araddr_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (arvalid === 1'b1 && arready !== 1'b1) |=> $stable(
        araddr
    );
  endproperty
  a_araddr_stable :
  assert property (p_araddr_stable)
  else protocol_error("ARADDR_STABLE", "ARADDR changed while ARVALID was asserted and ARREADY low");

  property p_arprot_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_prot)
      (arvalid === 1'b1 && arready !== 1'b1) |=> $stable(
        arprot
    );
  endproperty
  a_arprot_stable :
  assert property (p_arprot_stable)
  else protocol_error("ARPROT_STABLE", "ARPROT changed while ARVALID was asserted and ARREADY low");

  property p_rdata_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (rvalid === 1'b1 && rready !== 1'b1) |=> $stable(
        rdata
    );
  endproperty
  a_rdata_stable :
  assert property (p_rdata_stable)
  else protocol_error("RDATA_STABLE", "RDATA changed while RVALID was asserted and RREADY low");

  property p_rresp_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (rvalid === 1'b1 && rready !== 1'b1) |=> $stable(
        rresp
    );
  endproperty
  a_rresp_stable :
  assert property (p_rresp_stable)
  else protocol_error("RRESP_STABLE", "RRESP changed while RVALID was asserted and RREADY low");

  // ---- A3.1.2: VALID must be LOW while ARESETn is asserted, on every
  // channel and from both sides.
  //
  // Qualified on reset having *already* been low at the previous edge,
  // which gives a synchronous driver exactly one ACLK edge to react to
  // an asynchronously asserted reset -- the same one cycle a real
  // sync-reset flop takes. A driver that keeps offering a transfer
  // through reset still fails, which is the behaviour worth catching.
  //
  // Written as "not HIGH" rather than "=== 0" so the X on VALID before
  // any driver has run does not trip it; a real 1 during reset does.
  property p_awvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable) ($past(
        aresetn
    ) === 1'b0) |-> (awvalid !== 1'b1);
  endproperty
  a_awvalid_low_in_reset :
  assert property (p_awvalid_low_in_reset)
  else protocol_error("RESET_AWVALID", "AWVALID was still asserted a full cycle into ARESETn");

  property p_wvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable) ($past(
        aresetn
    ) === 1'b0) |-> (wvalid !== 1'b1);
  endproperty
  a_wvalid_low_in_reset :
  assert property (p_wvalid_low_in_reset)
  else protocol_error("RESET_WVALID", "WVALID was still asserted a full cycle into ARESETn");

  property p_bvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable) ($past(
        aresetn
    ) === 1'b0) |-> (bvalid !== 1'b1);
  endproperty
  a_bvalid_low_in_reset :
  assert property (p_bvalid_low_in_reset)
  else protocol_error("RESET_BVALID", "BVALID was still asserted a full cycle into ARESETn");

  property p_arvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable) ($past(
        aresetn
    ) === 1'b0) |-> (arvalid !== 1'b1);
  endproperty
  a_arvalid_low_in_reset :
  assert property (p_arvalid_low_in_reset)
  else protocol_error("RESET_ARVALID", "ARVALID was still asserted a full cycle into ARESETn");

  property p_rvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable) ($past(
        aresetn
    ) === 1'b0) |-> (rvalid !== 1'b1);
  endproperty
  a_rvalid_low_in_reset :
  assert property (p_rvalid_low_in_reset)
  else protocol_error("RESET_RVALID", "RVALID was still asserted a full cycle into ARESETn");

  // ---- A3.1.2: a driver may only begin driving VALID at a rising ACLK
  // edge *following* the edge at which ARESETn went high, so VALID must
  // still be low on that first post-reset edge. By now a driver has run,
  // so these demand a hard 0.
  property p_awvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable) $rose(
        aresetn
    ) |-> (awvalid === 1'b0);
  endproperty
  a_awvalid_low_after_reset :
  assert property (p_awvalid_low_after_reset)
  else
    protocol_error("RESET_AWVALID_EXIT",
                   "AWVALID was already high on the first ACLK edge after ARESETn deasserted");

  property p_wvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable) $rose(
        aresetn
    ) |-> (wvalid === 1'b0);
  endproperty
  a_wvalid_low_after_reset :
  assert property (p_wvalid_low_after_reset)
  else
    protocol_error("RESET_WVALID_EXIT",
                   "WVALID was already high on the first ACLK edge after ARESETn deasserted");

  property p_bvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable) $rose(
        aresetn
    ) |-> (bvalid === 1'b0);
  endproperty
  a_bvalid_low_after_reset :
  assert property (p_bvalid_low_after_reset)
  else
    protocol_error("RESET_BVALID_EXIT",
                   "BVALID was already high on the first ACLK edge after ARESETn deasserted");

  property p_arvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable) $rose(
        aresetn
    ) |-> (arvalid === 1'b0);
  endproperty
  a_arvalid_low_after_reset :
  assert property (p_arvalid_low_after_reset)
  else
    protocol_error("RESET_ARVALID_EXIT",
                   "ARVALID was already high on the first ACLK edge after ARESETn deasserted");

  property p_rvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable) $rose(
        aresetn
    ) |-> (rvalid === 1'b0);
  endproperty
  a_rvalid_low_after_reset :
  assert property (p_rvalid_low_after_reset)
  else
    protocol_error("RESET_RVALID_EXIT",
                   "RVALID was already high on the first ACLK edge after ARESETn deasserted");

  // ---- A3.3.1 channel dependencies: a write response belongs to a
  // write that has already been fully accepted, and read data belongs to
  // an address that has already been accepted. Counting handshakes is
  // what makes this checkable without tracking individual transactions:
  // the Nth B may not complete before the Nth AW and the Nth W have.
  //
  // The current cycle's own handshake counts, so a slave that accepts
  // the address, the data and answers in one cycle is allowed -- that is
  // legal AXI, if unusual. What is caught is a response for a
  // transaction that was never requested, which is the failure that
  // otherwise shows up as a mystery extra transaction in a scoreboard.
  property p_b_after_request;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      b_handshake |-> ((b_accepted < (aw_accepted + (aw_handshake ? 1 : 0))) &&
                       (b_accepted < (w_accepted  + (w_handshake  ? 1 : 0))));
  endproperty
  a_b_after_request :
  assert property (p_b_after_request)
  else
    protocol_error(
        "B_WITHOUT_REQUEST",
        "a write response completed before its write address and write data were both accepted");

  property p_r_after_request;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      r_handshake |-> (r_accepted < (ar_accepted + (ar_handshake ? 1 : 0)));
  endproperty
  a_r_after_request :
  assert property (p_r_after_request)
  else
    protocol_error("R_WITHOUT_REQUEST",
                   "read data was returned for a read address that was never accepted");

  // ---- B1.1 / A3.4.4: AXI4-Lite has no exclusive access, so EXOKAY is
  // not a legal response on either channel.
  property p_bresp_legal;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !check_exokay)
      (bvalid === 1'b1) |-> (bresp !== 2'b01);
  endproperty
  a_bresp_legal :
  assert property (p_bresp_legal)
  else protocol_error("BRESP_EXOKAY", "BRESP is EXOKAY, which AXI4-Lite does not define");

  property p_rresp_legal;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !check_exokay)
      (rvalid === 1'b1) |-> (rresp !== 2'b01);
  endproperty
  a_rresp_legal :
  assert property (p_rresp_legal)
  else protocol_error("RRESP_EXOKAY", "RRESP is EXOKAY, which AXI4-Lite does not define");

  // ---- B1.1: every AXI4-Lite access is the full width of the data bus,
  // so the address bits below the bus width must be zero. Generated only
  // where there are such bits to check.
  if (ADDR_LSB > 0) begin : g_alignment
    a_awaddr_aligned :
    assert property (
      @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !check_addr_alignment)
        (awvalid === 1'b1) |-> (awaddr[ADDR_LSB-1:0] === '0)
    )
    else
      protocol_error("AWADDR_ALIGN", $sformatf(
                     "AWADDR 0x%0h is not aligned to the %0d-byte data bus", awaddr, STRB_WIDTH));

    a_araddr_aligned :
    assert property (
      @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !check_addr_alignment)
        (arvalid === 1'b1) |-> (araddr[ADDR_LSB-1:0] === '0)
    )
    else
      protocol_error("ARADDR_ALIGN", $sformatf(
                     "ARADDR 0x%0h is not aligned to the %0d-byte data bus", araddr, STRB_WIDTH));
  end : g_alignment

  // ---- Handshake signals must never be X/Z once out of reset: an X on
  // a VALID or a READY makes the whole handshake meaningless.
  property p_awvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        awvalid
    );
  endproperty
  a_awvalid_known :
  assert property (p_awvalid_known)
  else protocol_error("AWVALID_X", "AWVALID is X/Z out of reset");

  property p_awready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        awready
    );
  endproperty
  a_awready_known :
  assert property (p_awready_known)
  else protocol_error("AWREADY_X", "AWREADY is X/Z out of reset");

  property p_wvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        wvalid
    );
  endproperty
  a_wvalid_known :
  assert property (p_wvalid_known)
  else protocol_error("WVALID_X", "WVALID is X/Z out of reset");

  property p_wready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        wready
    );
  endproperty
  a_wready_known :
  assert property (p_wready_known)
  else protocol_error("WREADY_X", "WREADY is X/Z out of reset");

  property p_bvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        bvalid
    );
  endproperty
  a_bvalid_known :
  assert property (p_bvalid_known)
  else protocol_error("BVALID_X", "BVALID is X/Z out of reset");

  property p_bready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        bready
    );
  endproperty
  a_bready_known :
  assert property (p_bready_known)
  else protocol_error("BREADY_X", "BREADY is X/Z out of reset");

  property p_arvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        arvalid
    );
  endproperty
  a_arvalid_known :
  assert property (p_arvalid_known)
  else protocol_error("ARVALID_X", "ARVALID is X/Z out of reset");

  property p_arready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        arready
    );
  endproperty
  a_arready_known :
  assert property (p_arready_known)
  else protocol_error("ARREADY_X", "ARREADY is X/Z out of reset");

  property p_rvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        rvalid
    );
  endproperty
  a_rvalid_known :
  assert property (p_rvalid_known)
  else protocol_error("RVALID_X", "RVALID is X/Z out of reset");

  property p_rready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(
        rready
    );
  endproperty
  a_rready_known :
  assert property (p_rready_known)
  else protocol_error("RREADY_X", "RREADY is X/Z out of reset");

  // ---- Payload must be known whenever a transfer is offered. WDATA is
  // checked only on the byte lanes WSTRB enables: AXI leaves the write
  // data of a disabled lane explicitly undefined, so checking it would
  // manufacture failures.
  property p_awaddr_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (awvalid === 1'b1) |-> !$isunknown(
        awaddr
    );
  endproperty
  a_awaddr_known :
  assert property (p_awaddr_known)
  else protocol_error("AWADDR_X", "AWADDR is X/Z while AWVALID is asserted");

  property p_awprot_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_prot)
      (awvalid === 1'b1) |-> !$isunknown(
        awprot
    );
  endproperty
  a_awprot_known :
  assert property (p_awprot_known)
  else protocol_error("AWPROT_X", "AWPROT is X/Z while AWVALID is asserted");

  property p_wstrb_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (wvalid === 1'b1) |-> !$isunknown(
        wstrb
    );
  endproperty
  a_wstrb_known :
  assert property (p_wstrb_known)
  else protocol_error("WSTRB_X", "WSTRB is X/Z while WVALID is asserted");

  property p_araddr_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (arvalid === 1'b1) |-> !$isunknown(
        araddr
    );
  endproperty
  a_araddr_known :
  assert property (p_araddr_known)
  else protocol_error("ARADDR_X", "ARADDR is X/Z while ARVALID is asserted");

  property p_arprot_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_prot)
      (arvalid === 1'b1) |-> !$isunknown(
        arprot
    );
  endproperty
  a_arprot_known :
  assert property (p_arprot_known)
  else protocol_error("ARPROT_X", "ARPROT is X/Z while ARVALID is asserted");

  property p_bresp_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (bvalid === 1'b1) |-> !$isunknown(
        bresp
    );
  endproperty
  a_bresp_known :
  assert property (p_bresp_known)
  else protocol_error("BRESP_X", "BRESP is X/Z while BVALID is asserted");

  property p_rresp_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (rvalid === 1'b1) |-> !$isunknown(
        rresp
    );
  endproperty
  a_rresp_known :
  assert property (p_rresp_known)
  else protocol_error("RRESP_X", "RRESP is X/Z while RVALID is asserted");

  // RDATA has no strobe: every bit of a read is meaningful, so all of it
  // must be driven.
  property p_rdata_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (rvalid === 1'b1) |-> !$isunknown(
        rdata
    );
  endproperty
  a_rdata_known :
  assert property (p_rdata_known)
  else protocol_error("RDATA_X", "RDATA is X/Z while RVALID is asserted");

  // One assertion per byte lane, so an X only fails where WSTRB says the
  // byte is actually being written.
  for (genvar b = 0; b < STRB_WIDTH; b++) begin : g_wdata_known
    a_wdata_known :
    assert property (
      @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
        (wvalid === 1'b1 && wstrb[b] === 1'b1) |-> !$isunknown(
        wdata[b*8+:8]
    ))
    else protocol_error("WDATA_X", $sformatf("WDATA byte %0d is X/Z but WSTRB enables it", b));
  end : g_wdata_known

`endif  // AXI_LITE_IF_SIM

endinterface : axi_lite_if
