# Stimulus

The transaction, the sequence library, and how to write sequences of your own.

Nothing in this document mentions a bus width, and that is the point: the
transaction sizes and places itself from the agent's config at randomize time,
so the same sequence drives a 12/32 port and a 64/64 one without being told
which it is on.

## The transaction

`axi_lite_seq_item` is **one whole transaction** — a read (AR answered by R) or
a write (AW + W answered by B). AXI4-Lite has no bursts, so that is the entire
taxonomy and there is no beat-level item to assemble.

### What you randomize

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `axi_lite_kind_e` | `AXI_LITE_WRITE` or `AXI_LITE_READ` |
| `addr` | `axi_lite_addr_t` | held in 64 bits, masked to the link's width |
| `prot` | `axi_lite_prot_t` | AWPROT/ARPROT |
| `wdata` | `axi_lite_data_t` | writes only |
| `wstrb` | `axi_lite_strb_t` | writes only |
| `addr_delay` | `int unsigned` | idle cycles before the address phase |
| `wdata_delay` | `int unsigned` | idle cycles before the write data phase |

### What comes back

| Field | Meaning |
| --- | --- |
| `rdata` | read data (reads only) |
| `resp` | BRESP for writes, RRESP for reads |
| `has_response` | set once an answer actually arrived |
| `aborted` | set if reset killed the transaction before it was answered |
| `latency_cycles` | request accepted → response accepted |
| `addr_stall_cycles` | cycles the address phase waited for READY |
| `wdata_stall_cycles` | cycles the write data phase waited |
| `resp_stall_cycles` | cycles the response waited for our own READY |

Check `has_response` before believing `resp`. An `aborted` item has neither.

### Geometry, and why it is not `rand`

`addr_width`, `data_width`, `has_prot`, the masks and the delay bounds are
plain non-rand fields, adopted from the config in `pre_randomize()`. They
describe the port; they are not stimulus. The constraints that *do* generate
fields refer to them:

| Constraint | What it enforces |
| --- | --- |
| `c_alignment` | address aligned to the data bus width |
| `c_window` | address inside the config's `addr_lo`…`addr_hi` |
| `c_addr_width` | no bits above `ADDR_WIDTH` |
| `c_strb_width` | no strobe bits above `DATA_WIDTH/8` |
| `c_read_has_no_wdata` | a read carries no write payload |
| `c_full_strobe` | gated by the non-rand `full_strobe` flag |
| `c_prot` | zero AxPROT when `has_prot` is clear |
| `c_addr_delay`, `c_wdata_delay` | delays inside the configured ranges |

`full_strobe` defaults to 1 — a write enables the whole bus unless you say
otherwise. Clear it to let the solver pick byte lanes.

### Completion

```systemverilog
function bit  is_done();
task          wait_done();     // blocks until answered or aborted
function bit  is_write();
function bit  is_error();      // has_response && resp != OKAY
function int unsigned num_bytes();          // bytes this transfer moves
function int unsigned num_strobed_bytes();  // byte lanes WSTRB enables
```

## The sequence library

All five are unparameterized and all draw from the agent's configured address
window.

| Sequence | Does |
| --- | --- |
| `axi_lite_write_seq` | one write |
| `axi_lite_read_seq` | one read; `.rdata` and `.resp` afterwards |
| `axi_lite_write_read_seq` | a write and a read-back, compared |
| `axi_lite_sweep_seq` | walk every location in the window, write then read |
| `axi_lite_random_seq` | a configurable mix of the above |

`axi_lite_base_seq` is the virtual parent. Extend it and you inherit the
geometry plumbing, `write()`, `read()` and `send()`.

### Random traffic

```systemverilog
axi_lite_random_seq random_sequence =
    axi_lite_random_seq::type_id::create("random_sequence");
if (!random_sequence.randomize() with { num_transactions == 40;
                                        read_percent inside {[40:60]}; })
  `uvm_fatal("RAND", "sequence randomization failed")
