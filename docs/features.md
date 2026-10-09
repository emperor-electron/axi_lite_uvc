# Features

What the UVC gives you, and why each piece is shaped the way it is.

## One interface file, synthesizable and verification both

`src/axi_lite_if.sv` is the UVC's virtual interface *and* an interface you can
instantiate inside a design. There is no second copy to keep in step.

Everything a synthesis tool would reject — clocking blocks, assertions, the
handshake counters, the string and `%m` reporting helpers — lives inside
`` `ifdef AXI_LITE_IF_SIM ``. What is left outside is the signal set and two
DUT-facing modports:

```systemverilog
axi_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cfg (.aclk(clk), .aresetn(rstn));
my_cpu    u_cpu  (.m_axil(cfg.dut_master));
my_periph u_regs (.s_axil(cfg.dut_slave));
```

The guard is derived automatically:

```systemverilog
`ifndef AXI_LITE_IF_SIM
  `ifdef XILINX_SIMULATOR
    `define AXI_LITE_IF_SIM
  `endif
`endif
```

`XILINX_SIMULATOR` is predefined by `xvlog`/`xelab` and *not* by Vivado
synthesis, so neither flow needs anything on the command line. On another
simulator, ask for it explicitly with `+define+AXI_LITE_IF_SIM`.

The `ifndef` comes first deliberately: an explicit `+define+` on any other tool
wins over the auto-derivation.

This has been checked in both directions — the interface synthesizes clean for
`xc7z045`, and forcing `AXI_LITE_IF_SIM` on during synthesis makes it fail
(`ERROR: [Synth 8-27] string type not supported`), which is what proves the
guard is actually load-bearing rather than decorative.

## Parameterized, not `define`-d

Address and data widths are SystemVerilog **parameters**, never compile-time
macros, so one compilation can hold as many differently sized ports as it likes:

```systemverilog
axi_lite_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) regs (aclk, aresetn);
axi_lite_if #(.ADDR_WIDTH(64), .DATA_WIDTH(64)) host (aclk, aresetn);
```

The self-test elaborates five geometries into one snapshot — 32/32, 32/64,
64/64, 12/32 and 16/64 — and drives all of them in a single run.

AXI4-Lite fixes the data bus at 32 or 64 bits. A width outside that still
elaborates, because narrow control buses are common in practice, but says so at
time 0 rather than quietly claiming to be AMBA.

## Only what touches an interface is parameterized

This is the design decision the rest of the UVC follows from.

| Parameterized by width | Not parameterized |
| --- | --- |
| `axi_lite_if` | `axi_lite_seq_item` |
| `axi_lite_master_driver` | `axi_lite_config` |
| `axi_lite_slave_driver` | `axi_lite_sequencer` |
| `axi_lite_monitor` | `axi_lite_mem` |
| `axi_lite_agent` | `axi_lite_ready_policy` |
| | `axi_lite_coverage` |
| | the whole sequence library |

The transaction holds its address and data in vectors sized to the widest legal
link (64 bits) and masks them down to the real width, which it learns from the
config at randomize time. Because the transaction is unparameterized, so is the
sequencer; because the sequencer is unparameterized, a test can hold every
port's sequencer in one plain queue and start the same sequence on all of them:

```systemverilog
axi_lite_sequencer sequencers[$];   // 32-bit, 64-bit, 12-bit address -- all of them
foreach (sequencers[i]) fork
  automatic int k = i;
  begin
    axi_lite_random_seq s = axi_lite_random_seq::type_id::create("s");
    void'(s.randomize());
    s.start(sequencers[k]);
  end
join_none
```

One sequence library serves every port geometry in your testbench. One coverage
model aggregates across all of them, with bus width as a coverpoint rather than
baked into the type.

## Either end of the link

| `role` | The agent | Needs |
| --- | --- | --- |
| `AXI_LITE_MASTER` | issues reads and writes into a DUT's **slave** port and takes responses back | a sequencer and stimulus |
| `AXI_LITE_SLAVE` | accepts requests from a DUT's **master** port and answers them | an `axi_lite_mem`, no stimulus |

The two are not symmetric, and the asymmetry is real rather than incidental: a
master is told what to do by sequences, a slave's whole behaviour is its config
and its memory model. A slave agent therefore has no sequencer at all.

Both roles build a monitor, and the monitor publishes regardless of role — so a
`UVM_PASSIVE` agent on a link you do not drive still feeds your scoreboard and
your coverage.

