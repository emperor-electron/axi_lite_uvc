# Configuration

`axi_lite_config` is where nearly all of the UVC's behaviour is decided. One
config object per agent; build it in the test rather than the env so a derived
test can adjust it before the agent is created.

```systemverilog
axi_lite_config cfg = axi_lite_config::type_id::create("cfg");
cfg.role = AXI_LITE_MASTER;
cfg.set_addr_window(12'h000, 12'h03F);
uvm_config_db#(axi_lite_config)::set(this, "env.master_agent", "agent_config", cfg);
```

The agent expects it under the field name `"agent_config"`, and passes it down
to its own children itself.

## Role and activity

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `role` | `axi_lite_role_e` | `AXI_LITE_MASTER` | `AXI_LITE_MASTER` drives a DUT's slave port and issues transactions. `AXI_LITE_SLAVE` drives a DUT's master port and answers them. |
| `is_active` | `uvm_active_passive_enum` | `UVM_ACTIVE` | `UVM_PASSIVE` builds only the monitor (and coverage). Use it to observe a link something else drives. |

The agent lets the config win over `uvm_agent`'s own `is_active`, so the two
views cannot disagree.

A passive agent still monitors, checks and covers. That is often what you want
on a link between two DUT blocks.

## Geometry

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `addr_width` | `int unsigned` | `0` | 0 means "not stated" — the agent fills it in from its own parameters. |
| `data_width` | `int unsigned` | `0` | Likewise. |
| `has_prot` | `bit` | `1` | Whether AWPROT/ARPROT are real on this link. Clear it for a DUT that ties them off: the master then drives zeros and the interface stops checking them. |

```systemverilog
function void set_geometry(int unsigned addr_width, int unsigned data_width);
function int unsigned bytes_per_beat();      // width of WSTRB
function axi_lite_addr_t addr_align_mask();  // the alignment every legal address satisfies
```

**You normally leave the widths alone.** The agent reconciles them against its
own type parameters at build time: silence means "adopt the parameters",
disagreement produces a `GEOMETRY` warning and the parameters win. A config
cannot contradict the interface it is attached to, so setting these by hand
only matters when you are building a config with no agent in sight.

## Address window

| Field | Type | Default |
| --- | --- | --- |
| `addr_lo` | `axi_lite_addr_t` | `'0` |
| `addr_hi` | `axi_lite_addr_t` | `64'hFF` |

```systemverilog
function void set_addr_window(axi_lite_addr_t lo, axi_lite_addr_t hi);
```

Every sequence in the library draws its addresses from this window and aligns
them to the bus width automatically, so no sequence ever has to be told the
register map. Every DUT has a decoded aperture and driving outside it is a
decode error rather than stimulus — which is why the window is configuration,
not a per-sequence argument.

Widening it past the DUT's aperture is how you test the error path on purpose:
[`example_decerr_test`](../example/example_base_test.sv) doubles the window so
roughly half of all traffic lands where nothing is decoded, and requires DECERR
back rather than merely tolerating it.

The window shapes *random* stimulus only. A directed `write()`/`read()` goes
exactly where it is told, window or no window — probing an unmapped address is a
test, not a mistake.

If the window reaches past what `ADDR_WIDTH` can address, the agent clamps it
and warns. Sequences would otherwise be asked for addresses the DUT could never
see, which is a silent hole in your stimulus.

## Master-side pacing

| Field | Type | Default |
| --- | --- | --- |
| `min_addr_delay` / `max_addr_delay` | `int unsigned` | `0` / `0` |
| `min_wdata_delay` / `max_wdata_delay` | `int unsigned` | `0` / `0` |
| `max_outstanding` | `int unsigned` | `1` |

```systemverilog
function void set_addr_delay (int unsigned min_cycles, int unsigned max_cycles);
function void set_wdata_delay(int unsigned min_cycles, int unsigned max_cycles);
```

Each transaction draws an `addr_delay` — idle ACLK cycles before its address
phase is offered — and a `wdata_delay` for its write data phase. **The two are
independent**, which is what lets a write present W before AW. That is legal
AXI4-Lite and a case plenty of slaves get wrong; with both ranges left at 0/0
you will never generate it.

