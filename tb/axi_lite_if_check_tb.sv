///////////////////////////////////////////////////////////////////
// Filename: axi_lite_if_check_tb.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Negative test for the interface's protocol assertions.
//           Drives deliberately illegal AXI4-Lite activity and fails
//           unless every rule catches its own violation.
///////////////////////////////////////////////////////////////////
//
// The UVC's own tests all pass, which says nothing on its own: a checker
// that never fires passes everything. This testbench exists to show the
// checkers are alive, one rule at a time, by breaking each rule on
// purpose and requiring the interface to notice -- and, just as
// important, by driving legal activity that looks suspicious and
// requiring it to stay quiet.
//
// Deliberately plain SystemVerilog with no UVM in it. It drives the
// interface's signals directly, which is exactly what a broken master or
// slave would do, and reads protocol_error_count to see what was caught.
// That also demonstrates the interface is usable outside UVM.
//
// Signals move on the falling edge of ACLK throughout, so every change
// is unambiguously before or after the rising edge the assertions sample
// on.

`timescale 1ns/1ps

module axi_lite_if_check_tb;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  always #(5ns) aclk = ~aclk;

  // 32-bit address and data, so ADDR_LSB is 2 and the alignment rule has
  // bits to check.
  axi_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) u (.aclk(aclk), .aresetn(aresetn));

  int unsigned checks_run    = 0;
  int unsigned checks_passed = 0;
  int unsigned base;

  task automatic idle();
    u.awvalid <= 1'b0;
    u.awaddr  <= '0;
    u.awprot  <= 3'b000;
    u.wvalid  <= 1'b0;
    u.wdata   <= '0;
    u.wstrb   <= '0;
    u.bvalid  <= 1'b0;
    u.bresp   <= 2'b00;
    u.arvalid <= 1'b0;
    u.araddr  <= '0;
    u.arprot  <= 3'b000;
    u.rvalid  <= 1'b0;
    u.rdata   <= '0;
    u.rresp   <= 2'b00;
    u.awready <= 1'b0;
    u.wready  <= 1'b0;
    u.bready  <= 1'b0;
    u.arready <= 1'b0;
    u.rready  <= 1'b0;
  endtask

  task automatic reset_link();
    @(negedge aclk);
    aresetn <= 1'b0;
    idle();
    repeat (3) @(negedge aclk);
    aresetn <= 1'b1;
    repeat (2) @(negedge aclk);
  endtask

  // A scenario that breaks a rule must be caught.
  task automatic expect_caught(string what, int unsigned base_count);
    checks_run++;
    if (u.protocol_error_count > base_count) begin
      checks_passed++;
      $display("  [ok]     %-40s caught  (%0d violation(s), last rule %s)",
               what, u.protocol_error_count - base_count, u.last_protocol_error_rule);
    end
    else begin
      $display("  [MISSED] %-40s NOT caught -- this checker is dead", what);
    end
  endtask

  // ...and a scenario that breaks nothing must not be.
  task automatic expect_quiet(string what, int unsigned base_count);
    checks_run++;
    if (u.protocol_error_count == base_count) begin
      checks_passed++;
      $display("  [ok]     %-40s clean", what);
    end
    else begin
      $display("  [FALSE]  %-40s reported %0d violation(s) on legal activity (last rule %s)",
               what, u.protocol_error_count - base_count, u.last_protocol_error_rule);
    end
  endtask

  // A complete, legal write: address and data offered, both accepted,
  // then a response. Used to give the ordering checks something real to
  // count before the scenarios that abuse them.
  task automatic legal_write(logic [31:0] addr, logic [31:0] data);
    @(negedge aclk);
    u.awaddr  <= addr;
    u.awvalid <= 1'b1;
    u.wdata   <= data;
    u.wstrb   <= 4'hF;
    u.wvalid  <= 1'b1;
    u.awready <= 1'b1;
    u.wready  <= 1'b1;
    @(negedge aclk);
    u.awvalid <= 1'b0;
    u.wvalid  <= 1'b0;
    u.awready <= 1'b0;
    u.wready  <= 1'b0;
    u.bresp   <= 2'b00;
    u.bvalid  <= 1'b1;
    u.bready  <= 1'b1;
    @(negedge aclk);
    u.bvalid  <= 1'b0;
    u.bready  <= 1'b0;
    @(negedge aclk);
  endtask

  initial begin
    $display("============================================================");
    $display(" AXI4-Lite interface protocol-checker self-test");
    $display("============================================================");

    // --- Legal activity must stay quiet -------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awaddr  <= 32'h0000_0010;
    u.awvalid <= 1'b1;
    u.wdata   <= 32'hA5A5_1234;
    u.wstrb   <= 4'hF;
    u.wvalid  <= 1'b1;
    repeat (3) @(negedge aclk);       // stalled, payload held steady
    u.awready <= 1'b1;
    u.wready  <= 1'b1;
    @(negedge aclk);                  // both handshake
    u.awvalid <= 1'b0;
    u.wvalid  <= 1'b0;
    u.awready <= 1'b0;
    u.wready  <= 1'b0;
    u.bvalid  <= 1'b1;
    u.bready  <= 1'b1;
    @(negedge aclk);
    u.bvalid  <= 1'b0;
    u.bready  <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_quiet("legal stalled write", base);

    // --- AWVALID withdrawn before AWREADY answered --------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awaddr  <= 32'h0000_0020;
    u.awvalid <= 1'b1;
    repeat (2) @(negedge aclk);
    u.awvalid <= 1'b0;                // never handshook
    repeat (2) @(negedge aclk);
    expect_caught("AWVALID withdrawn before handshake", base);

    // --- AWADDR changed mid-stall -------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awaddr  <= 32'h0000_0040;
    u.awvalid <= 1'b1;
    @(negedge aclk);
    u.awaddr  <= 32'h0000_0080;       // AWREADY still low
    @(negedge aclk);
    u.awready <= 1'b1;                // then complete it legally
    @(negedge aclk);
    u.awvalid <= 1'b0;
    u.awready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("AWADDR changed while stalled", base);

    // --- WDATA changed mid-stall --------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.wdata  <= 32'hAAAA_AAAA;
    u.wstrb  <= 4'hF;
    u.wvalid <= 1'b1;
    @(negedge aclk);
    u.wdata  <= 32'hBBBB_BBBB;        // WREADY still low
    @(negedge aclk);
    u.wready <= 1'b1;
    @(negedge aclk);
    u.wvalid <= 1'b0;
    u.wready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("WDATA changed while stalled", base);

    // --- RVALID withdrawn before RREADY answered ----------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.arvalid <= 1'b1;
    u.arready <= 1'b1;                // accept the address, so R is owed
    @(negedge aclk);
    u.arvalid <= 1'b0;
    u.arready <= 1'b0;
    u.rdata   <= 32'h1234_5678;
    u.rvalid  <= 1'b1;
    repeat (2) @(negedge aclk);
    u.rvalid  <= 1'b0;                // never handshook
    repeat (2) @(negedge aclk);
    expect_caught("RVALID withdrawn before handshake", base);

    // --- An unaligned address on a 4-byte bus -------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.araddr  <= 32'h0000_0002;       // not a multiple of 4
    u.arvalid <= 1'b1;
    u.arready <= 1'b1;
    @(negedge aclk);
    u.arvalid <= 1'b0;
    u.arready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_caught("unaligned ARADDR on a 4-byte bus", base);

    // --- ...and the same address with the rule switched off -----------
    reset_link();
    u.check_addr_alignment = 1'b0;
    base = u.protocol_error_count;
    @(negedge aclk);
    u.araddr  <= 32'h0000_0002;
    u.arvalid <= 1'b1;
    u.arready <= 1'b1;
    @(negedge aclk);
    u.arvalid <= 1'b0;
    u.arready <= 1'b0;
    // The read address was accepted, so answer it rather than leaving an
    // orphan for the next scenario to trip over.
    u.rvalid  <= 1'b1;
    u.rready  <= 1'b1;
    @(negedge aclk);
    u.rvalid  <= 1'b0;
    u.rready  <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_quiet("unaligned ARADDR, alignment check off", base);
    u.check_addr_alignment = 1'b1;

    // --- EXOKAY, which AXI4-Lite does not define ----------------------
    reset_link();
    legal_write(32'h0000_0000, 32'hDEAD_BEEF);   // so the B is owed
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awvalid <= 1'b1;
    u.wvalid  <= 1'b1;
    u.wstrb   <= 4'hF;
    u.awready <= 1'b1;
    u.wready  <= 1'b1;
    @(negedge aclk);
    u.awvalid <= 1'b0;
    u.wvalid  <= 1'b0;
    u.awready <= 1'b0;
    u.wready  <= 1'b0;
    u.bresp   <= 2'b01;               // EXOKAY
    u.bvalid  <= 1'b1;
    u.bready  <= 1'b1;
    @(negedge aclk);
    u.bvalid  <= 1'b0;
    u.bready  <= 1'b0;
    u.bresp   <= 2'b00;
    repeat (2) @(negedge aclk);
    expect_caught("BRESP = EXOKAY", base);

    // --- A write response for a write nobody asked for ----------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.bresp  <= 2'b00;
    u.bvalid <= 1'b1;
    u.bready <= 1'b1;                 // no AW and no W have happened
    @(negedge aclk);
    u.bvalid <= 1'b0;
    u.bready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("BVALID with no write requested", base);

    // --- Read data for a read nobody asked for ------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.rdata  <= 32'h0000_0001;
    u.rvalid <= 1'b1;
    u.rready <= 1'b1;                 // no AR has happened
    @(negedge aclk);
    u.rvalid <= 1'b0;
    u.rready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("RVALID with no read requested", base);

    // --- A write response before the write data arrived ---------------
    // The address was accepted but the data never was, so the slave
    // cannot possibly know what to write.
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awvalid <= 1'b1;
    u.awready <= 1'b1;
    @(negedge aclk);
    u.awvalid <= 1'b0;
    u.awready <= 1'b0;
    u.bvalid  <= 1'b1;
    u.bready  <= 1'b1;
    @(negedge aclk);
    u.bvalid  <= 1'b0;
    u.bready  <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("BVALID before the write data arrived", base);

    // --- AWVALID held high through reset ------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awvalid <= 1'b1;
    u.awaddr  <= 32'h0F0F_0F0C;
    @(negedge aclk);
    aresetn   <= 1'b0;                // AWVALID never dropped
    repeat (4) @(negedge aclk);
    u.awvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("AWVALID asserted during reset", base);

    // --- ARVALID already high on the first edge after reset release ---
    @(negedge aclk);
    aresetn   <= 1'b0;
    idle();
    repeat (3) @(negedge aclk);
    base = u.protocol_error_count;
    u.arvalid <= 1'b1;                // asserted on the release edge itself
    aresetn   <= 1'b1;
    repeat (3) @(negedge aclk);
    u.arvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("ARVALID high as reset released", base);

    // --- X on a handshake signal --------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awvalid <= 1'bx;
    repeat (2) @(negedge aclk);
    u.awvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("AWVALID unknown out of reset", base);

    // --- X in a byte WSTRB enables ------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.wdata  <= 32'hxxxx_0000;        // upper bytes X, WSTRB says they count
    u.wstrb  <= 4'b1111;
    u.wvalid <= 1'b1;
    u.wready <= 1'b1;
    @(negedge aclk);
    u.wvalid <= 1'b0;
    u.wready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_caught("X in a byte WSTRB enables", base);

    // --- X in a byte WSTRB disables is legal and must stay quiet -------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.wdata  <= 32'hxxxx_0000;        // same X, but now those lanes are off
    u.wstrb  <= 4'b0011;
    u.wvalid <= 1'b1;
    u.wready <= 1'b1;
    @(negedge aclk);
    u.wvalid <= 1'b0;
    u.wready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_quiet("X in a byte WSTRB disables (legal)", base);

    // --- Checks can be switched off for a directed negative test ------
    reset_link();
    u.checks_enable = 1'b0;
    base = u.protocol_error_count;
    @(negedge aclk);
    u.awvalid <= 1'b1;
    u.awaddr  <= 32'h3333_3330;
    repeat (2) @(negedge aclk);
    u.awvalid <= 1'b0;                // same violation as scenario 2
    repeat (2) @(negedge aclk);
    expect_quiet("violation with checks_enable=0", base);
    u.checks_enable = 1'b1;

    $display("------------------------------------------------------------");
    $display(" checker self-test: %0d of %0d scenarios behaved correctly",
             checks_passed, checks_run);
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: axi_lite_if  |  top: axi_lite_if_check_tb");
    $display(" test    : axi_lite_if_check_tb");
    $display(" result  : %s", (checks_passed == checks_run) ? "PASSED" : "FAILED");
    $display(" fatals=0 errors=%0d warnings=0", checks_run - checks_passed);
    $display("============================================================");
    $finish;
  end

endmodule : axi_lite_if_check_tb
