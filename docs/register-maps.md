# Register maps

Driving a DUT by register and field name instead of by address, shift and
mask — and generating the whole map from the [Corsair](https://github.com/esynr3z/corsair)
output you already have.

```systemverilog
// Before
write(12'h004, (gain << 8) | (mode << 1) | enable, resp);

// After
axi_lite_data_t vals[string];
vals["ENABLE"] = 1; vals["MODE"] = CSR_CTRL_MODE_STREAM; vals["GAIN"] = gain;
reg_write_fields("CTRL", vals, resp);
```

The second form is one bus transaction, like the first, but the address, the
shifts and the masks come from the register map rather than from the author's
memory — and it keeps working when the map is regenerated.

## Why this is more than a convenience

The obvious way to write one field of a register is to read it, substitute, and
write it back. **On most of the access modes a real register map contains, that
is wrong**, and wrong in a way that succeeds: the write is accepted, the response
is `OKAY`, and something else in the register is quietly destroyed.

The clearest case is write-1-to-clear. Hardware raises `IRQ.DONE` and
`IRQ.ERROR`. A test wants to clear `DONE`. A read-modify-write reads `0b11`,
writes `0b11` back, and clears **both** — losing an interrupt, with nothing
about the bus traffic looking unusual.

Because the map carries each field's access mode, `field_write()` can pick a
strategy that is actually safe. That is the feature; the shorter syntax is a
side effect.

## Quick start

Three steps, starting from a Corsair register map.

### 1. Generate the model

```bash
tools/corsair_uvc_gen.py regs/regs.json -c regs/csrconfig -o tb/my_reg_pkg.sv \
    --map-name my_periph --package my_reg_pkg
```

Put it next to `corsair -c csrconfig` in your Makefile so it is regenerated
whenever the map is. [`example/corsair/Makefile`](../example/corsair/Makefile)
has a `regs` target that does both.

### 2. Attach it to the agent's config

```systemverilog
reg_model               = my_periph_reg_model::type_id::create("reg_model");
master_config.reg_model = reg_model;
```

That is the whole integration. Every sequence extending `axi_lite_reg_seq` finds
the model through its sequencer.

### 3. Extend `axi_lite_reg_seq` instead of `axi_lite_base_seq`

```systemverilog
class my_bringup_seq extends axi_lite_reg_seq;
  `uvm_object_utils(my_bringup_seq)
  function new(string name = "my_bringup_seq"); super.new(name); endfunction

  virtual task body();
    axi_lite_data_t value;
    axi_lite_resp_e resp;

    reg_model.print_map(UVM_MEDIUM);   // the map, as the UVC understands it
    check_all_resets();                // every readable register vs. its reset value

    field_check("ID", "MAGIC", 16'hA711);
    field_write("CTRL", "GAIN", 8'h5A, resp);
    field_write_enum("CTRL", "MODE", "STREAM", resp);
    field_read("STATUS", "ERRCODE", value, resp);
  endtask
endclass
```

A complete, runnable version of all of this is in
[`example/corsair/`](../example/corsair):

```bash
cd example/corsair && make regress
```

## How a field write is carried out

`field_write()` picks one of four strategies and records which in
`last_strategy`, with the number of bus accesses in `last_num_bus_accesses`.

| Strategy | Chosen when | Cost | Why |
| --- | --- | --- | --- |
| `MODAL` | the field is `rw1c` / `rw1s` / `rw1t` / `wosc` | 1 write | For these modes a written 0 means "leave alone", so the field can be written in place with zeros elsewhere. A read-modify-write would write back the ones it just read and trigger every sibling flag. |
| `STROBE` | the field exactly fills whole byte lanes | 1 write | Only the field's lanes are enabled with `WSTRB`, so nothing outside it can be disturbed — a mask that fills its lanes leaves no room in them for another field. Works on write-only registers too. |
| `RMW` | the register is readable, no field in it has a read side effect, and no field is modal | 1 read + 1 write | The ordinary case. |
| `SHADOW` | anything else: write-only and unaligned, or reading would itself change the DUT (`roc`/`roll`/`rolh`), or the register holds modal fields | 1 write | The word is built from the shadow value instead of from a read. Modal fields are forced to 0, since 0 is their no-op and a shadow cannot know what the hardware has set. |

The order matters: `MODAL` is checked before `STROBE` because for those modes an
in-place write is both cheaper and the only correct option.

### The shadow

The shadow is this testbench's belief about a register: its reset value, updated
by every write *and every successful read* made through this layer. It is exact
for a register only this layer writes, and a guess for one the hardware also
changes — which is why `SHADOW` is the last resort rather than the default.

A reset invalidates it. Call `reg_model.reset_shadows()` from your reset
handling, or the next `SHADOW` write will build its word from values the DUT no
longer holds.

`axi_lite_reg::shadow_is_reset` distinguishes "the shadow is the reset value
because nothing has happened yet" from "the shadow reflects a write we made".
`field_write()` says so at `UVM_MEDIUM` when it builds a word for an unreadable
register that has not been written yet, because that is the one case where the
shadow is an assumption rather than a record.

## Access modes

Corsair's ten modes are carried verbatim, because the distinctions are exactly
what the strategy decision turns on.

| Mode | `axi_lite_access_e` | Readable | Writable | Read has side effects | Written 1 acts |
| --- | --- | :-: | :-: | :-: | :-: |
| `rw` | `AXI_LITE_ACCESS_RW` | ✓ | ✓ | | |
| `rw1c` | `AXI_LITE_ACCESS_RW1C` | ✓ | ✓ | | ✓ |
| `rw1s` | `AXI_LITE_ACCESS_RW1S` | ✓ | ✓ | | ✓ |
| `rw1t` | `AXI_LITE_ACCESS_RW1T` | ✓ | ✓ | | ✓ |
| `ro` | `AXI_LITE_ACCESS_RO` | ✓ | | | |
| `roc` | `AXI_LITE_ACCESS_ROC` | ✓ | | ✓ | |
| `roll` | `AXI_LITE_ACCESS_ROLL` | ✓ | | ✓ | |
| `rolh` | `AXI_LITE_ACCESS_ROLH` | ✓ | | ✓ | |
| `wo` | `AXI_LITE_ACCESS_WO` | | ✓ | | |
| `wosc` | `AXI_LITE_ACCESS_WOSC` | | ✓ | | ✓ |

Collapsing `rw1c` into `rw` would be the expensive mistake, and it is the one a
hand-written map usually makes.

## The sequence API

Everything below is on `axi_lite_reg_seq`, which extends `axi_lite_base_seq` —
so `write()`, `read()`, `send()` and the `blocking` flag are all still there for
anything the named API does not cover.

### Whole registers

```systemverilog
task reg_write(string reg_name, axi_lite_data_t value, output axi_lite_resp_e resp);
task reg_read (string reg_name, output axi_lite_data_t value, output axi_lite_resp_e resp);
```

`reg_write` is literal: it writes the word you give it. On a register holding
modal fields that means acting on every 1 bit, which is occasionally what you
want and otherwise what `field_write` is for.

### Fields

```systemverilog
task field_write(string reg_name, string field_name, axi_lite_data_t value,
                 output axi_lite_resp_e resp);
task field_read (string reg_name, string field_name, output axi_lite_data_t value,
                 output axi_lite_resp_e resp);
```

`field_read` returns the field already shifted down. Both report an error rather
than guessing if the access mode forbids the operation, or if the value does not
fit in the field.

### Several fields at once

```systemverilog
task reg_write_fields(string reg_name, axi_lite_data_t values[string],
                      output axi_lite_resp_e resp);
```

```systemverilog
axi_lite_data_t vals[string];
vals["ENABLE"] = 1'b1;
vals["MODE"]   = CSR_CTRL_MODE_STREAM;
vals["GAIN"]   = 8'hFF;
vals["THRESH"] = 12'hABC;
reg_write_fields("CTRL", vals, resp);
```

One bus write. This is the call that replaces a run of hand-built writes, and it
is also the only way to set two fields of the same register **atomically** as far
as the DUT is concerned — writing them one at a time lets the DUT observe
intermediate states the test never intended.

It reads first only if the named fields leave implemented bits behind that a
plain write would clobber, and only if reading is safe. Naming every implemented
field of a register — the common case when setting one up — needs no read at all.

Every name and value is validated before any bus traffic, so a typo in the third
field does not leave the first two already written.

### Enumerated values

```systemverilog
task field_write_enum(string reg_name, string field_name, string enum_name,
                      output axi_lite_resp_e resp);
task field_read_enum (string reg_name, string field_name, output string enum_name,
                      output axi_lite_resp_e resp);
```

```systemverilog
field_write_enum("CTRL", "MODE", "STREAM", resp);
field_read_enum("STATUS", "ERRCODE", name, resp);   // name == "UNDERFLOW"
```

`field_read_enum` returns `""` if the value is not an enumerated one, and says so
at `UVM_MEDIUM` — usually worth knowing.

The generated package also emits each value as a sized constant, so the same
thing can be written in a form the compiler checks:

```systemverilog
field_write("CTRL", "MODE", CSR_CTRL_MODE_STREAM, resp);
```

Prefer the constant where you have it; the string form is for when the value is
itself chosen at run time.

### Checks

```systemverilog
task reg_check  (string reg_name, axi_lite_data_t expected);
task field_check(string reg_name, string field_name, axi_lite_data_t expected);
task check_all_resets();
```

Each reports a `UVM_ERROR` on mismatch and counts it in `num_check_failures`, so
a sequence works as a self-checking bring-up script. `field_check` names the
enumerated value in its failure message where the field has one.

`check_all_resets()` reads every readable register and compares it with the reset
value the map declares, ignoring bits no field implements. Registers whose read
has a side effect are skipped and named — reading them to check a reset value
would destroy the thing being checked.

## The two ways to get a Corsair map in

| | **Generated model** (recommended) | **Macros** |
| --- | --- | --- |
| Reads | `regs.json` / `regs.yaml` | Corsair's exported SV parameters |
| Carries access modes | ✓ automatically | stated by hand at each field |
| Carries enumerated values | ✓ | one macro per value |
| Maintenance when the map changes | none — regenerate | none, but a renamed field is a compile error to fix |
| Needs an extra build step | ✓ | |

Both are verified to produce the same map:
`example/corsair`'s `corsair_example_macro_test` compares them field by field.

### The generator

```
tools/corsair_uvc_gen.py REGMAP [options]

  -o, --output FILE      output .sv (default: stdout)
  -c, --csrconfig FILE   Corsair csrconfig, read for base_address and data_width
      --base-address A   override the base address
      --data-width N     override the data width
      --map-name NAME    name the model reports in logs
      --class-name NAME  generated class name (default: <map-name>_reg_model)
      --package [NAME]   wrap the class in a package (the default)
      --no-package       emit a bare class to `include instead
      --prefix P         prefix for the emitted constants (default: CSR)
      --no-params        emit only the model, no constants
      --force            generate even if the map has problems
```

It validates the map before emitting anything — unaligned addresses, duplicate
addresses, overlapping fields, fields past the bus width, and access modes it
does not recognise are all reported with the register and field named.

The output is a package containing the model class **and** the same constants
Corsair's `SystemVerilogPackage` generator emits (`CSR_CTRL_GAIN_LSB`,
`CSR_CTRL_MODE_STREAM`, …), so it can be used in place of that export rather
than alongside it. See the warning below for why that matters.

### The macros

For a project that would rather consume Corsair's exported package — because it
is already in the filelist, or because the flow cannot run an extra script.

```systemverilog
`include "axi_lite_corsair.svh"

class my_map extends axi_lite_reg_model;
  virtual function void build_map();
    axi_lite_field f;
    `AXI_LITE_CORSAIR_MAP(this, "my_periph", CSR)

    `AXI_LITE_CORSAIR_REG(this, CSR, CTRL)
    `AXI_LITE_CORSAIR_FIELD(this, CSR, CTRL, ENABLE, AXI_LITE_ACCESS_RW)
    `AXI_LITE_CORSAIR_FIELD_H(f, this, CSR, CTRL, MODE, AXI_LITE_ACCESS_RW)
    `AXI_LITE_CORSAIR_ENUM(f, CSR, CTRL, MODE, STREAM)
  endfunction
endclass
```

Every number comes from the parameters, so nothing is retyped and nothing goes
stale: a field that is renamed or moved becomes a compile error at the macro
rather than a wrong address at run time. The access mode is the one thing stated
by hand, because Corsair's export does not carry it.

A worked version is
[`example/corsair/corsair_example_macro_model.sv`](../example/corsair/corsair_example_macro_model.sv).

## Corsair's SystemVerilog export does not compile (v1.0.4)

Worth knowing before you reach for it. Corsair v1.0.4 writes a field's
enumerated values as an **untyped** `enum` — whose base type is therefore `int`,
32 bits — with sized literals inside it:

```systemverilog
typedef enum {
    CSR_CTRL_MODE_IDLE = 2'h0,     // 2-bit literal in a 32-bit enum
    ...
} csrctrl_mode_t;
```

IEEE 1800-2017 §6.19 requires a sized literal in an enum to match the base
type's width, so this is illegal SystemVerilog. XSIM rejects the whole package:

```
ERROR: [VRFC 10-3291] enum literal 'CSR_CTRL_MODE_IDLE' width (2) must match enum width (32)
```

A map with no enumerated values is unaffected. Otherwise, use the generated
package: `corsair_uvc_gen.py` emits the same constants as correctly sized
`localparam`s, which is why it is a replacement for Corsair's export rather than
a supplement to it. If Corsair fixes this and you want both, give the generator a
different `--prefix` so the names do not collide.

## Using it without Corsair

Nothing in the model layer is Corsair-specific. Build a map by hand where that is
easier:

```systemverilog
axi_lite_reg_model m = axi_lite_reg_model::type_id::create("m");
m.configure(.map_name("my_periph"), .base_address(64'h4000_0000), .data_width(32));

void'(m.create_reg("CTRL", 64'h0));
void'(m.create_field("CTRL", "ENABLE", 0, 1, AXI_LITE_ACCESS_RW));
begin
  axi_lite_field f = m.create_field("CTRL", "MODE", 1, 2, AXI_LITE_ACCESS_RW);
  f.add_enum("IDLE", 0);
  f.add_enum("STREAM", 1);
end
```

`create_reg`/`create_field` validate as they go: a duplicate name, two registers
at one address, overlapping fields, or a field past the transaction's width are
all reported at build time rather than becoming a wrong access later.

## Several instances of the same peripheral

A map's offsets are relative to its `base_address`, so two instances are two
model objects built from the same class:

```systemverilog
left  = my_periph_reg_model::type_id::create("left");
right = my_periph_reg_model::type_id::create("right");
right.base_address = 64'h1000;
```

Attach each to its own agent's config, or assign `reg_model` on a sequence
directly to point it at one for the duration.

## Gotchas

**A mistyped name is a run-time error, not a compile error.** That is the cost of
a string-keyed API. The diagnostics are built to make it cheap anyway: an unknown
register names the closest match it can find (`has no register 'CTRLL'. Did you
mean 'CTRL'?`), and an unknown field lists the fields that do exist. All of this
is itself tested — `corsair_example_diag_test` drives seven mistakes and requires
each to be reported exactly once.

**Named access ignores the config's address window.** A register's address comes
from the map, not from a constraint, so `set_addr_window()` shapes only random
stimulus. The two are independent on purpose.

**The map's width is checked against the link's once, on first access.** A map
generated for a 32-bit bus describes registers at addresses that assume that
width; driving it over a 64-bit link produces a warning rather than a silent
reinterpretation.

**`reg_read` updates the shadow, `check_all_resets` included.** That is deliberate
— a read is at least as good a basis for a later read-modify-write as a write is
— but it means reading a register whose hardware changes it behind your back
leaves the shadow describing the moment of the read.

## What the example establishes

`cd example/corsair && make regress` runs seven tests against a DUT **Corsair
generated from the same `regs.json`** the model was generated from, so the design
and the testbench's idea of the design cannot drift apart.

| Test | Establishes |
| --- | --- |
| `corsair_example_base_test` | the map loads; every readable register matches its declared reset value; fields read and write by name |
| `corsair_example_strategy_test` | each of the four strategies is chosen where expected, in the expected number of bus accesses, and the fields it was not asked to touch survive |
| `corsair_example_irq_test` | clearing one `rw1c` flag leaves the other set — the hazard a read-modify-write would hit |
| `corsair_example_cmd_test` | three fields of a **write-only** register written one at a time all survive, checked against the DUT's own output ports rather than the bus, which cannot answer |
| `corsair_example_enum_test` | enumerated values by name and by constant; four fields in one bus write reaching the DUT's outputs |
| `corsair_example_diag_test` | seven mistyped or illegal accesses each reported exactly once |
| `corsair_example_macro_test` | the generated model and the macro-built model agree on all 7 registers and 16 fields |

The DUT exposes the hardware side of every field, which is what lets the
write-only and `rw1c` cases be *proved* rather than merely reported: the test
arranges a state the bus cannot create and checks a result the bus cannot read.

Verified on XSIM 2023.2 only. See
[Troubleshooting](troubleshooting.md#xsim-20232-specifics) for the XSIM bugs this
code works around, two of which were found while building this feature.
