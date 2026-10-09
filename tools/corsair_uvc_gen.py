#!/usr/bin/env python3
"""Generate an axi_lite_reg_model from a Corsair register map.

Corsair's own SystemVerilogPackage generator exports a flat list of
parameters -- CSR_CTRL_GAIN_LSB, CSR_CTRL_GAIN_MASK and so on. Those are
elaboration-time constants: SystemVerilog cannot look one up by string,
iterate them, or ask which fields a register has, so they cannot support a
named API. They also do not carry the per-field *access mode*, which is
what decides whether a field can be written with byte strobes, with a
read-modify-write, or neither.

This script reads the register map itself -- the same regs.json or
regs.yaml Corsair reads -- and emits a SystemVerilog class that registers
every register, field, access mode and enumerated value into an
axi_lite_reg_model at construction time.

Usage
-----
    tools/corsair_uvc_gen.py regs/regs.json -o tb/my_reg_model.sv

    # take base_address and data_width from the Corsair config too
    tools/corsair_uvc_gen.py regs/regs.json -c regs/csrconfig -o tb/my_reg_model.sv

    # a bare class to `include into an existing package, instead of a package
    tools/corsair_uvc_gen.py regs/regs.json --no-package -o tb/my_reg_model.sv

Run it from your Makefile next to `corsair -c csrconfig` so the model is
regenerated whenever the map is. The output is derived entirely from the
map: it is meant to be regenerated, not edited.
"""

import argparse
import configparser
import json
import os
import re
import sys
import textwrap

# Corsair's ten access modes (corsair/bitfield.py) mapped onto the UVC's
# enumeration. Kept as an explicit table rather than an uppercase() so an
# access mode Corsair adds later fails loudly here instead of silently
# becoming something else.
ACCESS_MAP = {
    "rw": "AXI_LITE_ACCESS_RW",
    "rw1c": "AXI_LITE_ACCESS_RW1C",
    "rw1s": "AXI_LITE_ACCESS_RW1S",
    "rw1t": "AXI_LITE_ACCESS_RW1T",
    "ro": "AXI_LITE_ACCESS_RO",
    "roc": "AXI_LITE_ACCESS_ROC",
    "roll": "AXI_LITE_ACCESS_ROLL",
    "rolh": "AXI_LITE_ACCESS_ROLH",
    "wo": "AXI_LITE_ACCESS_WO",
    "wosc": "AXI_LITE_ACCESS_WOSC",
}

MAX_DESC = 160


def sv_string(text, limit=MAX_DESC):
    """Escape a description for use as a SystemVerilog string literal."""
    if not text:
        return '""'
    one_line = re.sub(r"\s+", " ", str(text)).strip()
    if len(one_line) > limit:
        one_line = one_line[: limit - 3].rstrip() + "..."
    return '"' + one_line.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_regmap(path):
    """Read a Corsair register map file (.json, .yaml or .yml)."""
    ext = os.path.splitext(path)[1].lower()
    with open(path) as f:
        if ext in (".yaml", ".yml"):
            try:
                import yaml
            except ImportError:
                sys.exit(
                    "error: reading '%s' needs PyYAML (pip install pyyaml), or export the map "
                    "as JSON instead" % path
                )
            data = yaml.safe_load(f)
        else:
            data = json.load(f)

    if not isinstance(data, dict) or "regmap" not in data:
        sys.exit("error: '%s' has no 'regmap' key; is it a Corsair register map?" % path)
    return data["regmap"]


def load_globcfg(path):
    """Read [globcfg] out of a Corsair csrconfig."""
    parser = configparser.ConfigParser()
    if not parser.read(path):
        sys.exit("error: could not read Corsair config '%s'" % path)
    if "globcfg" not in parser:
        sys.exit("error: '%s' has no [globcfg] section" % path)
    g = parser["globcfg"]
    return {
        "base_address": int(str(g.get("base_address", "0")), 0),
        "data_width": int(str(g.get("data_width", "32")), 0),
        "address_width": int(str(g.get("address_width", "32")), 0),
        "address_increment": g.get("address_increment", "none"),
    }


