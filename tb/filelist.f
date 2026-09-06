// ---------------------------------------------------------------------
// The self-test only. The UVC itself comes from
// $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f, which the Makefile passes to
// xvlog alongside this file -- so a local `make` compiles the UVC
// through exactly the drop-in filelist a project reusing it would use.
//
// Paths are relative to this directory, which is where make runs.
// ---------------------------------------------------------------------
-i .

axi_lite_chan_fifo.sv
axi_lite_reg_slice.sv
axi_lite_tb_ctrl_if.sv
axi_lite_link.sv
axi_lite_tb_pkg.sv
axi_lite_tb_top.sv
axi_lite_if_check_tb.sv
