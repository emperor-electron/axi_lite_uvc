///////////////////////////////////////////////////////////////////
// Filename: axi_lite_config.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : Per-agent configuration for the AXI4-Lite UVC: which end of
//           the link the agent drives, how wide it is, which address
//           window its sequences use, how the master paces itself, how
//           the slave answers, and the backpressure model on each of the
//           five channels.
///////////////////////////////////////////////////////////////////
//
// This object is deliberately *not* parameterized. The bus widths live
// here as plain integers so that sequences, the scoreboard and any user
// code can be written once and reused against a 32-bit link and a
// 64-bit link in the same simulation. The agent cross-checks these
// numbers against its own type parameters at build time, so a config
// that disagrees with the interface it is attached to is a loud error
// rather than a silently truncated address.

class axi_lite_config extends uvm_object;

  // ---- Which end of the link, and whether we drive it at all ---------
  axi_lite_role_e role = AXI_LITE_MASTER;
  uvm_active_passive_enum is_active = UVM_ACTIVE;

  // ---- Bus geometry. Normally filled in by the agent from its own
  // parameters (see axi_lite_agent::adopt_interface_geometry), so a test
  // only has to set these when building a config by hand.
  // 0 means "not stated": the agent fills it in from its own parameters
  // without complaint. A non-zero value that disagrees with the agent is
  // reported, since that is a real contradiction rather than a default.
  int unsigned addr_width = 0;
  int unsigned data_width = 0;

  // Whether AWPROT/ARPROT are real on this link. Cleared for a DUT that
  // ties them off: the master then drives 0 and the interface stops
  // checking them.
  bit has_prot = 1'b1;

  // ---- Address window the sequence library draws from. Every DUT has a
  // decoded aperture and driving outside it is a decode error rather
  // than stimulus, so the window is configuration, not something each
  // sequence has to be told.
  axi_lite_addr_t addr_lo = '0;
  axi_lite_addr_t addr_hi = 64'h0000_0000_0000_00FF;

  // ---- Master-side pacing. Each transaction's `addr_delay` is the
  // number of idle ACLK cycles before its address phase is offered, and
  // `wdata_delay` the idle cycles before its write data phase. The two
  // are independent, which is what lets a write present W before AW --
  // legal AXI, and a case plenty of slaves get wrong.
  int unsigned min_addr_delay = 0;
  int unsigned max_addr_delay = 0;
  int unsigned min_wdata_delay = 0;
  int unsigned max_wdata_delay = 0;

  // How many transactions the master driver may have in flight at once.
  // 1 -- the default -- means each transaction completes before the next
  // is issued, which is what most AXI4-Lite peripherals expect and makes
  // a scoreboard's job unambiguous. Raise it to exercise a slave that
  // claims to pipeline.
  int unsigned max_outstanding = 1;

  // ---- Slave-side answering ------------------------------------------
  // Cycles between having everything needed to answer and asserting
  // BVALID/RVALID. 0..0 answers as early as legally possible.
  int unsigned min_resp_delay = 0;
  int unsigned max_resp_delay = 0;

  // The memory and response model the slave agent answers from. Left
  // null, the slave driver creates a plain zero-filled axi_lite_mem.
  // Share one handle between agents to give them a common memory.
  axi_lite_mem mem;

  // ---- Backpressure, per channel. Left empty, a channel gets an
  // AXI_LITE_READY_ALWAYS policy: a UVC that has not been told to
  // throttle should not silently start throttling.
  //
  // Which channels an agent actually drives follows from its role:
  //   AXI_LITE_MASTER drives B and R  (the responses it accepts)
  //   AXI_LITE_SLAVE  drives AW, W and AR (the requests it accepts)
  // A policy set on a channel this agent does not own is simply unused.
  protected axi_lite_ready_policy m_ready_policy[axi_lite_channel_e];

  // ---- Checks and instrumentation -----------------------------------
  // These three drive the interface's own variables of the same name;
  // clear them only to let a directed test drive deliberately illegal
  // stimulus.
  bit protocol_checks_enable = 1'b1;
  bit check_addr_alignment = 1'b1;
  bit check_exokay = 1'b1;
  bit coverage_enable = 1'b1;

  // Cycles a transfer may stay offered (VALID high, READY low) on any
  // channel before the monitor calls it a deadlock. 0 disables the
  // watchdog, which is the default because a test may legitimately
  // backpressure forever (AXI_LITE_READY_NEVER); switch it on wherever
  // the link is expected to keep moving.
  int unsigned stall_timeout_cycles = 0;

  `uvm_object_utils(axi_lite_config)

  extern function new(string name = "axi_lite_config");

  // ---- Geometry -----------------------------------------------------
  extern function void set_geometry(int unsigned addr_width, int unsigned data_width);
  // Bytes moved by one transfer, i.e. the width of WSTRB.
  extern function int unsigned bytes_per_beat();
  // The alignment every legal address has to satisfy.
  extern function axi_lite_addr_t addr_align_mask();

  // ---- Address window ------------------------------------------------
  extern function void set_addr_window(axi_lite_addr_t lo, axi_lite_addr_t hi);

  // ---- Backpressure --------------------------------------------------
  // Install a built-in model on one channel without constructing the
  // policy object by hand. Arguments not relevant to the chosen mode are
  // ignored.
  extern function void set_ready_mode(axi_lite_channel_e channel, axi_lite_ready_mode_e mode,
                                      int unsigned percent = 50, int unsigned ready_cycles = 1,
                                      int unsigned stall_cycles = 1, int unsigned burst_beats = 4,
                                      int unsigned delay_min = 0, int unsigned delay_max = 4);

  // The same model on every channel this agent drives.
  extern function void set_ready_mode_all(
      axi_lite_ready_mode_e mode, int unsigned percent = 50, int unsigned ready_cycles = 1,
      int unsigned stall_cycles = 1, int unsigned burst_beats = 4, int unsigned delay_min = 0,
      int unsigned delay_max = 4);

  // Hand over a policy of your own; see axi_lite_ready_policy.
  extern function void set_ready_policy(axi_lite_channel_e channel, axi_lite_ready_policy policy);

  // Null until something installs a policy. The drivers call this every
  // cycle, so a test can swap a model mid-run and have it take effect.
  extern function axi_lite_ready_policy get_ready_policy(axi_lite_channel_e channel);

  // ---- Pacing --------------------------------------------------------
  extern function void set_addr_delay(int unsigned min_cycles, int unsigned max_cycles);
  extern function void set_wdata_delay(int unsigned min_cycles, int unsigned max_cycles);
  extern function void set_resp_delay(int unsigned min_cycles, int unsigned max_cycles);

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function string convert2string();

endclass : axi_lite_config

function axi_lite_config::new(string name = "axi_lite_config");
  super.new(name);
endfunction : new

function void axi_lite_config::set_geometry(int unsigned addr_width, int unsigned data_width);
  this.addr_width = addr_width;
  this.data_width = data_width;
endfunction : set_geometry

function int unsigned axi_lite_config::bytes_per_beat();
  return (data_width == 0) ? 4 : (data_width / 8);
endfunction : bytes_per_beat

// The low address bits that must be zero, as a mask to AND away. A
// 4-byte bus masks off bits [1:0]; an 8-byte bus masks off [2:0].
function axi_lite_addr_t axi_lite_config::addr_align_mask();
  return ~axi_lite_addr_t'(bytes_per_beat() - 1);
endfunction : addr_align_mask

function void axi_lite_config::set_addr_window(axi_lite_addr_t lo, axi_lite_addr_t hi);
  addr_lo = lo;
  addr_hi = (hi < lo) ? lo : hi;
endfunction : set_addr_window

function void axi_lite_config::set_ready_mode(
    axi_lite_channel_e channel, axi_lite_ready_mode_e mode, int unsigned percent = 50,
    int unsigned ready_cycles = 1, int unsigned stall_cycles = 1, int unsigned burst_beats = 4,
    int unsigned delay_min = 0, int unsigned delay_max = 4);
  axi_lite_default_ready_policy policy;
  policy =
      axi_lite_default_ready_policy::type_id::create($sformatf("ready_policy_%s", channel.name()));
  policy.mode = mode;
  policy.ready_percent = percent;
  policy.ready_cycles = ready_cycles;
  policy.stall_cycles = stall_cycles;
  policy.burst_beats = burst_beats;
  policy.delay_min = delay_min;
  policy.delay_max = delay_max;
  m_ready_policy[channel] = policy;
endfunction : set_ready_mode

function void axi_lite_config::set_ready_mode_all(
    axi_lite_ready_mode_e mode, int unsigned percent = 50, int unsigned ready_cycles = 1,
    int unsigned stall_cycles = 1, int unsigned burst_beats = 4, int unsigned delay_min = 0,
    int unsigned delay_max = 4);
  // A separate policy object per channel, not one shared handle: the
  // stateful models (DUTY, BURST, DELAY) carry per-channel counters, and
  // sharing one would make AW's traffic advance W's pattern.
  axi_lite_channel_e channel;
  channel = channel.first();
  forever begin
    set_ready_mode(channel, mode, percent, ready_cycles, stall_cycles, burst_beats, delay_min,
                   delay_max);
    if (channel == channel.last()) break;
    channel = channel.next();
  end
endfunction : set_ready_mode_all

function void axi_lite_config::set_ready_policy(axi_lite_channel_e channel,
                                                axi_lite_ready_policy policy);
  m_ready_policy[channel] = policy;
endfunction : set_ready_policy

function axi_lite_ready_policy axi_lite_config::get_ready_policy(axi_lite_channel_e channel);
  return m_ready_policy.exists(channel) ? m_ready_policy[channel] : null;
endfunction : get_ready_policy

function void axi_lite_config::set_addr_delay(int unsigned min_cycles, int unsigned max_cycles);
  min_addr_delay = min_cycles;
  max_addr_delay = (max_cycles < min_cycles) ? min_cycles : max_cycles;
endfunction : set_addr_delay

function void axi_lite_config::set_wdata_delay(int unsigned min_cycles, int unsigned max_cycles);
  min_wdata_delay = min_cycles;
  max_wdata_delay = (max_cycles < min_cycles) ? min_cycles : max_cycles;
endfunction : set_wdata_delay

function void axi_lite_config::set_resp_delay(int unsigned min_cycles, int unsigned max_cycles);
  min_resp_delay = min_cycles;
  max_resp_delay = (max_cycles < min_cycles) ? min_cycles : max_cycles;
endfunction : set_resp_delay

function void axi_lite_config::do_copy(uvm_object rhs);
  axi_lite_config rhs_;
  if (rhs == null) `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs)) `uvm_fatal("DO_COPY", "cast of rhs to axi_lite_config failed")
  super.do_copy(rhs);
  role                   = rhs_.role;
  is_active              = rhs_.is_active;
  addr_width             = rhs_.addr_width;
  data_width             = rhs_.data_width;
  has_prot               = rhs_.has_prot;
  addr_lo                = rhs_.addr_lo;
  addr_hi                = rhs_.addr_hi;
  min_addr_delay         = rhs_.min_addr_delay;
  max_addr_delay         = rhs_.max_addr_delay;
  min_wdata_delay        = rhs_.min_wdata_delay;
  max_wdata_delay        = rhs_.max_wdata_delay;
  max_outstanding        = rhs_.max_outstanding;
  min_resp_delay         = rhs_.min_resp_delay;
  max_resp_delay         = rhs_.max_resp_delay;
  mem                    = rhs_.mem;
  m_ready_policy         = rhs_.m_ready_policy;
  protocol_checks_enable = rhs_.protocol_checks_enable;
  check_addr_alignment   = rhs_.check_addr_alignment;
  check_exokay           = rhs_.check_exokay;
  coverage_enable        = rhs_.coverage_enable;
  stall_timeout_cycles   = rhs_.stall_timeout_cycles;
endfunction : do_copy

function string axi_lite_config::convert2string();
  string backpressure = "";
  axi_lite_channel_e channel;
  channel = channel.first();
  forever begin
    axi_lite_ready_policy policy = get_ready_policy(channel);
    if (policy != null)
      backpressure = {
        backpressure,
        $sformatf(
            " %s=%s", axi_lite_short_name(channel.name(), 12), policy.convert2string()
        )
      };
    if (channel == channel.last()) break;
    channel = channel.next();
  end
  return $sformatf(
      "%s %s: ADDR=%0db DATA=%0db (%0dB/xfer) | window 0x%0h..0x%0h | outstanding<=%0d | addr_delay=%0d..%0d wdata_delay=%0d..%0d resp_delay=%0d..%0d | ready:%s",
      role.name(),
      is_active.name(),
      addr_width,
      data_width,
      bytes_per_beat(),
      addr_lo,
      addr_hi,
      max_outstanding,
      min_addr_delay,
      max_addr_delay,
      min_wdata_delay,
      max_wdata_delay,
      min_resp_delay,
      max_resp_delay,
      (backpressure == "") ? " (none configured)" : backpressure
  );
endfunction : convert2string