def resolve_addresses(regmap, data_width, address_increment):
    """Fill in any register whose address Corsair would have assigned.

    Corsair lets a register omit its address and derives it from
    `address_increment`. A map read straight from JSON may therefore have
    `address: null`, so the same rule is applied here rather than emitting
    a model with a hole in it.
    """
    if str(address_increment) == "none":
        step = data_width // 8
    elif str(address_increment) == "data_width":
        step = data_width // 8
    else:
        step = int(str(address_increment), 0)

    next_addr = 0
    for reg in regmap:
        addr = reg.get("address", None)
        if addr is None:
            reg["address"] = next_addr
        else:
            reg["address"] = int(str(addr), 0) if isinstance(addr, str) else int(addr)
        next_addr = reg["address"] + step
    return regmap


def check_map(regmap, data_width, base_address):
    """Report anything that would make the generated model unusable."""
    problems = []
    bytes_per_reg = data_width // 8
    seen = {}

    for reg in regmap:
        name = reg.get("name")
        if not name:
            problems.append("a register has no name")
            continue
        addr = reg["address"]

        if (base_address + addr) % bytes_per_reg:
            problems.append(
                "%s is at 0x%x, which is not aligned to the %d-byte bus"
                % (name, base_address + addr, bytes_per_reg)
            )
        if addr in seen:
            problems.append("%s and %s are both at 0x%x" % (name, seen[addr], addr))
        seen[addr] = name

        used = 0
        for bf in reg.get("bitfields", []):
            fname = bf.get("name", "?")
            lsb = int(bf.get("lsb", 0))
            width = int(bf.get("width", 1))
            access = str(bf.get("access", "rw"))

            if access not in ACCESS_MAP:
                problems.append(
                    "%s.%s has access '%s', which this generator does not know; "
                    "add it to ACCESS_MAP" % (name, fname, access)
                )
            if lsb + width > data_width:
                problems.append(
                    "%s.%s occupies bits %d:%d, past the %d-bit bus"
                    % (name, fname, lsb + width - 1, lsb, data_width)
                )
            mask = ((1 << width) - 1) << lsb
            if used & mask:
                problems.append("%s.%s overlaps another field" % (name, fname))
            used |= mask

    return problems


