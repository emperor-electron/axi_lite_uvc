// ---------------------------------------------------------------------
// The reusable AXI4-Lite UVC, and nothing else.
//
// Add this filelist to another testbench's compile to pull the UVC in.
// Simulators resolve filelist entries relative to the directory the
// compiler runs in, not to the filelist, so the paths below are anchored
// on an environment variable that you point at this repository:
//
//   export AXI_LITE_UVC_ROOT=/path/to/axi_lite
//   xvlog -sv -L uvm -f $AXI_LITE_UVC_ROOT/src/axi_lite_uvc.f -f my_tb.f
//
// -i puts the UVC's source directory on the `include search path, which
// is how axi_lite_pkg.sv finds the class files it includes.
//
// Nothing here depends on anything outside these two files except UVM.
// ---------------------------------------------------------------------
-i $AXI_LITE_UVC_ROOT/src

$AXI_LITE_UVC_ROOT/src/axi_lite_if.sv
$AXI_LITE_UVC_ROOT/src/axi_lite_pkg.sv
