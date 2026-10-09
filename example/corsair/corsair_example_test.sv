///////////////////////////////////////////////////////////////////
// Filename: corsair_example_test.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Tests for the Corsair integration example.
///////////////////////////////////////////////////////////////////
//
// The only thing these do differently from example/example_base_test.sv
// is attach a register model to the agent's config. After that, every
// sequence can address the DUT by name.

class corsair_example_base_test extends uvm_test;

  `uvm_component_utils(corsair_example_base_test)

  corsair_example_env env;
  axi_lite_config     master_config;

  // The map, generated from regs.json. One object, shared by every
  // sequence through the config.
  corsair_example_reg_model reg_model;

  extern function new(string name = "corsair_example_base_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual task run_stimulus();
  // Gives a sequence the hardware-side handle and starts it.
  extern task start_seq(corsair_base_seq seq);

endclass : corsair_example_base_test

function corsair_example_base_test::new(string name = "corsair_example_base_test",
                                        uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void corsair_example_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  master_config      = axi_lite_config::type_id::create("master_config");
  master_config.role = AXI_LITE_MASTER;

  // ---------------------------------------------------------------------
  // The one line this example is about.
  //
  // The model carries its own base address and data width, both taken
  // from the Corsair config at generation time, so there is nothing else
  // to keep in step. Every axi_lite_reg_seq started on this agent finds
  // it through the sequencer.
  // ---------------------------------------------------------------------
  reg_model               = corsair_example_reg_model::type_id::create("reg_model");
  master_config.reg_model = reg_model;

  // Random stimulus, if any, stays inside the decoded map. Named access
  // ignores this window -- a register's address comes from the map, not
  // from a constraint -- but it keeps the two kinds of traffic
  // consistent if a test mixes them.
  master_config.set_addr_window(64'h0, EX_MAP_HI);

  master_config.set_addr_delay(0, 2);
  master_config.set_wdata_delay(0, 2);
  master_config.set_ready_mode(AXI_LITE_CH_B, AXI_LITE_READY_RANDOM, .percent(80));
  master_config.set_ready_mode(AXI_LITE_CH_R, AXI_LITE_READY_RANDOM, .percent(80));
  master_config.stall_timeout_cycles = 2000;

  uvm_config_db#(axi_lite_config)::set(this, "env", "master_config", master_config);
  env = corsair_example_env::type_id::create("env", this);
endfunction : build_phase

task corsair_example_base_test::start_seq(corsair_base_seq seq);
  seq.hw_vif = env.hw_vif;
  seq.start(env.master_agent.sequencer);
endtask : start_seq

task corsair_example_base_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "driving the register map");
  // Let reset release before the first access.
  repeat (10) @(posedge env.vif.aclk);
  run_stimulus();
  repeat (20) @(posedge env.vif.aclk);
  phase.drop_objection(this, "done");
endtask : run_phase

task corsair_example_base_test::run_stimulus();
  corsair_bringup_seq seq = corsair_bringup_seq::type_id::create("bringup");
  start_seq(seq);
endtask : run_stimulus


///////////////////////////////////////////////////////////////////
class corsair_example_strategy_test extends corsair_example_base_test;
  `uvm_component_utils(corsair_example_strategy_test)
  function new(string name = "corsair_example_strategy_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_stimulus();
    corsair_strategy_seq seq = corsair_strategy_seq::type_id::create("strategy");
    start_seq(seq);
  endtask
endclass : corsair_example_strategy_test


///////////////////////////////////////////////////////////////////
class corsair_example_irq_test extends corsair_example_base_test;
  `uvm_component_utils(corsair_example_irq_test)
  function new(string name = "corsair_example_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_stimulus();
    corsair_irq_seq seq = corsair_irq_seq::type_id::create("irq");
    start_seq(seq);
  endtask
endclass : corsair_example_irq_test


///////////////////////////////////////////////////////////////////
class corsair_example_cmd_test extends corsair_example_base_test;
  `uvm_component_utils(corsair_example_cmd_test)
  function new(string name = "corsair_example_cmd_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_stimulus();
    corsair_cmd_seq seq = corsair_cmd_seq::type_id::create("cmd");
    start_seq(seq);
  endtask
endclass : corsair_example_cmd_test


///////////////////////////////////////////////////////////////////
class corsair_example_enum_test extends corsair_example_base_test;
  `uvm_component_utils(corsair_example_enum_test)
  function new(string name = "corsair_example_enum_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual task run_stimulus();
    corsair_enum_seq seq = corsair_enum_seq::type_id::create("enum");
    start_seq(seq);
  endtask
endclass : corsair_example_enum_test


///////////////////////////////////////////////////////////////////
// Negative test: the mistakes a named API invites, and the diagnostics
// that are supposed to catch them.
//
// A string name is resolved at run time, so a typo cannot be a compile
// error the way a parameter name would be. That makes the quality of the
// message the only thing standing between a typo and a confusing null
// dereference -- so the messages are tested, the same way the protocol
// assertions are tested by tb/axi_lite_if_check_tb.sv.
//
// Each case below must produce exactly one UVM_ERROR. The catcher
// demotes them to UVM_INFO so the test can require them without failing.
///////////////////////////////////////////////////////////////////
class corsair_error_catcher extends uvm_report_catcher;

  int unsigned num_caught = 0;

  function new(string name = "corsair_error_catcher");
    super.new(name);
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_ERROR) &&
        ((get_id() == "REGMODEL") || (get_id() == "REGCHECK"))) begin
      num_caught++;
      set_severity(UVM_INFO);
      set_id("EXPECTED_ERROR");
    end
    return THROW;
  endfunction

endclass : corsair_error_catcher


class corsair_diag_seq extends corsair_base_seq;

  `uvm_object_utils(corsair_diag_seq)

  corsair_error_catcher catcher;

  int unsigned num_cases = 0;
  int unsigned num_failures = 0;

  function new(string name = "corsair_diag_seq");
    super.new(name);
  endfunction

  // Each case runs with a known catch count and must add exactly one.
  function void expect_one(string what, int unsigned base_count);
    int unsigned caught = catcher.num_caught - base_count;
    num_cases++;
    if (caught != 1) begin
      num_failures++;
      `uvm_error("DIAG", $sformatf("%s produced %0d error(s), expected exactly 1", what, caught))
    end else begin
      `uvm_info("DIAG", $sformatf("%s: reported, as it should be", what), UVM_LOW)
    end
  endfunction

  virtual task body();
    axi_lite_data_t value;
    axi_lite_resp_e resp;
    int unsigned    base;

    // ---- A mistyped register name. The message should name the one it
    // probably meant.
    base = catcher.num_caught;
    reg_read("CTRLL", value, resp);
    expect_one("read of a mistyped register name", base);

    // ---- A mistyped field name. The message lists the fields that do
    // exist, which is usually enough on its own.
    base = catcher.num_caught;
    field_read("CTRL", "GAINN", value, resp);
    expect_one("read of a mistyped field name", base);

    // ---- A value too wide for the field. Silently truncating this is
    // how a test ends up passing while testing the wrong number.
    base = catcher.num_caught;
    field_write("CTRL", "GAIN", 16'h1FF, resp);
    expect_one("write of a value too wide for the field", base);

    // ---- Writing a read-only field.
    base = catcher.num_caught;
    field_write("ID", "MAGIC", 16'h0000, resp);
    expect_one("write to a read-only field", base);

    // ---- Reading a write-only field.
    base = catcher.num_caught;
    field_read("CMD", "OPCODE", value, resp);
    expect_one("read of a write-only field", base);

    // ---- An enumerated value that is not in the map.
    base = catcher.num_caught;
    field_write_enum("CTRL", "MODE", "TURBO", resp);
    expect_one("write of an unknown enumerated value", base);

    // ---- A field named in reg_write_fields that does not exist. The
    // whole call must be abandoned before any bus traffic, so that a
    // typo in the third field does not leave the first two written.
    base = catcher.num_caught;
    begin
      axi_lite_data_t vals[string];
      vals["ENABLE"] = 1'b1;
      vals["NOPE"]   = 1'b1;
      reg_write_fields("CTRL", vals, resp);
    end
    expect_one("multi-field write naming an unknown field", base);

    $display("============================================================");
    $display(" register-model diagnostics: %0d of %0d cases behaved correctly",
             num_cases - num_failures, num_cases);
    $display("============================================================");
  endtask

endclass : corsair_diag_seq


class corsair_example_diag_test extends corsair_example_base_test;

  `uvm_component_utils(corsair_example_diag_test)

  corsair_error_catcher catcher;

  function new(string name = "corsair_example_diag_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    catcher = new("catcher");
    uvm_report_cb::add(null, catcher);
  endfunction

  virtual task run_stimulus();
    corsair_diag_seq seq = corsair_diag_seq::type_id::create("diag");
    seq.catcher = catcher;
    start_seq(seq);
  endtask

endclass : corsair_example_diag_test


///////////////////////////////////////////////////////////////////
// The two integration paths must describe the same map.
//
// One model is generated from regs.json; the other is built from the
// exported SystemVerilog parameters through the macros in
// src/axi_lite_corsair.svh. They come from the same register map by two
// routes, so every address, offset, width and reset value has to agree.
// If they ever stop agreeing, one of the two paths has a bug -- and
// without this test it would be the quieter one that got shipped.
///////////////////////////////////////////////////////////////////
class corsair_example_macro_test extends corsair_example_base_test;

  `uvm_component_utils(corsair_example_macro_test)

  corsair_example_macro_model macro_model;

  function new(string name = "corsair_example_macro_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    macro_model = corsair_example_macro_model::type_id::create("macro_model");
  endfunction

  // Compared in check_phase rather than in a sequence: this is a property
  // of the two models, and needs no bus traffic to establish.
  virtual function void check_phase(uvm_phase phase);
    int unsigned num_compared = 0;
    super.check_phase(phase);

    if (macro_model.base_address !== reg_model.base_address)
      `uvm_error("MACRO", $sformatf("base address differs: generated 0x%0h, macros 0x%0h",
                                    reg_model.base_address, macro_model.base_address))
    if (macro_model.data_width !== reg_model.data_width)
      `uvm_error("MACRO", $sformatf("data width differs: generated %0d, macros %0d",
                                    reg_model.data_width, macro_model.data_width))
    if (macro_model.regs.size() !== reg_model.regs.size())
      `uvm_error("MACRO", $sformatf("register count differs: generated %0d, macros %0d",
                                    reg_model.regs.size(), macro_model.regs.size()))

    foreach (reg_model.regs[i]) begin
      axi_lite_reg want = reg_model.regs[i];
      axi_lite_reg got  = macro_model.get_reg(want.reg_name);
      if (got == null) continue;  // get_reg has already reported it

      if (got.offset !== want.offset)
        `uvm_error("MACRO", $sformatf("%s offset differs: generated 0x%0h, macros 0x%0h",
                                      want.reg_name, want.offset, got.offset))
      if (got.fields.size() !== want.fields.size())
        `uvm_error("MACRO", $sformatf("%s field count differs: generated %0d, macros %0d",
                                      want.reg_name, want.fields.size(), got.fields.size()))

      foreach (want.fields[j]) begin
        axi_lite_field wf = want.fields[j];
        axi_lite_field gf = got.get_field(wf.field_name);
        if (gf == null) continue;
        num_compared++;

        if (gf.lsb !== wf.lsb)
          `uvm_error("MACRO", $sformatf("%s.%s lsb differs: generated %0d, macros %0d",
                                        want.reg_name, wf.field_name, wf.lsb, gf.lsb))
        if (gf.width !== wf.width)
          `uvm_error("MACRO", $sformatf("%s.%s width differs: generated %0d, macros %0d",
                                        want.reg_name, wf.field_name, wf.width, gf.width))
        if (gf.mask !== wf.mask)
          `uvm_error("MACRO", $sformatf("%s.%s mask differs: generated 0x%0h, macros 0x%0h",
                                        want.reg_name, wf.field_name, wf.mask, gf.mask))
        if (gf.reset_value !== wf.reset_value)
          `uvm_error("MACRO", $sformatf("%s.%s reset differs: generated 0x%0h, macros 0x%0h",
                                        want.reg_name, wf.field_name, wf.reset_value,
                                        gf.reset_value))
        // The access mode is the one thing the macro path states by
        // hand, so a disagreement here is a transcription error in
        // corsair_example_macro_model.sv rather than a tool problem.
        if (gf.access !== wf.access)
          `uvm_error("MACRO", $sformatf("%s.%s access differs: generated %s, macros %s",
                                        want.reg_name, wf.field_name,
                                        axi_lite_access_short(wf.access),
                                        axi_lite_access_short(gf.access)))
      end
    end

    `uvm_info("MACRO", $sformatf(
              "the generated model and the macro-built model agree on %0d register(s) and %0d field(s)",
              reg_model.regs.size(), num_compared), UVM_LOW)
  endfunction

endclass : corsair_example_macro_test