random_sequence.start(env.master_agent.sequencer);
```

| Knob | Soft default | Meaning |
| --- | --- | --- |
| `num_transactions` | `[8:32]` | how many |
| `read_percent` | `50` | fraction that are reads |
| `partial_strobe_percent` | `25` | fraction of **writes** using a partial byte strobe |
| `prot_percent` | `20` | fraction carrying a non-zero AxPROT |

All four defaults are `soft`, so a `with` clause overrides them without
conflict.

### A single access

```systemverilog
axi_lite_write_seq write_sequence = axi_lite_write_seq::type_id::create("w");
assert (write_sequence.randomize() with { addr == 'h10; wdata == 32'hCAFE_F00D; });
write_sequence.start(sequencer);
// write_sequence.resp is now the BRESP
```

```systemverilog
axi_lite_read_seq read_sequence = axi_lite_read_seq::type_id::create("r");
assert (read_sequence.randomize() with { addr == 'h10; });
read_sequence.start(sequencer);
$display("read 0x%0h -> %s", read_sequence.rdata, read_sequence.resp.name());
```

`axi_lite_write_seq` has a `full_strobe` flag (default 1). Clear it and the
solver picks byte lanes for you.

### Walking the map

```systemverilog
axi_lite_sweep_seq sweep_sequence = axi_lite_sweep_seq::type_id::create("sweep");
assert (sweep_sequence.randomize() with { max_locations == 64; });
sweep_sequence.start(sequencer);
// sweep_sequence.num_visited, .num_errors
```

The sweep writes an address-derived pattern to every location in the window and
reads it straight back. That is the check that catches an address truncated,
shifted, or decoded onto the wrong register — a bug random traffic can hide for
a long time.

`max_locations` caps the walk so a sweep of a 4 GB aperture is bounded rather
than eternal; 0 means the whole window. `pattern_for(addr)` is virtual if you
want a different pattern.

Set `check_readback = 0` when the map contains read-only or side-effecting
registers, and let your scoreboard — which knows the map — do the checking. The
sweep's own comparison is a bring-up convenience; the scoreboard's is the real
check.

## Directed access: `write()` and `read()`

Every sequence extending `axi_lite_base_seq` gets these two, and a directed
test reads like the register sequence it is describing:

```systemverilog
task axi_lite_base_seq::write(axi_lite_addr_t addr, axi_lite_data_t data,
                              output axi_lite_resp_e resp,
                              input  axi_lite_strb_t strb = '1,
                              input  axi_lite_prot_t prot = 3'b000);

task axi_lite_base_seq::read(axi_lite_addr_t addr,
                             output axi_lite_data_t data,
                             output axi_lite_resp_e resp,
                             input  axi_lite_prot_t prot = 3'b000);
```

```systemverilog
class my_bringup_seq extends axi_lite_base_seq;
  `uvm_object_utils(my_bringup_seq)
  function new(string name = "my_bringup_seq"); super.new(name); endfunction

  virtual task body();
    axi_lite_data_t data;
    axi_lite_resp_e resp;

    read(ID_ADDR, data, resp);
    if (data !== 32'hA711_0001)
      `uvm_error("BRINGUP", $sformatf("ID read 0x%0h", data))

    write(CTRL_ADDR, 32'h0000_0001, resp);          // whole word
    write(CTRL_ADDR, 32'h0000_00A5, resp, .strb(4'b0001));  // one byte lane

    read(UNMAPPED_ADDR, data, resp);                // outside the window on purpose
    if (resp != AXI_LITE_DECERR)
      `uvm_error("BRINGUP", "unmapped address did not answer DECERR")
  endtask
endclass
```

Two things worth knowing about directed access:

**It is not held to the address window.** `send()` turns off `c_window`,
`c_alignment` and `c_addr_width` for an item whose address the caller chose
deliberately, then only randomizes the pacing knobs. Probing an unmapped address
to watch the slave answer DECERR is a test, not a mistake. A misaligned or
too-wide address still produces a warning naming the field, so a genuine typo is
not silent.

**Getting WSTRB right is the most common register-file bug there is.** One
directed byte-lane write is worth having even when random traffic covers it,
because when it fails you know immediately which lane.

## Blocking and pipelining

`axi_lite_base_seq` has a `blocking` flag, default 1: `send()` returns only once
the transaction has been answered. That is what makes `write()` then `read()`
read like a program.

Clear it to keep several transactions in flight from one sequence:

```systemverilog
blocking = 1'b0;
foreach (addrs[i]) begin
  axi_lite_seq_item item = new_item($sformatf("w%0d", i));
  item.kind  = AXI_LITE_WRITE;
  item.addr  = addrs[i];
  item.wdata = data[i];
  item.wstrb = item.strb_mask;
  send(item);              // returns immediately
  items.push_back(item);
end
foreach (items[i]) items[i].wait_done();
```

This only helps if `max_outstanding > 1` in the config — otherwise the driver
throttles to one at a time regardless, and all you have changed is where the
waiting happens.

## Writing a sequence from scratch

```systemverilog
class my_seq extends axi_lite_base_seq;
  `uvm_object_utils(my_seq)
  rand int unsigned num_bursts;
  constraint c_n { soft num_bursts inside {[4:16]}; }

  function new(string name = "my_seq"); super.new(name); endfunction

  virtual task body();
    for (int i = 0; i < num_bursts; i++) begin
      axi_lite_seq_item item = new_item($sformatf("item_%0d", i));

      // Constrain against the mirrors -- m_addr_lo, m_addr_hi, m_strb_mask,
      // m_align_mask -- rather than hard-coding a width. pre_randomize()
      // refreshes them from the agent's config, so this sequence is correct
      // on every port geometry in the testbench.
      if (!item.randomize() with { kind == AXI_LITE_WRITE;
                                   addr inside {[m_addr_lo : m_addr_hi]}; })
        `uvm_fatal("RAND", "item randomization failed")

      start_item(item);
      finish_item(item);
      if (blocking) item.wait_done();
    end
  endtask
endclass
```

`new_item()` creates an item and stamps the port's geometry onto it. Use it
rather than `create()` directly, or the item will randomize against defaults
instead of against your actual link.

Prefer `send(item)` over hand-rolling `start_item`/`finish_item` when the
address and payload are already decided — it relaxes the generating constraints
for you and warns about a bad address instead of failing to solve.

## Driving several ports at once

Because the sequencer carries no width parameter, every port's sequencer fits in
one queue:

```systemverilog
foreach (env.agents[i]) fork
  automatic int k = i;
  begin
    axi_lite_random_seq s = axi_lite_random_seq::type_id::create($sformatf("s%0d", k));
    if (!s.randomize() with { num_transactions == 20; })
      `uvm_fatal("RAND", "randomization failed")
    s.start(env.agents[k].sequencer);
  end
join_none
wait fork;
```

The self-test's `axi_lite_multiwidth_test` does exactly this across five
different port geometries in one run.

## If your DUT has a register map

Everything above addresses the DUT by address. If it has a register map —
especially a generated one — extend `axi_lite_reg_seq` instead of
`axi_lite_base_seq` and address it by name:

```systemverilog
class my_seq extends axi_lite_reg_seq;
  virtual task body();
    axi_lite_resp_e resp;
    field_write("CTRL", "GAIN", 8'h5A, resp);        // address, shift and mask from the map
    field_write_enum("CTRL", "MODE", "STREAM", resp);
  endtask
endclass
```

`axi_lite_reg_seq` extends `axi_lite_base_seq`, so `write()`, `read()`, `send()`
and `blocking` are all still available for anything the named API does not cover.

See **[Register maps](register-maps.md)**.

Next: **[Checks and coverage](checks-and-coverage.md)**.
