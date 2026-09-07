# Troubleshooting

Failure modes with non-obvious causes. Ordered roughly by how often they bite.

## `NOVIF` — no virtual interface in the config DB

```
UVM_FATAL ... [NOVIF] no virtual axi_lite_if #(32,32) set in the config DB for uvm_test_top.env.master_agent
```

Almost always a **type mismatch, not a missing set()**.
`virtual axi_lite_if #(12, 32)` and `virtual axi_lite_if #(32, 32)` are different
SystemVerilog types. A `uvm_config_db#(T)::set()` and a `get()` whose `T` differ
by one parameter do not warn — the `get()` returns 0 and the agent gives up.

Read the widths in the message: they are the agent's parameters, so they are what
the `set()` had to have used.

Check, in order:

1. The `set()` type parameters match the agent's exactly.
2. The field name matches — the agent asks for `"vif"`.
3. The scope reaches the agent. `set(null, "*", ...)` always does; a narrower
   path must name the agent's actual hierarchy.
4. The env forwarded it. The agent expects `"vif"` and `"agent_config"` under its
   own instance name; see [Getting started § 4](getting-started.md#4-the-env-one-agent-per-port).

The fix that makes it stop happening is in
[Getting started § 2](getting-started.md#2-write-the-widths-down-once): declare
the widths once and `typedef` the parameterized types.

## `NOCFG` — no config in the config DB

The sequencer and the agent both need `"agent_config"`. The agent builds a
default if none is provided (with a `CFG` info message) and hands it down; the
sequencer treats its absence as fatal because a sequence with no config would
randomize against a made-up geometry.

If you see this on the sequencer but not the agent, something is setting
`"agent_config"` at a scope that reaches one and not the other. Set it on the
agent and let the agent forward it.

## `GEOMETRY` warnings

```
config says DATA_WIDTH is 32 but this agent is parameterized for 64; using 64
```

You set `addr_width`/`data_width` on a config attached to an agent whose
parameters disagree. The parameters win, because a config cannot contradict the
interface it is attached to.

**Just don't set them.** They default to 0, meaning "not stated", and the agent
fills them in.

```
address window ends at 0x1FFFF but only 12 address bits exist; clamping to 0xFFF
```

The window reached past what `ADDR_WIDTH` can address. Sequences would have been
asked for addresses the DUT can never see — a silent hole in your stimulus, so it
is clamped and reported.

## A test hangs

**First, arm the watchdog.** `stall_timeout_cycles` defaults to 0 (off) because a
test may legitimately backpressure forever. Set it to a few thousand and rerun:

```systemverilog
cfg.stall_timeout_cycles = 2000;
```

You now get an error naming the channel that stopped moving, which turns a hang
into a five-minute problem.

Then, in likely order:

| Symptom | Cause |
| --- | --- |
| Nothing ever moves | A `AXI_LITE_READY_NEVER` policy left installed on a channel this agent drives. |
| Writes hang, reads work | The DUT is waiting for AW before it will take W, and both your delay ranges are 0/0 so it never sees the ordering it expects — or it genuinely cannot handle W-before-AW, which is the bug. |
| Sequence blocked in `wait_done()` | The transaction was never answered. Check the interface's `protocol_error_count` and the monitor's stall reports. |
| Hangs only with `max_outstanding > 1` | The DUT does not actually pipeline. Drop it back to 1 and see if the hang goes with it. |

A reset will not rescue a hang by accident: the drivers abort everything in
flight on `ARESETn` and release the sequences waiting on it, on purpose, so a
reset test cannot deadlock its own testbench.

## A test ends while a response is still in flight

Symptom: an intermittent error saying a response left the slave and never reached
the master, on some seeds only, usually with `max_outstanding > 1`.

Cause: a drain check written as "are all my queues empty?" There is a window
between a request reaching the DUT and its response coming back where **every
queue is legitimately empty** — so the check says "done", the phase ends, and the
response that arrives a few cycles later is reported as lost.

Fix: count outstanding transactions, not queued ones. Increment when a request is
observed, decrement when its response is, and make "idle" mean the counter is
zero *and* the queues are empty.

The self-test's scoreboard does this with a `num_outstanding` counter; this is a
bug it actually had.

## A read disagrees with the last write to that address

Symptom: `read 0x6c returned 0xcacbc8c9 but the last write there left 0xcacbc8ac`,
on some seeds only, with `max_outstanding > 1`.

**This is usually not a DUT bug.** AXI4-Lite orders responses within a channel
but gives **no ordering whatsoever between the read and write channels**. With
more than one transaction in flight, a read and a write to the same address may
be served in either order, and the master's completion order tells you nothing
about the slave's service order.

A scoreboard that compares every read against a shadow model will therefore
report a failure that is not one — and it will do it rarely enough to look like a
real intermittent bug.

Fix: track taint. A read is checkable only if **no write to its address was in
flight at any point during that read's life** — from when the read was issued to
when it completed, not merely at completion. Skip the comparison for tainted
reads and say how many you skipped.

In the self-test this costs 0–3 skipped reads out of 15–20 in the pipelined test;
every other read is still strictly checked. Checking at completion only was the
first attempt, and it was too narrow.

## Protocol assertions fire

```
axi_lite_tb_top.link_a.u_if: AXI4-Lite protocol violation [AWADDR_STABLE]: ...
```

The rule name is in the brackets, and the hierarchical path names the interface
instance. `vif.last_protocol_error_rule` holds the most recent one if you want it
programmatically.

The assertions watch the wires, so read the message before assuming it is the
DUT: whichever side drives the signal named is the side at fault.

Two failures usually mean a convention mismatch rather than a bug:

- **`AWADDR_ALIGN` / `ARADDR_ALIGN`** on a DUT that deliberately decodes sub-word
  addresses → `cfg.check_addr_alignment = 0`.
- **AxPROT-related noise** on a DUT that ties them off → `cfg.has_prot = 0`, and
  the master drives zeros and the checks stand down.

Everything else, investigate before switching off. `protocol_checks_enable = 0`
exists for directed tests driving deliberately illegal stimulus, not for triage.

## `randomize()` fails

**On a sequence:** the address window and the alignment have to be jointly
satisfiable. A window of `[0x001 : 0x00F]` on a 4-byte bus contains exactly three
legal addresses; a window of `[0x001 : 0x002]` contains none.

**On an item you built by hand:** it randomized against defaults because it was
created with `type_id::create()` instead of `new_item()`. `new_item()` stamps the
port's geometry onto the item; without it the constraints describe a small 32-bit
port that may have nothing to do with your link.

**On a directed access:** use `send()`. It turns off `c_window`, `c_alignment`
and `c_addr_width` for an address the caller chose deliberately, and warns about a
misaligned or too-wide address rather than handing you an unsolvable constraint
set. Probing outside the window is a legitimate test.

## A scoreboard or coverage subscriber never sees anything

If `write()` is never called on a subscriber that is definitely connected, check
the **name of its formal argument**:

```systemverilog
class my_scoreboard extends uvm_subscriber #(axi_lite_seq_item);
  virtual function void write(axi_lite_seq_item t);   // must be `t`
```

`uvm_subscriber #(T)` declares `write(T t)`. Naming your formal anything else —
`item`, `txn` — makes it an **overload rather than an override**, so the base
class's empty `write()` is what actually gets called and nothing reaches your
code. Some tools warn; not all of them do.

If you want a more descriptive name inside the body, alias it:

```systemverilog
virtual function void write(axi_lite_seq_item t);
  axi_lite_seq_item item = t;
  ...
```

`axi_lite_coverage` does exactly this, with a comment saying why.

## Coverage looks wrong

**Every read landed in a strobe bin.** `cp_strobe` is gated `iff (cov_kind ==
AXI_LITE_WRITE)` precisely so this cannot happen — if you have copied the
covergroup and dropped the `iff`, half your traffic is claiming coverage it
cannot contribute to.

**Everything is in address bucket 0.** The bucket divides the *configured window*
into eight, not the 64-bit address space: `(addr - lo) / ceil(span/8)`. A copy
that divides the raw address will put a 12-bit peripheral aperture entirely in
bucket 0.

## XSIM 2023.2 specifics

Only XSIM (Vivado 2023.2) has compiled this code. It miscompiles several pieces
of legal SystemVerilog in ways that produce no error message. If something here
behaves impossibly, suspect these before suspecting the code — all four are
commented at their source.

| Construct | What XSIM does | Workaround in this repo |
| --- | --- | --- |
| `enum.name().substr(...)` inside a loop advancing the same enum with `first()`/`next()`/`last()` | `xelab` dies with **SIGSEGV**, no message, part-way through the package | `axi_lite_short_name()` takes the name as a `string` formal, materialising it first |
| A conditional expression yielding an enum inside `randomize() with { }` | Evaluated wrongly — solved the read case to `WRITE` and called the write case unsatisfiable | Choose in procedural code into a variable of the enum's own type, then compare against it |
| Masking a wide `rand` field by constraint | `(x & ~mask) == 0` declared unsatisfiable; `(x >> width) == 0` solves but returns 0 on **every** draw | Trim in `post_randomize()` |
| Property formal arguments | Compile, then are **silently ignored** — assertions that look present and check nothing | One property per signal, written out longhand |

The masking one is worth dwelling on: neither failure appears on a 64-bit bus,
where the mask is all ones and the constraint is vacuous. It would have gone
unnoticed on the widest port while quietly breaking every narrow one.

## Synthesis rejects the interface

If Vivado synthesis complains about clocking blocks, assertions or
`ERROR: [Synth 8-27] string type not supported`, then `AXI_LITE_IF_SIM` is
defined during synthesis. It should be derived only from `XILINX_SIMULATOR`,
which synthesis does not set — so something is defining it explicitly, in a
`.xdc`, a global define, or a file included ahead of the interface.

The guard being load-bearing is verified in both directions: the interface
synthesizes clean for `xc7z045`, and forcing the macro on makes it fail with
exactly that error.

## A failing test reports success in CI

XSIM exits 0 after a `UVM_FATAL` — the test called `$finish`, it did not crash.
A script checking only the exit status will call a failing test a pass.

Both Makefiles grep the simulation log for the top module's own banner:

```
CHECK_PASS = ! grep -q '^ result  : FAILED$$' $(SIM_LOG)
```

Copy the `final` block from
[`example/example_tb_top.sv`](../example/example_tb_top.sv) into your own
testbench top and grep for it the same way.

## Still stuck

- [`example/`](../example) is a complete working testbench with numbered comments
  at each integration step.
- [`tb/`](../tb) shows the harder shapes: master and slave agents facing each
  other, five port geometries in one snapshot, and a scoreboard that handles the
  ordering subtleties above.
- `make gui` in either directory opens the run in XSIM interactively.