## Programmable backpressure on all five channels

AXI4-Lite's five channels handshake independently, so each is throttled
independently. Which channels an agent drives follows from its role:

- `AXI_LITE_MASTER` drives `BREADY` and `RREADY` — the responses it accepts
- `AXI_LITE_SLAVE` drives `AWREADY`, `WREADY` and `ARREADY` — the requests it accepts

Six built-in models:

| Mode | Behaviour |
| --- | --- |
| `AXI_LITE_READY_ALWAYS` | READY tied high — no backpressure (the default) |
| `AXI_LITE_READY_NEVER` | READY tied low — the channel never accepts |
| `AXI_LITE_READY_RANDOM` | independent per-cycle coin flip at `.percent()` |
| `AXI_LITE_READY_DUTY` | deterministic square wave, `.ready_cycles()` / `.stall_cycles()` |
| `AXI_LITE_READY_BURST` | accept `.burst_beats()` transfers, then stall `.stall_cycles()` |
| `AXI_LITE_READY_DELAY` | hold off `.delay_min()`…`.delay_max()` cycles after VALID |

For anything these do not cover, extend `axi_lite_ready_policy`, override one
function, and hand it over. The drivers only ever talk to the base class:

```systemverilog
class every_third_ready extends axi_lite_ready_policy;
  local int unsigned n;
  function bit next_ready(bit valid, bit accepted);
    n = (n + 1) % 3;
    return (n == 0);
  endfunction
  function void reset(); n = 0; endfunction
endclass
```

Because the policy class carries no width parameter, one custom model works on
every port in your testbench. Policies are read every cycle, so swapping one
mid-run takes effect immediately.