def generate(regmap, opts):
    """Render the SystemVerilog model."""
    cls = opts.class_name
    out = []
    w = out.append

    w("///////////////////////////////////////////////////////////////////")
    w("// GENERATED FILE -- DO NOT EDIT.")
    w("//")
    w("// Produced by tools/corsair_uvc_gen.py from:")
    w("//   register map : %s" % os.path.basename(opts.regmap))
    if opts.csrconfig:
        w("//   Corsair cfg  : %s" % os.path.basename(opts.csrconfig))
    w("//")
    w("// Regenerate it whenever the register map changes -- the map is the")
    w("// source of truth and anything edited here is lost on the next run.")
    w("//")
    w("// %d register(s), %d field(s)." % (len(regmap), sum(len(r.get('bitfields', [])) for r in regmap)))
    w("///////////////////////////////////////////////////////////////////")
    w("")

    if opts.package:
        w("package %s;" % opts.package)
        w("")
        w("  import uvm_pkg::*;")
        w('  `include "uvm_macros.svh"')
        w("  import axi_lite_pkg::*;")
        w("")

    ind = "  " if opts.package else ""

    # ---- Constants, mirroring the names Corsair's SystemVerilogPackage
    # generator uses, so this file is a drop-in replacement for it.
    #
    # Emitting them here rather than importing Corsair's package is not
    # duplication for its own sake: Corsair v1.0.4 writes enumerated
    # values as an untyped `enum` (whose base type is therefore `int`,
    # 32 bits) with sized literals -- `CSR_CTRL_MODE_IDLE = 2'h0` -- and
    # IEEE 1800-2017 section 6.19 requires a sized literal to match the
    # enum's base-type width. The result is illegal SystemVerilog that
    # strict tools reject outright. Sized localparams carry the same
    # information and compile.
    if opts.params:
        pre = opts.prefix
        w("%s// ---- Map constants. Same names as Corsair's" % ind)
        w("%s// SystemVerilogPackage export, so this package can be used in" % ind)
        w("%s// place of it." % ind)
        w("%slocalparam int %s_BASE_ADDR  = %d;" % (ind, pre, opts.base_address))
        w("%slocalparam int %s_DATA_WIDTH = %d;" % (ind, pre, opts.data_width))
        w("%slocalparam int %s_ADDR_WIDTH = %d;" % (ind, pre, opts.addr_width))
        w("")

        for reg in regmap:
            rname = reg["name"].upper()
            reset = 0
            for bf in reg.get("bitfields", []):
                reset |= (int(bf.get("reset", 0)) & ((1 << int(bf.get("width", 1))) - 1)) << int(
                    bf.get("lsb", 0)
                )
            w("%s// %s" % (ind, reg["name"]))
            w(
                "%slocalparam int %s_%s_ADDR = %d;"
                % (ind, pre, rname, reg["address"])
            )
            w(
                "%slocalparam logic [%d:0] %s_%s_RESET = %d'h%X;"
                % (ind, opts.data_width - 1, pre, rname, opts.data_width, reset)
            )

            for bf in reg.get("bitfields", []):
                fname = bf["name"].upper()
                lsb = int(bf.get("lsb", 0))
                width = int(bf.get("width", 1))
                fres = int(bf.get("reset", 0)) & ((1 << width) - 1)
                mask = ((1 << width) - 1) << lsb
                base = "%s_%s_%s" % (pre, rname, fname)
                w("%slocalparam int %s_WIDTH = %d;" % (ind, base, width))
                w("%slocalparam int %s_LSB = %d;" % (ind, base, lsb))
                w(
                    "%slocalparam logic [%d:0] %s_MASK = %d'h%X;"
                    % (ind, opts.data_width - 1, base, opts.data_width, mask)
                )
                w(
                    "%slocalparam logic [%d:0] %s_RESET = %d'h%X;"
                    % (ind, width - 1, base, width, fres)
                )
                for ev in bf.get("enums", []) or []:
                    # Sized to the field, which is what makes these usable
                    # where Corsair's own enum literals are not.
                    w(
                        "%slocalparam logic [%d:0] %s_%s = %d'h%X;"
                        % (
                            ind,
                            width - 1,
                            base,
                            ev["name"].upper(),
                            width,
                            int(ev.get("value", 0)),
                        )
                    )
            w("")

    w("%sclass %s extends axi_lite_reg_model;" % (ind, cls))
    w("")
    w("%s  `uvm_object_utils(%s)" % (ind, cls))
    w("")
    w('%s  function new(string name = "%s");' % (ind, cls))
    w("%s    super.new(name);" % ind)
    w(
        '%s    configure(.map_name("%s"), .base_address(%d\'h%X), .data_width(%d));'
        % (ind, opts.map_name, 64, opts.base_address, opts.data_width)
    )
    w("%s    build_map();" % ind)
    w("%s  endfunction : new" % ind)
    w("")
    w("%s  // One call per register and per field, in map order." % ind)
    w("%s  virtual function void build_map();" % ind)

    for reg in regmap:
        rname = reg["name"]
        fields = reg.get("bitfields", [])
        w("")
        w("%s    // ---- %s @ 0x%X ----" % (ind, rname, reg["address"]))
        if reg.get("description"):
            for line in textwrap.wrap(re.sub(r"\s+", " ", reg["description"]).strip(), 66):
                w("%s    // %s" % (ind, line))
        w(
            "%s    void'(create_reg(\"%s\", 64'h%X, %s));"
            % (ind, rname, reg["address"], sv_string(reg.get("description", "")))
        )

        for bf in fields:
            fname = bf["name"]
            lsb = int(bf.get("lsb", 0))
            width = int(bf.get("width", 1))
            reset = int(bf.get("reset", 0))
            access = ACCESS_MAP[str(bf.get("access", "rw"))]
            desc = sv_string(bf.get("description", ""))
            enums = bf.get("enums", []) or []

            call = (
                "create_field(\"%s\", \"%s\", %d, %d, %s, 64'h%X, %s)"
                % (rname, fname, lsb, width, access, reset, desc)
            )

            if not enums:
                w("%s    void'(%s);" % (ind, call))
            else:
                # The handle is only needed to hang enumerated values off,
                # so it is scoped to a block rather than declared up top.
                w("%s    begin : %s_%s" % (ind, rname.lower(), fname.lower()))
                w("%s      axi_lite_field f = %s;" % (ind, call))
                for ev in enums:
                    w(
                        '%s      f.add_enum("%s", 64\'h%X, %s);'
                        % (ind, ev["name"], int(ev.get("value", 0)), sv_string(ev.get("description", "")))
                    )
                w("%s    end : %s_%s" % (ind, rname.lower(), fname.lower()))

    w("%s  endfunction : build_map" % ind)
    w("")
    w("%sendclass : %s" % (ind, cls))

    if opts.package:
        w("")
        w("endpackage : %s" % opts.package)

    w("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(
        description="Generate an axi_lite_reg_model from a Corsair register map.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage")[1] if "Usage" in __doc__ else None,
    )
    ap.add_argument("regmap", help="Corsair register map: regs.json, regs.yaml or regs.yml")
    ap.add_argument("-o", "--output", help="output .sv file (default: stdout)")
    ap.add_argument(
        "-c",
        "--csrconfig",
        help="Corsair csrconfig, read for base_address and data_width",
    )
    ap.add_argument("--base-address", type=lambda v: int(v, 0), help="override base address")
    ap.add_argument("--data-width", type=int, help="override data width in bits")
    ap.add_argument(
        "--map-name",
        help="name the model reports in logs (default: derived from the output or map file)",
    )
    ap.add_argument("--class-name", help="generated class name (default: <map-name>_reg_model)")
    ap.add_argument(
        "--package",
        nargs="?",
        const="",
        default=None,
        help="wrap the class in a package of this name (default: <class-name>_pkg)",
    )
    ap.add_argument(
        "--no-package",
        action="store_true",
        help="emit a bare class to `include into an existing package",
    )
    ap.add_argument(
        "--prefix",
        default="CSR",
        help="prefix for the emitted constants (default: CSR, matching Corsair)",
    )
    ap.add_argument(
        "--no-params",
        action="store_true",
        help="omit the constant block and emit only the register model",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="write the output even if the map has problems",
    )
    opts = ap.parse_args()

    regmap = load_regmap(opts.regmap)
    if not regmap:
        sys.exit("error: '%s' contains no registers" % opts.regmap)

    globcfg = load_globcfg(opts.csrconfig) if opts.csrconfig else {}
    opts.base_address = (
        opts.base_address
        if opts.base_address is not None
        else globcfg.get("base_address", 0)
    )
    opts.data_width = (
        opts.data_width if opts.data_width is not None else globcfg.get("data_width", 32)
    )
    opts.addr_width = globcfg.get("address_width", 32)
    opts.params = not opts.no_params
    opts.prefix = re.sub(r"[^A-Za-z0-9_]", "_", opts.prefix).upper().strip("_") or "CSR"

    if opts.data_width not in (32, 64):
        print(
            "warning: data_width=%d; AXI4-Lite permits only 32 or 64" % opts.data_width,
            file=sys.stderr,
        )

    # Default names, derived from the output file so that the common case
    # needs no naming flags at all.
    stem = os.path.splitext(os.path.basename(opts.output or opts.regmap))[0]
    stem = re.sub(r"_reg_model$|_regs$|^regs$", "", stem) or "csr"
    stem = re.sub(r"[^A-Za-z0-9_]", "_", stem).strip("_") or "csr"
    if not re.match(r"^[A-Za-z]", stem):
        stem = "m_" + stem

    opts.map_name = opts.map_name or stem
    opts.class_name = opts.class_name or ("%s_reg_model" % opts.map_name)
    if opts.no_package:
        opts.package = None
    elif opts.package == "":
        opts.package = "%s_pkg" % opts.class_name

    regmap = resolve_addresses(
        regmap, opts.data_width, globcfg.get("address_increment", "none")
    )

    problems = check_map(regmap, opts.data_width, opts.base_address)
    for p in problems:
        print("error: %s" % p, file=sys.stderr)
    if problems and not opts.force:
        sys.exit(
            "error: %d problem(s) in '%s'; fix the map, or pass --force to generate anyway"
            % (len(problems), opts.regmap)
        )

    text = generate(regmap, opts)

    if opts.output:
        outdir = os.path.dirname(os.path.abspath(opts.output))
        if outdir:
            os.makedirs(outdir, exist_ok=True)
        with open(opts.output, "w") as f:
            f.write(text)
        print(
            "corsair_uvc_gen: %s -> %s (%d registers, %d fields)"
            % (
                opts.regmap,
                opts.output,
                len(regmap),
                sum(len(r.get("bitfields", [])) for r in regmap),
            )
        )
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
