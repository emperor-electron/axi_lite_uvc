// ---------------------------------------------------------------------
// The example testbench only. The UVC itself comes from
// $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f, which the Makefile passes to
// xvlog alongside this file -- exactly how your own project should pull
// it in.
//
// Paths are relative to this directory, which is where make runs.
// ---------------------------------------------------------------------
-i .

example_dut.sv
example_tb_pkg.sv
example_tb_top.sv
