///////////////////////////////////////////////////////////////////
// Filename: axi_lite_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : The reusable AXI4-Lite UVC: transaction, config,
//           backpressure policies, slave memory model, sequencer,
//           master/slave drivers, monitor, coverage, agent and sequence
//           library.
///////////////////////////////////////////////////////////////////
//
// This package plus axi_lite_if.sv (together, axi_lite_uvc.f) is the
// whole verification component. Drop those two files into another
// testbench's compile and you have it -- nothing else in this repository
// is needed, and nothing here depends on anything outside it but UVM.
//
// Include order below is dependency order, not alphabetical: each file
// only names types declared above it.

package axi_lite_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Enumerations, typedefs and the capacity constants for the
  // unparameterized transaction fields.
  `include "axi_lite_types.sv"

  // Programmable backpressure: the policy contract and its built-ins.
  `include "axi_lite_ready_policy.sv"

  // What a slave agent answers with: storage, response regions, hooks.
  `include "axi_lite_mem.sv"

  // The DUT's register map by name: registers, bit fields, access modes
  // and enumerated values. Included before the config because the config
  // carries a handle to one.
  `include "axi_lite_reg_model.sv"

  // Per-agent configuration: role, geometry, address window, pacing,
  // backpressure, the memory model.
  `include "axi_lite_config.sv"

  // The transaction: one whole read or write.
  `include "axi_lite_seq_item.sv"

  // Components. The four that touch a virtual interface are
  // parameterized by the port's widths; everything else is not.
  `include "axi_lite_sequencer.sv"
  `include "axi_lite_master_driver.sv"
  `include "axi_lite_slave_driver.sv"
  `include "axi_lite_monitor.sv"
  `include "axi_lite_coverage.sv"
  `include "axi_lite_agent.sv"

  // Stimulus.
  `include "axi_lite_seq_lib.sv"

  // Named register and bit-field access, built on the sequence library.
  `include "axi_lite_reg_seq.sv"

endpackage : axi_lite_pkg