`max_outstanding` is how many transactions the master driver may have in flight
at once. 1 means each completes before the next is issued. Raise it to exercise
a slave that claims to pipeline — and read
[Troubleshooting](troubleshooting.md#a-read-disagrees-with-the-last-write-to-that-address)
first, because AXI4-Lite gives no ordering between the read and write channels
and a scoreboard that assumes otherwise will report a bug that is not there.

## Slave-side answering

| Field | Type | Default |
| --- | --- | --- |
| `min_resp_delay` / `max_resp_delay` | `int unsigned` | `0` / `0` |
| `mem` | `axi_lite_mem` | `null` |

```systemverilog
function void set_resp_delay(int unsigned min_cycles, int unsigned max_cycles);
```

`resp_delay` is the gap between the slave agent having everything it needs to
answer and asserting BVALID/RVALID. 0/0 answers as early as legally possible.

Left null, `mem` is filled in with a plain zero-filled `axi_lite_mem` by the
slave driver. Share one handle between two slave agents to give them a common
memory.

## The DUT's register map

| Field | Type | Default |
| --- | --- | --- |
| `reg_model` | `axi_lite_reg_model` | `null` |

```systemverilog
cfg.reg_model = my_periph_reg_model::type_id::create("reg_model");
```

Attaching a map is what lets a sequence address the DUT by register and field
name instead of by address. Every sequence extending `axi_lite_reg_seq` picks it
up through its sequencer, so a test sets it once here.

Left null, only address-based access is available — the rest of the UVC does not
need it. Full documentation: **[Register maps](register-maps.md)**.

## Backpressure, per channel

```systemverilog
function void set_ready_mode(axi_lite_channel_e channel, axi_lite_ready_mode_e mode,
                             int unsigned percent      = 50,
                             int unsigned ready_cycles = 1,
                             int unsigned stall_cycles = 1,
                             int unsigned burst_beats  = 4,
                             int unsigned delay_min    = 0,
                             int unsigned delay_max    = 4);

function void set_ready_mode_all(axi_lite_ready_mode_e mode, ...);  // same arguments
function void set_ready_policy(axi_lite_channel_e channel, axi_lite_ready_policy policy);
function axi_lite_ready_policy get_ready_policy(axi_lite_channel_e channel);
```

Arguments not relevant to the chosen mode are ignored, so name the ones you mean:

```systemverilog
cfg.set_ready_mode(AXI_LITE_CH_B,  AXI_LITE_READY_RANDOM, .percent(70));
cfg.set_ready_mode(AXI_LITE_CH_R,  AXI_LITE_READY_BURST, .burst_beats(4), .stall_cycles(6));
cfg.set_ready_mode(AXI_LITE_CH_AW, AXI_LITE_READY_DUTY, .ready_cycles(2), .stall_cycles(3));
```

| Mode | Arguments it uses | Behaviour |
| --- | --- | --- |
| `AXI_LITE_READY_ALWAYS` | — | READY tied high. No backpressure. **The default** for any channel you never mention. |
| `AXI_LITE_READY_NEVER` | — | READY tied low. The channel never accepts. |
| `AXI_LITE_READY_RANDOM` | `percent` | Independent per-cycle coin flip. |
| `AXI_LITE_READY_DUTY` | `ready_cycles`, `stall_cycles` | Deterministic square wave, free-running. |
| `AXI_LITE_READY_BURST` | `burst_beats`, `stall_cycles` | Accept N transfers, then stall. Counts *transfers*, not cycles, so the stall always lands after a known amount of traffic however the DUT paced it. |
| `AXI_LITE_READY_DELAY` | `delay_min`, `delay_max` | Hold off a drawn number of cycles after VALID rises, then accept. |

Which channels an agent actually drives follows from its role:

| Role | Drives READY on |
| --- | --- |
| `AXI_LITE_MASTER` | `AXI_LITE_CH_B`, `AXI_LITE_CH_R` |
| `AXI_LITE_SLAVE` | `AXI_LITE_CH_AW`, `AXI_LITE_CH_W`, `AXI_LITE_CH_AR` |

A policy set on a channel this agent does not own is simply unused, so
`set_ready_mode_all()` is safe on either role.

A channel with no policy installed gets `AXI_LITE_READY_ALWAYS`: a UVC that has
not been told to throttle should not silently start throttling.

`AXI_LITE_READY_BURST` is the model that finds "slave assumes the master is
always ready" bugs, because the stall arrives after a fixed number of accepted
transfers rather than at a random moment.

### Writing your own

Extend `axi_lite_ready_policy` and override one function. The drivers only ever
talk to the base class, and it carries no width parameter, so one custom model
works on every port in your testbench:

```systemverilog
class ready_after_two_stalls extends axi_lite_ready_policy;
  `uvm_object_utils(ready_after_two_stalls)
  local int unsigned m_waited;

  function new(string name = "ready_after_two_stalls"); super.new(name); endfunction

  // Decide READY for the NEXT cycle. Called once per ACLK edge:
  //   valid    - this channel's VALID sampled at this edge
  //   accepted - a transfer completed on this channel at this edge
  virtual function bit next_ready(bit valid, bit accepted);
    if (!valid)  begin m_waited = 0; return 1'b0; end
    if (accepted) begin m_waited = 0; return 1'b0; end
    m_waited++;
    return (m_waited > 2);
  endfunction

  virtual function void reset(); m_waited = 0; endfunction
endclass
```

`reset()` is called whenever ARESETn asserts, so a stateful policy restarts from
a known point rather than resuming mid-pattern.

The drivers call `get_ready_policy()` every cycle, so a test can swap a model
mid-run and have it take effect on the next edge.

Every knob on the built-in `axi_lite_default_ready_policy` is `rand`, so a test
can randomize a whole backpressure profile in one go:

```systemverilog
axi_lite_default_ready_policy policy = axi_lite_default_ready_policy::type_id::create("policy");
assert (policy.randomize() with { mode inside {AXI_LITE_READY_RANDOM, AXI_LITE_READY_BURST};
                                  ready_percent inside {[20:80]}; });
cfg.set_ready_policy(AXI_LITE_CH_R, policy);
```

## The slave memory model

`axi_lite_mem` is a sparse **byte** store — an associative array keyed by byte
address — which is what lets a byte-strobed write update exactly the lanes WSTRB
enables, and what keeps the class free of any width parameter.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default_byte` | `byte unsigned` | `8'h00` | What an untouched byte reads back as. |
| `fill_from_address` | `bit` | `0` | When set, an untouched byte reads as `addr[7:0] ^ 8'hA5` instead. Makes a mis-decoded address obvious in a waveform. |
| `num_reads` / `num_writes` | `int unsigned` | `0` | Access census. |

```systemverilog
// Response regions
function void add_region(axi_lite_addr_t lo, axi_lite_addr_t hi,
                         axi_lite_resp_e resp, string region_name = "");
function void clear_regions();

// Backdoor -- no bus traffic
function byte unsigned peek_byte(axi_lite_addr_t addr);
function void          poke_byte(axi_lite_addr_t addr, byte unsigned value);
function int unsigned  num_bytes_written();

// The four hooks a peripheral model overrides
virtual function axi_lite_resp_e resp_for_read (axi_lite_addr_t addr, axi_lite_prot_t prot);
virtual function axi_lite_resp_e resp_for_write(axi_lite_addr_t addr, axi_lite_prot_t prot);
virtual function axi_lite_data_t do_read (axi_lite_addr_t addr, int unsigned num_bytes);
virtual function void            do_write(axi_lite_addr_t addr, axi_lite_data_t data,
                                          axi_lite_strb_t strb, int unsigned num_bytes);
```

Regions are searched in order, so a specific `AXI_LITE_OKAY` region added first
carves a hole in a broader error region added after it.

```systemverilog
axi_lite_mem mem = axi_lite_mem::type_id::create("mem");
mem.fill_from_address = 1'b1;
mem.add_region(64'h0100, 64'h01FF, AXI_LITE_OKAY,   "mailbox");   // hole
mem.add_region(64'h0000, 64'h0FFF, AXI_LITE_SLVERR, "reserved");  // everything else
cfg.mem = mem;
```

The `read()`/`write()` entry points the driver calls apply the response policy
*before* the access, so a DECERR read does not quietly return real data and a
DECERR write does not quietly land in the array.

Modelling a real peripheral means overriding the hooks:

```systemverilog
class my_periph_mem extends axi_lite_mem;
  `uvm_object_utils(my_periph_mem)
  function new(string name = "my_periph_mem"); super.new(name); endfunction

  virtual function axi_lite_resp_e resp_for_write(axi_lite_addr_t addr, axi_lite_prot_t prot);
    if (addr == 64'h00) return AXI_LITE_SLVERR;   // the ID register is read-only
    return super.resp_for_write(addr, prot);
  endfunction

  virtual function void do_write(axi_lite_addr_t addr, axi_lite_data_t data,
                                 axi_lite_strb_t strb, int unsigned num_bytes);
    super.do_write(addr, data, strb, num_bytes);
    if (addr == 64'h20) m_irq_pending &= ~data;   // write-1-to-clear
  endfunction
endclass
```

## Checks and instrumentation

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `protocol_checks_enable` | `bit` | `1` | Master switch for the interface's assertions. |
| `check_addr_alignment` | `bit` | `1` | Require AWADDR/ARADDR aligned to the data bus. Clear it for a DUT that deliberately decodes sub-word addresses. |
| `check_exokay` | `bit` | `1` | Flag EXOKAY on BRESP/RRESP — AXI4-Lite has no exclusive access, so it is out of spec wherever it appears. |
| `coverage_enable` | `bit` | `1` | Build the coverage subscriber. |
| `stall_timeout_cycles` | `int unsigned` | `0` | Error if a transfer stays offered (VALID high, READY low) this long on any channel. **0 disables it.** |

The agent pushes the first four into the interface in `end_of_elaboration_phase`,
before any driver or DUT has run.

`stall_timeout_cycles` defaults to off because a test may legitimately
backpressure forever (`AXI_LITE_READY_NEVER`). Switch it on — a few thousand
cycles is usually right — wherever the link is expected to keep moving. It turns
a hang into a diagnosable error with a channel name attached.

Clearing `protocol_checks_enable` should be rare and deliberate: it is for a
directed test driving stimulus that is illegal on purpose. Turning it off to
quieten a failure is turning off the thing that found the bug.

## Complete example

```systemverilog
// A master agent on a 4 KB peripheral aperture: bursty source, bursty sink,
// pipelined, with the deadlock watchdog armed.
master_config = axi_lite_config::type_id::create("master_config");
master_config.role     = AXI_LITE_MASTER;
master_config.has_prot = 1'b1;
master_config.set_addr_window(12'h000, 12'hFFF);
master_config.set_addr_delay (0, 5);
master_config.set_wdata_delay(0, 5);
master_config.set_ready_mode(AXI_LITE_CH_B, AXI_LITE_READY_BURST, .burst_beats(4), .stall_cycles(6));
master_config.set_ready_mode(AXI_LITE_CH_R, AXI_LITE_READY_BURST, .burst_beats(4), .stall_cycles(6));
master_config.max_outstanding      = 4;
master_config.stall_timeout_cycles = 2000;

// A slave agent answering a DUT's master port out of a modelled peripheral.
slave_config = axi_lite_config::type_id::create("slave_config");
slave_config.role = AXI_LITE_SLAVE;
slave_config.mem  = my_periph_mem::type_id::create("mem");
slave_config.mem.add_region(64'h1000, 64'hFFFF, AXI_LITE_DECERR, "unmapped");
slave_config.set_resp_delay(1, 4);
slave_config.set_ready_mode_all(AXI_LITE_READY_RANDOM, .percent(60));
slave_config.stall_timeout_cycles = 2000;
```

Next: **[Stimulus](stimulus.md)**.