Details and arguments: [Configuration › Backpressure](configuration.md#backpressure-per-channel).

## A slave that answers like a real peripheral

`axi_lite_mem` is a sparse byte store — an associative array keyed by byte
address, not by word — so a byte-strobed write updates exactly the lanes WSTRB
enables without any mask reconstruction at some assumed word width. That is what
keeps the class unparameterized and what makes a 32-bit write and a 64-bit write
to overlapping addresses behave the way real memory does.

On top of the store:

- **Response regions.** `add_region(lo, hi, AXI_LITE_DECERR, "unmapped")` makes
  an address range answer with an error. A later `AXI_LITE_OKAY` region carves an
  explicit hole in a broader error region.
- **Backdoor access.** `peek_byte()` / `poke_byte()` preload or inspect without
  generating bus traffic.
- **Fill policy.** An unwritten byte reads back as `default_byte`, or — with
  `fill_from_address` set — as `addr[7:0] ^ 8'hA5`, which makes an address
  decoded onto the wrong location obvious in a waveform.
- **Four virtual hooks.** Override `resp_for_read`, `resp_for_write`, `do_read`
  and `do_write` and you have a modelled peripheral with side effects, not just
  a memory.

```systemverilog
class my_periph_mem extends axi_lite_mem;
  function void do_write(axi_lite_addr_t addr, axi_lite_data_t data,
                         axi_lite_strb_t strb, int unsigned num_bytes);
    super.do_write(addr, data, strb, num_bytes);
    if (addr == 64'h20) fire_interrupt();   // write-1-to-clear, a FIFO push, ...
  endfunction
endclass
```

## Assertions that are themselves tested

The interface carries **49 concurrent assertions** covering handshake stability,
reset behaviour, response ordering and legal encodings. They police the UVC and
the DUT equally — whichever side drives the signal that breaks a rule is the
side the failure points at.

The part worth noticing is that they are themselves tested.
`tb/axi_lite_if_check_tb.sv` is a non-UVM testbench that commits 17 deliberate
protocol violations and requires each one to be caught:

```bash
cd tb && make check-protocol
```

An assertion nobody has ever seen fail is a claim, not a check. Full list:
[Checks and coverage](checks-and-coverage.md).

## Register maps by name, generated from Corsair

A DUT with a register map can be driven by name rather than by address:

```systemverilog
field_write_enum("CTRL", "MODE", "STREAM", resp);
field_check("STATUS", "ERRCODE", CSR_STATUS_ERRCODE_NONE);
```

`axi_lite_reg_model` holds registers, fields, access modes and enumerated values;
`axi_lite_reg_seq` adds the named access tasks on top of the ordinary sequence
library. Both are unparameterized, so one map works against a 32-bit link and a
64-bit one.

The map is generated from the [Corsair](https://github.com/esynr3z/corsair)
register map you already have — `tools/corsair_uvc_gen.py` reads the same
`regs.json` Corsair reads — or built from Corsair's exported SystemVerilog
parameters through the macros in `src/axi_lite_corsair.svh`.

### The part that is not syntax sugar

Writing one field of a register by reading it, substituting and writing it back
is wrong on most of the access modes a real map contains, and wrong in a way that
succeeds. Hardware raises `IRQ.DONE` and `IRQ.ERROR`; a test clears `DONE`; a
read-modify-write reads `0b11`, writes `0b11` back, and clears both. The write is
accepted, the response is `OKAY`, and an interrupt is gone.

Because the map carries the access mode, `field_write()` picks between four
strategies:

| Strategy | When | Cost |
| --- | --- | --- |
| `MODAL` | `rw1c`/`rw1s`/`rw1t`/`wosc` — a written 0 means "leave alone" | 1 write |
| `STROBE` | the field exactly fills whole byte lanes | 1 write |
| `RMW` | readable, no read side effects, nothing modal | 1 read + 1 write |
| `SHADOW` | write-only and unaligned, or reading would change the DUT | 1 write |

`last_strategy` reports which was used, so "this write cost one bus access and no
read" is a property a test can assert on rather than hope for.

Full documentation: **[Register maps](register-maps.md)**.

## Pipelining, and the ability to turn it off

`max_outstanding` controls how many transactions the master driver may have in
flight. The default is **1** — each transaction completes before the next is
issued, which is what most AXI4-Lite peripherals expect and what makes a
scoreboard's job unambiguous.

Raise it to exercise a slave that claims to pipeline. The master driver's
dispatch thread calls `item_done()` as soon as a transaction is accepted rather
than when it completes, so sequences keep feeding it while responses are still
outstanding.

Be aware of what you are buying: AXI4-Lite orders responses within a channel but
gives **no ordering at all between the read and write channels**. With more than
one transaction in flight, a read and a write to the same address can be served
in either order, and a scoreboard that assumes otherwise will report a bug that
is not there. See
[Troubleshooting](troubleshooting.md#a-read-disagrees-with-the-last-write-to-that-address).

## Independent address and write-data pacing

`set_addr_delay()` and `set_wdata_delay()` are separate on purpose. Because they
are independent, a write can present W **before** AW — which is legal AXI4-Lite
and a case plenty of slaves get wrong, usually by latching WDATA into a buffer
that AW is assumed to have already sized.

## Reset that actually resets

Both drivers run their threads inside a reset-isolation fork:

```systemverilog
fork
  begin : reset_scope
    fork
      cycle_counter(); dispatch_thread();
      aw_thread(); w_thread(); ar_thread(); b_thread(); r_thread();
      @(negedge vif.aresetn);
    join_any
    disable fork;
  end : reset_scope
join
```

A falling `ARESETn` kills every channel thread mid-transfer, drives idle, and
starts over. Anything in flight is marked `aborted` and released, so a sequence
blocked in `wait_done()` wakes up rather than hanging — a reset test that
deadlocks its own testbench tells you nothing.

The two ends of that are separate and both honest. The driver hands the
sequence its item back with `aborted = 1` and `has_response` still clear, so the
issuing sequence can tell "no answer because reset" from "no answer because the
DUT hung". The monitor, which never saw a response either, discards its
partially assembled transactions and says how many with a `RESET_FLUSH` warning
rather than publishing halves of them to your scoreboard.

## Two analysis ports, not one

| Port | Publishes | Use it for |
| --- | --- | --- |
| `request_analysis_port` | a **clone** of the transaction the moment it is fully requested (AW+W seen, or AR seen) | checking what went *into* a DUT, feeding a reference model early |
| `item_analysis_port` | the completed transaction, at the B or R handshake | scoreboarding, coverage — this is the one you usually want |

The monitor samples all five channels in one ordered loop per clock edge —
requests first, then responses — so two channels handshaking on the same edge
cannot race each other into different orders on different runs.

## Where to go next

- [Configuration](configuration.md) — every knob, with defaults
- [Stimulus](stimulus.md) — the sequence library and writing your own
- [Checks and coverage](checks-and-coverage.md) — the assertion list and the coverage model
