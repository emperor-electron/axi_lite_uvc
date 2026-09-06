///////////////////////////////////////////////////////////////////
// Filename: axi_lite_ready_policy.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Programmable backpressure models for the AXI4-Lite UVC: a
//           base policy class defining the one-call-per-cycle READY
//           contract, and a default implementation covering the common
//           always/never/random/duty/burst/delay shapes.
///////////////////////////////////////////////////////////////////
//
// AXI4-Lite has five independent VALID/READY channels, and each one can
// be backpressured on its own. That is why this class is per *channel*
// rather than per agent: a master agent installs a policy on B and R
// (the responses it accepts), a slave agent installs one on AW, W and
// AR (the requests it accepts), and axi_lite_config keeps one handle per
// channel so they can differ.
//
// A driver calls next_ready() exactly once per ACLK edge for each
// channel it owns, and drives whatever it returns for the following
// cycle. Deciding READY one cycle ahead is what keeps the model honest:
// it cannot peek at the VALID it is about to answer, so no policy -- not
// even a user's -- can accidentally create the combinational
// READY-from-VALID path that makes a testbench pass a design that would
// deadlock in silicon.
//
// READY has no protocol restrictions of its own: either side may assert,
// deassert, or hold it at any time, so every policy here is legal by
// construction. Only VALID has stability rules to obey.
//
// To build a model these do not cover -- replaying a trace, following a
// credit counter, stalling only writes to one address region -- extend
// axi_lite_ready_policy, override next_ready(), and hand it to
// axi_lite_config::set_ready_policy(). The policy is deliberately not
// parameterized by bus width, so one custom model works against every
// link in the testbench.

virtual class axi_lite_ready_policy extends uvm_object;

  extern function new(string name = "axi_lite_ready_policy");

  // Decide the READY value for the *next* cycle on one channel.
  //   valid    - this channel's VALID sampled at this edge
  //   accepted - a transfer completed on this channel at this edge
  pure virtual function bit next_ready(bit valid, bit accepted);

  // Called whenever ARESETn asserts, so a stateful policy can restart
  // from a known point rather than resuming mid-pattern.
  extern virtual function void reset();

endclass : axi_lite_ready_policy

function axi_lite_ready_policy::new(string name = "axi_lite_ready_policy");
  super.new(name);
endfunction : new

function void axi_lite_ready_policy::reset();
  // Nothing to do for a stateless policy.
endfunction : reset


