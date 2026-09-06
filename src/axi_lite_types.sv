///////////////////////////////////////////////////////////////////
// Filename: axi_lite_types.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Shared enumerations, typedefs and capacity constants for the
//           AXI4-Lite UVC. Included first by axi_lite_pkg so every other
//           class in the UVC can name these types.
///////////////////////////////////////////////////////////////////

// Capacities for the *unparameterized* transaction fields. A sequence
// item has to be usable against a 32-bit link and a 64-bit link in the
// same simulation, so its address and data are held in vectors sized to
// the widest link AXI4-Lite allows and masked down to the link's real
// width.
//
// 64 is not an arbitrary ceiling: AXI4-Lite (IHI 0022, section B) fixes
// the data bus at 32 or 64 bits, so a wider transaction field could
// never describe a legal link.
parameter int AXI_LITE_MAX_ADDR_WIDTH = 64;
parameter int AXI_LITE_MAX_DATA_WIDTH = 64;
parameter int AXI_LITE_MAX_STRB_WIDTH = AXI_LITE_MAX_DATA_WIDTH / 8;

typedef bit [AXI_LITE_MAX_ADDR_WIDTH-1:0] axi_lite_addr_t;
typedef bit [AXI_LITE_MAX_DATA_WIDTH-1:0] axi_lite_data_t;
typedef bit [AXI_LITE_MAX_STRB_WIDTH-1:0] axi_lite_strb_t;

// AWPROT/ARPROT. The three bits are independent (IHI 0022 A4.7):
//   [0] 0 = unprivileged access, 1 = privileged
//   [1] 0 = secure access,       1 = non-secure
//   [2] 0 = data access,         1 = instruction access
typedef bit [2:0] axi_lite_prot_t;

// Which end of the link this agent owns. The two are not symmetric: a
// master agent issues transactions, a slave agent answers them and
// therefore needs a memory model to answer them from.
typedef enum {
  AXI_LITE_MASTER,  // drives a DUT's *slave* port  (issues transactions)
  AXI_LITE_SLAVE    // drives a DUT's *master* port (serves transactions)
} axi_lite_role_e;

// A transaction is one of exactly two shapes. AXI4-Lite has no bursts,
// so this is the whole taxonomy.
typedef enum bit {
  AXI_LITE_WRITE = 1'b0,   // AW + W, answered by B
  AXI_LITE_READ  = 1'b1    // AR,     answered by R
} axi_lite_kind_e;

// BRESP/RRESP encodings (IHI 0022 A3.4.4). EXOKAY is listed so a
// checker can name it when it appears: AXI4-Lite has no exclusive
// access, so a slave that returns it is out of spec.
typedef enum bit [1:0] {
  AXI_LITE_OKAY   = 2'b00,  // normal access success
  AXI_LITE_EXOKAY = 2'b01,  // exclusive access -- illegal in AXI4-Lite
  AXI_LITE_SLVERR = 2'b10,  // slave reached, but it reported an error
  AXI_LITE_DECERR = 2'b11   // no slave at that address (decode error)
} axi_lite_resp_e;

// The five independent channels. Every one of them is a VALID/READY
// handshake, which is why one backpressure policy type serves all of
// them -- the config keeps one policy per channel.
typedef enum {
  AXI_LITE_CH_AW,  // write address:  master VALID, slave READY
  AXI_LITE_CH_W,   // write data:     master VALID, slave READY
  AXI_LITE_CH_B,   // write response: slave  VALID, master READY
  AXI_LITE_CH_AR,  // read address:   master VALID, slave READY
  AXI_LITE_CH_R    // read data:      slave  VALID, master READY
} axi_lite_channel_e;

// Built-in backpressure models, selected through
// axi_lite_config::set_ready_mode() and implemented by
// axi_lite_default_ready_policy. For anything these do not cover,
// extend axi_lite_ready_policy and hand the object to the config --
// the drivers only ever talk to the base class.
typedef enum {
  AXI_LITE_READY_ALWAYS,  // READY tied high: no backpressure at all
  AXI_LITE_READY_NEVER,   // READY tied low: the channel never accepts
  AXI_LITE_READY_RANDOM,  // independent per-cycle coin flip, ready_percent
  AXI_LITE_READY_DUTY,    // deterministic square wave, ready_cycles / stall_cycles
  AXI_LITE_READY_BURST,   // accept burst_beats transfers, then stall stall_cycles
  AXI_LITE_READY_DELAY    // hold off delay_min..delay_max cycles after VALID
} axi_lite_ready_mode_e;

// One captured address phase and one captured write data phase. Kept
// small and plain: they exist only to hold a channel's payload between
// the cycle it was accepted off the wire and the cycle it can be acted
// on -- which on AXI4-Lite can be several, since AW and W arrive on
// unrelated schedules. The slave driver and the monitor both need them,
// so they live here rather than in whichever file happened to want them
// first.
typedef struct {
  axi_lite_addr_t addr;
  axi_lite_prot_t prot;
} axi_lite_addr_phase_t;

typedef struct {
  axi_lite_data_t data;
  axi_lite_strb_t strb;
} axi_lite_wdata_phase_t;

// Strip the "AXI_LITE_" (or "AXI_LITE_CH_") prefix off an enum's name(),
// so a log line reads "WRITE -> OKAY" rather than
// "AXI_LITE_WRITE -> AXI_LITE_OKAY".
//
// Taking the name as a *string argument* rather than writing
// `e.name().substr(...)` at each call site is a workaround, not a style
// choice. XSIM 2023.2's elaborator segfaults -- no error, no message,
// just SIGSEGV part-way through compiling the package -- on
// `e.name().substr(...)` where `e` is an enum variable being advanced by
// first()/next()/last() in the same loop. Either construct alone is
// fine; together they crash the tool. Materialising the name into a
// formal first avoids it entirely, and the length guard makes the helper
// safe for a name shorter than the prefix.
function automatic string axi_lite_short_name(string full, int unsigned prefix_len = 9);
  return (full.len() > prefix_len) ? full.substr(prefix_len, full.len() - 1) : full;
endfunction
