///////////////////////////////////////////////////////////////////
// Filename: axi_lite_coverage.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Functional coverage subscriber for the AXI4-Lite UVC.
//           Answers "did this run actually exercise the protocol?" --
//           reads against writes, response codes, strobe patterns,
//           protection attributes, and above all how much backpressure
//           and latency the port really saw.
///////////////////////////////////////////////////////////////////
//
// Unparameterized, like every other analysis-side class here, so one
// coverage model aggregates across ports of different widths. Bus width
// is covered as a coverpoint instead of being baked into the type,
// which is what makes "did we exercise 64-bit ports?" a coverage
// question rather than a compile-time one.
//
// It subscribes to the *completed* transaction stream, not the request
// stream: a coverage model that counted requests would report a run as
// well covered even if the DUT never answered any of them.

class axi_lite_coverage extends uvm_subscriber #(axi_lite_seq_item);

  `uvm_component_utils(axi_lite_coverage)

  axi_lite_config agent_config;

  // Sampled fields, reduced to scalars a covergroup can bin.
  local axi_lite_kind_e cov_kind;
  local axi_lite_resp_e cov_resp;
  local int unsigned    cov_data_width;
  local int unsigned    cov_addr_width;
  local bit [2:0]       cov_prot;
  local int unsigned    cov_latency;
  local int unsigned    cov_addr_stall;
  local int unsigned    cov_resp_stall;

  // How much of the data bus a write actually enabled, reduced to a
  // width-independent category so one bin set covers a 4-byte and an
  // 8-byte bus alike. Bin ranges have to be constants, and a bus's byte
  // count is not one.
  typedef enum { STRB_NONE, STRB_SINGLE, STRB_PARTIAL, STRB_FULL } strobe_e;
  local strobe_e cov_strobe;

  // Where in the configured address window the access landed, in
  // eighths. Again a category rather than a raw address, so a 4 KB
  // aperture and a 16-byte one produce comparable bins.
  local int unsigned cov_addr_bucket;

  covergroup cg_transaction;
    option.per_instance = 1;
    option.name         = "axi_lite_transaction_cg";

    cp_kind : coverpoint cov_kind;

    // EXOKAY is not an illegal_bin on purpose. The interface already
    // asserts that it never appears, and one loud failure from the
    // assertion is more useful than a second, less specific one from
    // the coverage engine -- especially in a directed negative test that
    // drives it deliberately.
    cp_resp : coverpoint cov_resp {
      bins okay   = {AXI_LITE_OKAY};
      bins slverr = {AXI_LITE_SLVERR};
      bins decerr = {AXI_LITE_DECERR};
      bins exokay = {AXI_LITE_EXOKAY};
    }

    // The two widths AXI4-Lite defines, plus a catch-all so a narrower
    // local bus still lands somewhere visible.
    cp_data_width : coverpoint cov_data_width {
      bins w32   = {32};
      bins w64   = {64};
      bins other = default;
    }

    cp_addr_width : coverpoint cov_addr_width {
      bins narrow = {[1:16]};     // a peripheral's own aperture
      bins w32    = {32};
      bins w64    = {64};
      bins other  = default;
    }

    // Write strobes, sampled only on writes. The `iff` matters: without
    // it every read would land in some strobe bin and the numbers would
    // say the strobe space was well covered when only half the traffic
    // could contribute to it at all.
    //
    // A zero-strobe write is legal AXI and writes nothing, which is a
    // case register files get wrong often enough to be worth its own bin.
    cp_strobe : coverpoint cov_strobe iff (cov_kind == AXI_LITE_WRITE) {
      bins none    = {STRB_NONE};
      bins single  = {STRB_SINGLE};
      bins partial = {STRB_PARTIAL};
      bins full    = {STRB_FULL};
    }

    // AxPROT, as the three independent attributes it actually is.
    cp_privileged  : coverpoint cov_prot[0];
    cp_nonsecure   : coverpoint cov_prot[1];
    cp_instruction : coverpoint cov_prot[2];

    // How long the whole transaction took, end to end. The point of a
    // programmable slave delay and of response backpressure is to fill
    // the upper bins here.
    cp_latency : coverpoint cov_latency {
      bins immediate = {[0:2]};
      bins quick     = {[3:8]};
      bins slow      = {[9:32]};
      bins very_slow = {[33:255]};
      bins glacial   = {[256:$]};
    }

    // Backpressure actually experienced, split by where it happened:
    // a slave that is slow to accept and a master that is slow to take
    // its answer are different bugs.
    cp_addr_stall : coverpoint cov_addr_stall {
      bins none      = {0};
      bins short_[3] = {[1:3]};
      bins mid       = {[4:15]};
      bins long_     = {[16:$]};
    }

    cp_resp_stall : coverpoint cov_resp_stall {
      bins none      = {0};
      bins short_[3] = {[1:3]};
      bins mid       = {[4:15]};
      bins long_     = {[16:$]};
    }

    cp_addr_bucket : coverpoint cov_addr_bucket {
      bins b[8] = {[0:7]};
    }

    // The combinations that matter. An errored read and an errored write
    // take different paths through a slave, and a stalled error response
    // is the corner both of them share.
    x_kind_resp        : cross cp_kind, cp_resp;
    x_kind_stall       : cross cp_kind, cp_addr_stall;
    x_width_kind       : cross cp_data_width, cp_kind;
    x_resp_stall_resp  : cross cp_resp, cp_resp_stall;
    // Strobe patterns only mean anything on a write, and cp_strobe's own
    // `iff` already sees to that -- but the cross needs the reads
    // excluded explicitly too, or it carries a row of permanently empty
    // read bins that can never be filled.
    x_kind_strobe      : cross cp_kind, cp_strobe {
      ignore_bins reads = binsof(cp_kind) intersect {AXI_LITE_READ};
    }
  endgroup : cg_transaction

  extern function new(string name = "axi_lite_coverage", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void write(axi_lite_seq_item t);

  // Which eighth of the configured window this address falls in.
  extern protected virtual function int unsigned addr_bucket(axi_lite_addr_t addr);

endclass : axi_lite_coverage

function axi_lite_coverage::new(string name = "axi_lite_coverage", uvm_component parent = null);
  super.new(name, parent);
  cg_transaction = new();
endfunction : new

function void axi_lite_coverage::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(axi_lite_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_lite_config set in the config DB")
endfunction : build_phase

function int unsigned axi_lite_coverage::addr_bucket(axi_lite_addr_t addr);
  axi_lite_addr_t lo = agent_config.addr_lo;
  axi_lite_addr_t hi = agent_config.addr_hi;
  axi_lite_addr_t span;
  axi_lite_addr_t bucket_size;

  if ((addr < lo) || (hi <= lo))
    return 0;

  // Scaled by dividing rather than multiplying: the obvious
  // (addr - lo) * 8 / span overflows on a window anywhere near the top
  // of a 64-bit address space, and the bucket only has to be roughly
  // right. Rounding the bucket size up keeps the top of the window in
  // bucket 7 rather than spilling into a ninth.
  span        = hi - lo + 1;
  bucket_size = (span + 7) / 8;
  return int'((addr - lo) / bucket_size) % 8;
endfunction : addr_bucket

// The formal is named `t` because uvm_subscriber#(T) declares it that
// way; renaming it here would make this an overload that never gets
// called rather than an override. `item` below is a local alias, purely
// so the body reads as it should.
function void axi_lite_coverage::write(axi_lite_seq_item t);
  axi_lite_seq_item item = t;
  int unsigned strobed;

  if (!agent_config.coverage_enable)
    return;

  cov_kind        = item.kind;
  cov_resp        = item.resp;
  cov_data_width  = item.data_width;
  cov_addr_width  = item.addr_width;
  cov_prot        = item.prot;
  cov_latency     = item.latency_cycles;
  cov_addr_stall  = item.addr_stall_cycles;
  cov_resp_stall  = item.resp_stall_cycles;
  cov_addr_bucket = addr_bucket(item.addr);

  // Only meaningful on a write; cp_strobe's `iff` is what stops a read's
  // value from being counted, so what it is set to here does not matter.
  strobed = item.num_strobed_bytes();
  if      (strobed == 0)                cov_strobe = STRB_NONE;
  else if (strobed == 1)                cov_strobe = STRB_SINGLE;
  else if (strobed == item.num_bytes()) cov_strobe = STRB_FULL;
  else                                  cov_strobe = STRB_PARTIAL;

  cg_transaction.sample();
endfunction : write
