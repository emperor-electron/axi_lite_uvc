// ---------------------------------------------------------------------
// The Corsair example testbench. The UVC itself comes from
// $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f, which the Makefile passes to
// xvlog alongside this file.
//
// The first three entries are generated -- `make regs` produces them
// from regs.json -- and are listed before the testbench package because
// it imports them.
// ---------------------------------------------------------------------
-i .

corsair_example_regs.v
corsair_example_reg_pkg.sv

// corsair_example_regs_pkg.sv -- Corsair's own SystemVerilogPackage
// export -- is deliberately NOT compiled: v1.0.4 emits illegal enum
// literals in it (see corsair_example_tb_pkg.sv). The generated package
// above carries the same constants, correctly sized.

corsair_example_hw_if.sv
corsair_example_tb_pkg.sv
corsair_example_tb_top.sv