///////////////////////////////////////////////////////////////////
// The built-in models. All knobs are rand, so a test can randomize a
// whole backpressure profile in one go:
//
//   assert (policy.randomize() with { mode inside {AXI_LITE_READY_RANDOM,
//                                                  AXI_LITE_READY_BURST};
//                                     ready_percent inside {[20:80]}; });
///////////////////////////////////////////////////////////////////
class axi_lite_default_ready_policy extends axi_lite_ready_policy;

  rand axi_lite_ready_mode_e mode;

  // AXI_LITE_READY_RANDOM: chance, in percent, that READY is high in any
  // given cycle. 100 degenerates to ALWAYS, 0 to NEVER.
  rand int unsigned ready_percent;

  // AXI_LITE_READY_DUTY: ready_cycles high then stall_cycles low, forever.
  // AXI_LITE_READY_BURST reuses stall_cycles as the length of its stall.
  rand int unsigned ready_cycles;
  rand int unsigned stall_cycles;

  // AXI_LITE_READY_BURST: transfers accepted before stalling.
  rand int unsigned burst_beats;

  // AXI_LITE_READY_DELAY: cycles to hold READY low after VALID appears,
  // re-drawn for every transfer.
  rand int unsigned delay_min;
  rand int unsigned delay_max;

  constraint c_percent { ready_percent inside {[0:100]}; }
  constraint c_cycles  { ready_cycles inside {[1:16]};
                         stall_cycles inside {[1:16]}; }
  constraint c_burst   { burst_beats  inside {[1:32]}; }
  constraint c_delay   { delay_min <= delay_max;
                         delay_max inside {[0:16]}; }

  `uvm_object_utils(axi_lite_default_ready_policy)

  // Pattern state.
  local bit          m_phase_ready;    // AXI_LITE_READY_DUTY: in the high phase?
  local int unsigned m_phase_count;    // cycles spent in the current phase
  local int unsigned m_beats;          // AXI_LITE_READY_BURST: beats this burst
  local bit          m_stalling;       // AXI_LITE_READY_BURST: in the stall
  local bit          m_armed;          // AXI_LITE_READY_DELAY: target drawn?
  local int unsigned m_delay_target;   // AXI_LITE_READY_DELAY: cycles to wait
  local int unsigned m_delay_count;

  extern function new(string name = "axi_lite_default_ready_policy");
  extern virtual function bit next_ready(bit valid, bit accepted);
  extern virtual function void reset();
  extern virtual function string convert2string();

  extern local function bit next_duty();
  extern local function bit next_burst(bit accepted);
  extern local function bit next_delay(bit valid, bit accepted);

endclass : axi_lite_default_ready_policy

function axi_lite_default_ready_policy::new(string name = "axi_lite_default_ready_policy");
  super.new(name);
  // Defaults chosen so a freshly constructed policy applies no
  // backpressure: a UVC that has not been told to throttle should not
  // silently start throttling.
  mode          = AXI_LITE_READY_ALWAYS;
  ready_percent = 50;
  ready_cycles  = 1;
  stall_cycles  = 1;
  burst_beats   = 4;
  delay_min     = 0;
  delay_max     = 4;
  reset();
endfunction : new

function void axi_lite_default_ready_policy::reset();
  m_phase_ready  = 1'b1;
  m_phase_count  = 0;
  m_beats        = 0;
  m_stalling     = 1'b0;
  m_armed        = 1'b0;
  m_delay_target = 0;
  m_delay_count  = 0;
endfunction : reset

function bit axi_lite_default_ready_policy::next_ready(bit valid, bit accepted);
  case (mode)
    AXI_LITE_READY_ALWAYS : return 1'b1;
    AXI_LITE_READY_NEVER  : return 1'b0;
    AXI_LITE_READY_RANDOM : return ($urandom_range(99, 0) < ready_percent);
    AXI_LITE_READY_DUTY   : return next_duty();
    AXI_LITE_READY_BURST  : return next_burst(accepted);
    AXI_LITE_READY_DELAY  : return next_delay(valid, accepted);
    default               : return 1'b1;
  endcase
endfunction : next_ready

// A free-running square wave, independent of traffic: ready_cycles high,
// stall_cycles low. Useful for reproducing a fixed-rate acceptor (a
// register file behind a clock crossing, say) exactly the same way on
// every seed.
function bit axi_lite_default_ready_policy::next_duty();
  bit value = m_phase_ready;
  m_phase_count++;
  if (m_phase_ready && (m_phase_count >= ready_cycles)) begin
    m_phase_ready = 1'b0;
    m_phase_count = 0;
  end
  else if (!m_phase_ready && (m_phase_count >= stall_cycles)) begin
    m_phase_ready = 1'b1;
    m_phase_count = 0;
  end
  return value;
endfunction : next_duty

// Traffic-driven rather than time-driven: count *accepted transfers*,
// not cycles, then shut the channel for stall_cycles. This is the model
// that finds outstanding-transaction bugs, because the stall always
// lands after a known number of transfers no matter how the other side
// paced them.
function bit axi_lite_default_ready_policy::next_burst(bit accepted);
  if (accepted)
    m_beats++;

  if (m_stalling) begin
    m_phase_count++;
    if (m_phase_count >= stall_cycles) begin
      m_stalling    = 1'b0;
      m_phase_count = 0;
      m_beats       = 0;
      return 1'b1;
    end
    return 1'b0;
  end

  if (m_beats >= burst_beats) begin
    m_stalling    = 1'b1;
    m_phase_count = 0;
    return 1'b0;
  end
  return 1'b1;
endfunction : next_burst

// Hold READY low for a freshly drawn delay every time a transfer is
// offered, which exercises the "VALID before READY" handshake ordering
// that both sides must tolerate. The counter only advances while VALID
// is asserted, so the delay measures real stall, not idle time.
function bit axi_lite_default_ready_policy::next_delay(bit valid, bit accepted);
  if (accepted)
    m_armed = 1'b0;

  if (!m_armed) begin
    m_delay_target = $urandom_range(delay_max, delay_min);
    m_delay_count  = 0;
    m_armed        = 1'b1;
  end

  if (!valid)
    return (m_delay_target == 0);

  if (m_delay_count >= m_delay_target)
    return 1'b1;

  m_delay_count++;
  return 1'b0;
endfunction : next_delay

function string axi_lite_default_ready_policy::convert2string();
  case (mode)
    AXI_LITE_READY_RANDOM : return $sformatf("%s(%0d%%)", mode.name(), ready_percent);
    AXI_LITE_READY_DUTY   : return $sformatf("%s(%0d on/%0d off)", mode.name(), ready_cycles, stall_cycles);
    AXI_LITE_READY_BURST  : return $sformatf("%s(%0d xfers/%0d stall)", mode.name(), burst_beats, stall_cycles);
    AXI_LITE_READY_DELAY  : return $sformatf("%s(%0d..%0d)", mode.name(), delay_min, delay_max);
    default               : return mode.name();
  endcase
endfunction : convert2string
