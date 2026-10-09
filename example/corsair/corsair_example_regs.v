// Created with Corsair v1.0.4

module corsair_example_regs #(
    parameter ADDR_W = 12,
    parameter DATA_W = 32,
    parameter STRB_W = DATA_W / 8
)(
    // System
    input clk,
    input rst,
    // ID.VERSION
    // ID.MAGIC

    // CTRL.ENABLE
    output  csr_ctrl_enable_out,
    // CTRL.MODE
    output [1:0] csr_ctrl_mode_out,
    // CTRL.GAIN
    output [7:0] csr_ctrl_gain_out,
    // CTRL.THRESH
    output [11:0] csr_ctrl_thresh_out,

    // STATUS.BUSY
    input  csr_status_busy_in,
    // STATUS.ERRCODE
    input [3:0] csr_status_errcode_in,

    // IRQ.DONE
    input csr_irq_done_set,
    // IRQ.ERROR
    input csr_irq_error_set,

    // CMD.OPCODE
    output [7:0] csr_cmd_opcode_out,
    // CMD.ARG
    output [15:0] csr_cmd_arg_out,
    // CMD.FLAG
    output  csr_cmd_flag_out,

    // SCRATCH.VALUE

    // EVENT.COUNT
    input [7:0] csr_event_count_in,
    // EVENT.ARM
    output  csr_event_arm_out,

    // AXI
    input  [ADDR_W-1:0] axil_awaddr,
    input  [2:0]        axil_awprot,
    input               axil_awvalid,
    output              axil_awready,
    input  [DATA_W-1:0] axil_wdata,
    input  [STRB_W-1:0] axil_wstrb,
    input               axil_wvalid,
    output              axil_wready,
    output [1:0]        axil_bresp,
    output              axil_bvalid,
    input               axil_bready,

    input  [ADDR_W-1:0] axil_araddr,
    input  [2:0]        axil_arprot,
    input               axil_arvalid,
    output              axil_arready,
    output [DATA_W-1:0] axil_rdata,
    output [1:0]        axil_rresp,
    output              axil_rvalid,
    input               axil_rready
);
wire              wready;
wire [ADDR_W-1:0] waddr;
wire [DATA_W-1:0] wdata;
wire              wen;
wire [STRB_W-1:0] wstrb;
wire [DATA_W-1:0] rdata;
wire              rvalid;
wire [ADDR_W-1:0] raddr;
wire              ren;
    reg [ADDR_W-1:0] waddr_int;
    reg [ADDR_W-1:0] raddr_int;
    reg [DATA_W-1:0] wdata_int;
    reg [STRB_W-1:0] strb_int;
    reg              awflag;
    reg              wflag;
    reg              arflag;
    reg              rflag;

    reg              axil_bvalid_int;
    reg [DATA_W-1:0] axil_rdata_int;
    reg              axil_rvalid_int;

    assign axil_awready = ~awflag;
    assign axil_wready  = ~wflag;
    assign axil_bvalid  = axil_bvalid_int;
    assign waddr        = waddr_int;
    assign wdata        = wdata_int;
    assign wstrb        = strb_int;
    assign wen          = awflag && wflag;
    assign axil_bresp   = 'd0; // always okay

    always @(posedge clk) begin
        if (rst == 1'b0) begin
            waddr_int       <= 'd0;
            wdata_int       <= 'd0;
            strb_int        <= 'd0;
            awflag          <= 1'b0;
            wflag           <= 1'b0;
            axil_bvalid_int <= 1'b0;
        end else begin
            if (axil_awvalid == 1'b1 && awflag == 1'b0) begin
                awflag    <= 1'b1;
                waddr_int <= axil_awaddr;
            end else if (wen == 1'b1 && wready == 1'b1) begin
                awflag    <= 1'b0;
            end

            if (axil_wvalid == 1'b1 && wflag == 1'b0) begin
                wflag     <= 1'b1;
                wdata_int <= axil_wdata;
                strb_int  <= axil_wstrb;
            end else if (wen == 1'b1 && wready == 1'b1) begin
                wflag     <= 1'b0;
            end

            if (axil_bvalid_int == 1'b1 && axil_bready == 1'b1) begin
                axil_bvalid_int <= 1'b0;
            end else if ((axil_wvalid == 1'b1 && awflag == 1'b1) || (axil_awvalid == 1'b1 && wflag == 1'b1) || (wflag == 1'b1 && awflag == 1'b1)) begin
                axil_bvalid_int <= wready;
            end
        end
    end

    assign axil_arready = ~arflag;
    assign axil_rdata   = axil_rdata_int;
    assign axil_rvalid  = axil_rvalid_int;
    assign raddr        = raddr_int;
    assign ren          = arflag && ~rflag;
    assign axil_rresp   = 'd0; // always okay

    always @(posedge clk) begin
        if (rst == 1'b0) begin
            raddr_int       <= 'd0;
            arflag          <= 1'b0;
            rflag           <= 1'b0;
            axil_rdata_int  <= 'd0;
            axil_rvalid_int <= 1'b0;
        end else begin
            if (axil_arvalid == 1'b1 && arflag == 1'b0) begin
                arflag    <= 1'b1;
                raddr_int <= axil_araddr;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                arflag    <= 1'b0;
            end

            if (rvalid == 1'b1 && ren == 1'b1 && rflag == 1'b0) begin
                rflag <= 1'b1;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                rflag <= 1'b0;
            end

            if (rvalid == 1'b1 && axil_rvalid_int == 1'b0) begin
                axil_rdata_int  <= rdata;
                axil_rvalid_int <= 1'b1;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                axil_rvalid_int <= 1'b0;
            end
        end
    end

//------------------------------------------------------------------------------
// CSR:
// [0x0] - ID - Identification. Constant, so a correct read proves the AXI4-Lite path reaches this block.
//------------------------------------------------------------------------------
wire [31:0] csr_id_rdata;


wire csr_id_ren;
assign csr_id_ren = ren && (raddr == 12'h0);
reg csr_id_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_id_ren_ff <= 1'b0;
    end else begin
        csr_id_ren_ff <= csr_id_ren;
    end
end
//---------------------
// Bit field:
// ID[15:0] - VERSION - Map version.
// access: ro, hardware: f
//---------------------
reg [15:0] csr_id_version_ff;

assign csr_id_rdata[15:0] = csr_id_version_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_id_version_ff <= 16'h1;
    end else  begin
      begin
            csr_id_version_ff <= csr_id_version_ff;
        end
    end
end


//---------------------
// Bit field:
// ID[31:16] - MAGIC - Always 0xA711.
// access: ro, hardware: f
//---------------------
reg [15:0] csr_id_magic_ff;

assign csr_id_rdata[31:16] = csr_id_magic_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_id_magic_ff <= 16'ha711;
    end else  begin
      begin
            csr_id_magic_ff <= csr_id_magic_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x4] - CTRL - Main control. Deliberately mixes a byte-aligned field, an unaligned field and an enumerated field, so every field-write strategy the UVC can pick is exercised by one register.
//------------------------------------------------------------------------------
wire [31:0] csr_ctrl_rdata;
assign csr_ctrl_rdata[7:3] = 5'h0;
assign csr_ctrl_rdata[31:28] = 4'h0;

wire csr_ctrl_wen;
assign csr_ctrl_wen = wen && (waddr == 12'h4);

wire csr_ctrl_ren;
assign csr_ctrl_ren = ren && (raddr == 12'h4);
reg csr_ctrl_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_ctrl_ren_ff <= 1'b0;
    end else begin
        csr_ctrl_ren_ff <= csr_ctrl_ren;
    end
end
//---------------------
// Bit field:
// CTRL[0] - ENABLE - Enable the block.
// access: rw, hardware: o
//---------------------
reg  csr_ctrl_enable_ff;

assign csr_ctrl_rdata[0] = csr_ctrl_enable_ff;

assign csr_ctrl_enable_out = csr_ctrl_enable_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_ctrl_enable_ff <= 1'b0;
    end else  begin
     if (csr_ctrl_wen) begin
            if (wstrb[0]) begin
                csr_ctrl_enable_ff <= wdata[0];
            end
        end else begin
            csr_ctrl_enable_ff <= csr_ctrl_enable_ff;
        end
    end
end


//---------------------
// Bit field:
// CTRL[2:1] - MODE - Operating mode.
// access: rw, hardware: o
//---------------------
reg [1:0] csr_ctrl_mode_ff;

assign csr_ctrl_rdata[2:1] = csr_ctrl_mode_ff;

assign csr_ctrl_mode_out = csr_ctrl_mode_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_ctrl_mode_ff <= 2'h0;
    end else  begin
     if (csr_ctrl_wen) begin
            if (wstrb[0]) begin
                csr_ctrl_mode_ff[1:0] <= wdata[2:1];
            end
        end else begin
            csr_ctrl_mode_ff <= csr_ctrl_mode_ff;
        end
    end
end


//---------------------
// Bit field:
// CTRL[15:8] - GAIN - Byte-aligned on purpose: a write to this field alone needs no read.
// access: rw, hardware: o
//---------------------
reg [7:0] csr_ctrl_gain_ff;

assign csr_ctrl_rdata[15:8] = csr_ctrl_gain_ff;

assign csr_ctrl_gain_out = csr_ctrl_gain_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_ctrl_gain_ff <= 8'h80;
    end else  begin
     if (csr_ctrl_wen) begin
            if (wstrb[1]) begin
                csr_ctrl_gain_ff[7:0] <= wdata[15:8];
            end
        end else begin
            csr_ctrl_gain_ff <= csr_ctrl_gain_ff;
        end
    end
end


//---------------------
// Bit field:
// CTRL[27:16] - THRESH - Straddles byte lane 2 and 3, so a write to this field alone needs a read-modify-write.
// access: rw, hardware: o
//---------------------
reg [11:0] csr_ctrl_thresh_ff;

assign csr_ctrl_rdata[27:16] = csr_ctrl_thresh_ff;

assign csr_ctrl_thresh_out = csr_ctrl_thresh_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_ctrl_thresh_ff <= 12'h0;
    end else  begin
     if (csr_ctrl_wen) begin
            if (wstrb[2]) begin
                csr_ctrl_thresh_ff[7:0] <= wdata[23:16];
            end
            if (wstrb[3]) begin
                csr_ctrl_thresh_ff[11:8] <= wdata[27:24];
            end
        end else begin
            csr_ctrl_thresh_ff <= csr_ctrl_thresh_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x8] - STATUS - Read-only status driven by hardware.
//------------------------------------------------------------------------------
wire [31:0] csr_status_rdata;
assign csr_status_rdata[3:1] = 3'h0;
assign csr_status_rdata[31:8] = 24'h0;


wire csr_status_ren;
assign csr_status_ren = ren && (raddr == 12'h8);
reg csr_status_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_status_ren_ff <= 1'b0;
    end else begin
        csr_status_ren_ff <= csr_status_ren;
    end
end
//---------------------
// Bit field:
// STATUS[0] - BUSY - Block is busy.
// access: ro, hardware: i
//---------------------
reg  csr_status_busy_ff;

assign csr_status_rdata[0] = csr_status_busy_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_status_busy_ff <= 1'b0;
    end else  begin
              begin            csr_status_busy_ff <= csr_status_busy_in;
        end
    end
end


//---------------------
// Bit field:
// STATUS[7:4] - ERRCODE - Last error.
// access: ro, hardware: i
//---------------------
reg [3:0] csr_status_errcode_ff;

assign csr_status_rdata[7:4] = csr_status_errcode_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_status_errcode_ff <= 4'h0;
    end else  begin
              begin            csr_status_errcode_ff <= csr_status_errcode_in;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0xc] - IRQ - Write-1-to-clear interrupt flags. A read-modify-write here would clear flags nobody asked to clear, which is the hazard the UVC's field_write() avoids.
//------------------------------------------------------------------------------
wire [31:0] csr_irq_rdata;
assign csr_irq_rdata[31:2] = 30'h0;

wire csr_irq_wen;
assign csr_irq_wen = wen && (waddr == 12'hc);

wire csr_irq_ren;
assign csr_irq_ren = ren && (raddr == 12'hc);
reg csr_irq_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_irq_ren_ff <= 1'b0;
    end else begin
        csr_irq_ren_ff <= csr_irq_ren;
    end
end
//---------------------
// Bit field:
// IRQ[0] - DONE - Operation completed.
// access: rw1c, hardware: s
//---------------------
reg  csr_irq_done_ff;

assign csr_irq_rdata[0] = csr_irq_done_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_irq_done_ff <= 1'b0;
    end else  begin
        if (csr_irq_done_set) begin
            csr_irq_done_ff <= 1'b1;
        end else     if (csr_irq_wen) begin
            if (wstrb[0] && wdata[0]) begin
                csr_irq_done_ff <= 1'b0;
            end
        end else begin
            csr_irq_done_ff <= csr_irq_done_ff;
        end
    end
end


//---------------------
// Bit field:
// IRQ[1] - ERROR - Error occurred.
// access: rw1c, hardware: s
//---------------------
reg  csr_irq_error_ff;

assign csr_irq_rdata[1] = csr_irq_error_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_irq_error_ff <= 1'b0;
    end else  begin
        if (csr_irq_error_set) begin
            csr_irq_error_ff <= 1'b1;
        end else     if (csr_irq_wen) begin
            if (wstrb[0] && wdata[1]) begin
                csr_irq_error_ff <= 1'b0;
            end
        end else begin
            csr_irq_error_ff <= csr_irq_error_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x10] - CMD - Write-only command. Cannot be read back, so a field write here cannot read-modify-write and must use the shadow value.
//------------------------------------------------------------------------------
wire [31:0] csr_cmd_rdata;
assign csr_cmd_rdata[31:25] = 7'h0;

wire csr_cmd_wen;
assign csr_cmd_wen = wen && (waddr == 12'h10);

//---------------------
// Bit field:
// CMD[7:0] - OPCODE - Command opcode.
// access: wo, hardware: o
//---------------------
reg [7:0] csr_cmd_opcode_ff;

assign csr_cmd_rdata[7:0] = 8'h0;

assign csr_cmd_opcode_out = csr_cmd_opcode_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_cmd_opcode_ff <= 8'h0;
    end else  begin
     if (csr_cmd_wen) begin
            if (wstrb[0]) begin
                csr_cmd_opcode_ff[7:0] <= wdata[7:0];
            end
        end else begin
            csr_cmd_opcode_ff <= csr_cmd_opcode_ff;
        end
    end
end


//---------------------
// Bit field:
// CMD[23:8] - ARG - Command argument.
// access: wo, hardware: o
//---------------------
reg [15:0] csr_cmd_arg_ff;

assign csr_cmd_rdata[23:8] = 16'h0;

assign csr_cmd_arg_out = csr_cmd_arg_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_cmd_arg_ff <= 16'h0;
    end else  begin
     if (csr_cmd_wen) begin
            if (wstrb[1]) begin
                csr_cmd_arg_ff[7:0] <= wdata[15:8];
            end
            if (wstrb[2]) begin
                csr_cmd_arg_ff[15:8] <= wdata[23:16];
            end
        end else begin
            csr_cmd_arg_ff <= csr_cmd_arg_ff;
        end
    end
end


//---------------------
// Bit field:
// CMD[24] - FLAG - Single bit at the top of the word. Write-only and not byte-aligned, so writing it alone can only be done from the shadow value.
// access: wo, hardware: o
//---------------------
reg  csr_cmd_flag_ff;

assign csr_cmd_rdata[24] = 1'b0;

assign csr_cmd_flag_out = csr_cmd_flag_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_cmd_flag_ff <= 1'b0;
    end else  begin
     if (csr_cmd_wen) begin
            if (wstrb[3]) begin
                csr_cmd_flag_ff <= wdata[24];
            end
        end else begin
            csr_cmd_flag_ff <= csr_cmd_flag_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x14] - SCRATCH - Plain read/write word, for a whole-register access that needs no field handling at all.
//------------------------------------------------------------------------------
wire [31:0] csr_scratch_rdata;

wire csr_scratch_wen;
assign csr_scratch_wen = wen && (waddr == 12'h14);

wire csr_scratch_ren;
assign csr_scratch_ren = ren && (raddr == 12'h14);
reg csr_scratch_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_scratch_ren_ff <= 1'b0;
    end else begin
        csr_scratch_ren_ff <= csr_scratch_ren;
    end
end
//---------------------
// Bit field:
// SCRATCH[31:0] - VALUE - Anything you like.
// access: rw, hardware: n
//---------------------
reg [31:0] csr_scratch_value_ff;

assign csr_scratch_rdata[31:0] = csr_scratch_value_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_scratch_value_ff <= 32'h0;
    end else  begin
     if (csr_scratch_wen) begin
            if (wstrb[0]) begin
                csr_scratch_value_ff[7:0] <= wdata[7:0];
            end
            if (wstrb[1]) begin
                csr_scratch_value_ff[15:8] <= wdata[15:8];
            end
            if (wstrb[2]) begin
                csr_scratch_value_ff[23:16] <= wdata[23:16];
            end
            if (wstrb[3]) begin
                csr_scratch_value_ff[31:24] <= wdata[31:24];
            end
        end else begin
            csr_scratch_value_ff <= csr_scratch_value_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x18] - EVENT - Event counter that clears when read. Reading it to service one field is destructive, so the UVC will not read-modify-write this register.
//------------------------------------------------------------------------------
wire [31:0] csr_event_rdata;
assign csr_event_rdata[15:8] = 8'h0;
assign csr_event_rdata[31:17] = 15'h0;

wire csr_event_wen;
assign csr_event_wen = wen && (waddr == 12'h18);

wire csr_event_ren;
assign csr_event_ren = ren && (raddr == 12'h18);
reg csr_event_ren_ff;
always @(posedge clk) begin
    if (!rst) begin
        csr_event_ren_ff <= 1'b0;
    end else begin
        csr_event_ren_ff <= csr_event_ren;
    end
end
//---------------------
// Bit field:
// EVENT[7:0] - COUNT - Events since the last read. Cleared by the read itself.
// access: roc, hardware: i
//---------------------
reg [7:0] csr_event_count_ff;

assign csr_event_rdata[7:0] = csr_event_count_ff;


always @(posedge clk) begin
    if (!rst) begin
        csr_event_count_ff <= 8'h0;
    end else  begin
          if (csr_event_ren && !csr_event_ren_ff) begin
            csr_event_count_ff <= 8'h0;
        end else            begin            csr_event_count_ff <= csr_event_count_in;
        end
    end
end


//---------------------
// Bit field:
// EVENT[16] - ARM - Plain control bit sharing the register with a read-clear field.
// access: rw, hardware: o
//---------------------
reg  csr_event_arm_ff;

assign csr_event_rdata[16] = csr_event_arm_ff;

assign csr_event_arm_out = csr_event_arm_ff;

always @(posedge clk) begin
    if (!rst) begin
        csr_event_arm_ff <= 1'b0;
    end else  begin
     if (csr_event_wen) begin
            if (wstrb[2]) begin
                csr_event_arm_ff <= wdata[16];
            end
        end else begin
            csr_event_arm_ff <= csr_event_arm_ff;
        end
    end
end


//------------------------------------------------------------------------------
// Write ready
//------------------------------------------------------------------------------
assign wready = 1'b1;

//------------------------------------------------------------------------------
// Read address decoder
//------------------------------------------------------------------------------
reg [31:0] rdata_ff;
always @(posedge clk) begin
    if (!rst) begin
        rdata_ff <= 32'h0;
    end else if (ren) begin
        case (raddr)
            12'h0: rdata_ff <= csr_id_rdata;
            12'h4: rdata_ff <= csr_ctrl_rdata;
            12'h8: rdata_ff <= csr_status_rdata;
            12'hc: rdata_ff <= csr_irq_rdata;
            12'h10: rdata_ff <= csr_cmd_rdata;
            12'h14: rdata_ff <= csr_scratch_rdata;
            12'h18: rdata_ff <= csr_event_rdata;
            default: rdata_ff <= 32'h0;
        endcase
    end else begin
        rdata_ff <= 32'h0;
    end
end
assign rdata = rdata_ff;

//------------------------------------------------------------------------------
// Read data valid
//------------------------------------------------------------------------------
reg rvalid_ff;
always @(posedge clk) begin
    if (!rst) begin
        rvalid_ff <= 1'b0;
    end else if (ren && rvalid) begin
        rvalid_ff <= 1'b0;
    end else if (ren) begin
        rvalid_ff <= 1'b1;
    end
end

assign rvalid = rvalid_ff;

endmodule