// Created with Corsair v1.0.4
package corsair_example_regs_pkg;

parameter CSR_BASE_ADDR = 0;
parameter CSR_DATA_WIDTH = 32;
parameter CSR_ADDR_WIDTH = 12;

// ID
parameter CSR_ID_ADDR = 12'h0;
parameter CSR_ID_RESET = 32'ha7110001;

// ID.VERSION
parameter CSR_ID_VERSION_WIDTH = 16;
parameter CSR_ID_VERSION_LSB = 0;
parameter CSR_ID_VERSION_MASK = 32'hffff;
parameter CSR_ID_VERSION_RESET = 16'h1;

// ID.MAGIC
parameter CSR_ID_MAGIC_WIDTH = 16;
parameter CSR_ID_MAGIC_LSB = 16;
parameter CSR_ID_MAGIC_MASK = 32'hffff0000;
parameter CSR_ID_MAGIC_RESET = 16'ha711;


// CTRL
parameter CSR_CTRL_ADDR = 12'h4;
parameter CSR_CTRL_RESET = 32'h8000;

// CTRL.ENABLE
parameter CSR_CTRL_ENABLE_WIDTH = 1;
parameter CSR_CTRL_ENABLE_LSB = 0;
parameter CSR_CTRL_ENABLE_MASK = 32'h1;
parameter CSR_CTRL_ENABLE_RESET = 1'h0;

// CTRL.MODE
parameter CSR_CTRL_MODE_WIDTH = 2;
parameter CSR_CTRL_MODE_LSB = 1;
parameter CSR_CTRL_MODE_MASK = 32'h6;
parameter CSR_CTRL_MODE_RESET = 2'h0;
typedef enum {
    CSR_CTRL_MODE_IDLE = 2'h0, //Do nothing.
    CSR_CTRL_MODE_STREAM = 2'h1, //Continuous streaming.
    CSR_CTRL_MODE_SINGLE = 2'h2, //One frame then stop.
    CSR_CTRL_MODE_LOOPBACK = 2'h3 //Echo input to output.
} csrctrl_mode_t;

// CTRL.GAIN
parameter CSR_CTRL_GAIN_WIDTH = 8;
parameter CSR_CTRL_GAIN_LSB = 8;
parameter CSR_CTRL_GAIN_MASK = 32'hff00;
parameter CSR_CTRL_GAIN_RESET = 8'h80;

// CTRL.THRESH
parameter CSR_CTRL_THRESH_WIDTH = 12;
parameter CSR_CTRL_THRESH_LSB = 16;
parameter CSR_CTRL_THRESH_MASK = 32'hfff0000;
parameter CSR_CTRL_THRESH_RESET = 12'h0;


// STATUS
parameter CSR_STATUS_ADDR = 12'h8;
parameter CSR_STATUS_RESET = 32'h0;

// STATUS.BUSY
parameter CSR_STATUS_BUSY_WIDTH = 1;
parameter CSR_STATUS_BUSY_LSB = 0;
parameter CSR_STATUS_BUSY_MASK = 32'h1;
parameter CSR_STATUS_BUSY_RESET = 1'h0;

// STATUS.ERRCODE
parameter CSR_STATUS_ERRCODE_WIDTH = 4;
parameter CSR_STATUS_ERRCODE_LSB = 4;
parameter CSR_STATUS_ERRCODE_MASK = 32'hf0;
parameter CSR_STATUS_ERRCODE_RESET = 4'h0;
typedef enum {
    CSR_STATUS_ERRCODE_NONE = 4'h0, //No error.
    CSR_STATUS_ERRCODE_OVERFLOW = 4'h1, //Input overflowed.
    CSR_STATUS_ERRCODE_UNDERFLOW = 4'h2 //Input underflowed.
} csrstatus_errcode_t;


// IRQ
parameter CSR_IRQ_ADDR = 12'hc;
parameter CSR_IRQ_RESET = 32'h0;

// IRQ.DONE
parameter CSR_IRQ_DONE_WIDTH = 1;
parameter CSR_IRQ_DONE_LSB = 0;
parameter CSR_IRQ_DONE_MASK = 32'h1;
parameter CSR_IRQ_DONE_RESET = 1'h0;

// IRQ.ERROR
parameter CSR_IRQ_ERROR_WIDTH = 1;
parameter CSR_IRQ_ERROR_LSB = 1;
parameter CSR_IRQ_ERROR_MASK = 32'h2;
parameter CSR_IRQ_ERROR_RESET = 1'h0;


// CMD
parameter CSR_CMD_ADDR = 12'h10;
parameter CSR_CMD_RESET = 32'h0;

// CMD.OPCODE
parameter CSR_CMD_OPCODE_WIDTH = 8;
parameter CSR_CMD_OPCODE_LSB = 0;
parameter CSR_CMD_OPCODE_MASK = 32'hff;
parameter CSR_CMD_OPCODE_RESET = 8'h0;

// CMD.ARG
parameter CSR_CMD_ARG_WIDTH = 16;
parameter CSR_CMD_ARG_LSB = 8;
parameter CSR_CMD_ARG_MASK = 32'hffff00;
parameter CSR_CMD_ARG_RESET = 16'h0;

// CMD.FLAG
parameter CSR_CMD_FLAG_WIDTH = 1;
parameter CSR_CMD_FLAG_LSB = 24;
parameter CSR_CMD_FLAG_MASK = 32'h1000000;
parameter CSR_CMD_FLAG_RESET = 1'h0;


// SCRATCH
parameter CSR_SCRATCH_ADDR = 12'h14;
parameter CSR_SCRATCH_RESET = 32'h0;

// SCRATCH.VALUE
parameter CSR_SCRATCH_VALUE_WIDTH = 32;
parameter CSR_SCRATCH_VALUE_LSB = 0;
parameter CSR_SCRATCH_VALUE_MASK = 32'hffffffff;
parameter CSR_SCRATCH_VALUE_RESET = 32'h0;


// EVENT
parameter CSR_EVENT_ADDR = 12'h18;
parameter CSR_EVENT_RESET = 32'h0;

// EVENT.COUNT
parameter CSR_EVENT_COUNT_WIDTH = 8;
parameter CSR_EVENT_COUNT_LSB = 0;
parameter CSR_EVENT_COUNT_MASK = 32'hff;
parameter CSR_EVENT_COUNT_RESET = 8'h0;

// EVENT.ARM
parameter CSR_EVENT_ARM_WIDTH = 1;
parameter CSR_EVENT_ARM_LSB = 16;
parameter CSR_EVENT_ARM_MASK = 32'h10000;
parameter CSR_EVENT_ARM_RESET = 1'h0;


endpackage