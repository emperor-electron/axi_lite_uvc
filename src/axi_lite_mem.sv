///////////////////////////////////////////////////////////////////
// Filename: axi_lite_mem.sv
// Author  : Benjamin Tamayo
// Date    : 2026-09-01
// Purpose : The slave agent's memory and response model: what a read
//           returns, what a write keeps, and which addresses answer with
//           SLVERR or DECERR instead of OKAY.
///////////////////////////////////////////////////////////////////
//
// This class has no counterpart in a stream UVC, and it is the reason an
// AXI4-Lite slave agent is a bigger idea than an AXI4-Stream one. A
// stream sink only has to decide TREADY; an AXI4-Lite slave has to
// answer. Every read needs data and a response, every write needs a
// response, and both have to be self-consistent -- a read after a write
// to the same address must return what was written, or the UVC is not a
// usable stand-in for the peripheral it replaces.
//
// Storage is a sparse associative array of *bytes*, not words. That one
// choice is what keeps this class unparameterized:
//
//   - WSTRB is a per-byte enable, so a byte-granular store applies it
//     directly instead of reconstructing a mask at some word width;
//   - a 32-bit link and a 64-bit link index the same array, so one
//     memory can back several differently sized ports;
//   - only the addresses actually touched cost anything, so a 64-bit
//     address space is free until something writes to it.
//
// Subclass it for a real model. resp_for_write()/resp_for_read() and
// do_read()/do_write() are virtual, so a peripheral model with
// side effects on access -- a FIFO behind a register, a write-1-to-clear
// bit -- is an override rather than a rewrite:
//
//   class my_periph_mem extends axi_lite_mem;
//     virtual function axi_lite_data_t do_read(axi_lite_addr_t addr,
//                                              int unsigned num_bytes);
//       if (addr == STATUS_REG) return read_status_and_clear();
//       return super.do_read(addr, num_bytes);
//     endfunction
//   endclass

// An address range that answers with something other than OKAY. Ranges
// are inclusive at both ends and are searched in the order they were
// added, so a specific range added before a broad one wins.
typedef struct {
  axi_lite_addr_t lo;
  axi_lite_addr_t hi;
  axi_lite_resp_e resp;
  string          name;
} axi_lite_region_t;

class axi_lite_mem extends uvm_object;

  `uvm_object_utils(axi_lite_mem)

  // ---- Storage ------------------------------------------------------
  // Sparse: only bytes that were written exist. Everything else reads
  // back as fill_byte() decides.
  protected byte unsigned m_bytes          [axi_lite_addr_t];

  // ---- What an untouched byte reads back as -------------------------
  // Left at 0 an unwritten memory reads as zeros, which is what a real
  // register file usually does. Set fill_from_address and an unwritten
  // byte instead reads back as a function of its own address, which
  // turns any address-decode bug into a data mismatch the very first
  // time it is read rather than only after something is written there.
  byte unsigned           default_byte                        = 8'h00;
  bit                     fill_from_address                   = 1'b0;

  // ---- Error injection ----------------------------------------------
  axi_lite_region_t       m_regions        [              $];

  // ---- Census, reported by the slave driver -------------------------
  int unsigned            num_reads                           = 0;
  int unsigned            num_writes                          = 0;

  extern function new(string name = "axi_lite_mem");

  // ---- Region management --------------------------------------------
  // Make [lo:hi] answer with `resp`. A region with AXI_LITE_OKAY is
  // legal and useful: it carves an explicit hole in a broader error
  // region added after it.
  extern virtual function void add_region(axi_lite_addr_t lo, axi_lite_addr_t hi,
                                          axi_lite_resp_e resp, string region_name = "");
  extern virtual function void clear_regions();

  // ---- The four hooks a peripheral model overrides ------------------
  extern virtual function axi_lite_resp_e resp_for_read(axi_lite_addr_t addr, axi_lite_prot_t prot);
  extern virtual function axi_lite_resp_e resp_for_write(axi_lite_addr_t addr,
                                                         axi_lite_prot_t prot);
  extern virtual function axi_lite_data_t do_read(axi_lite_addr_t addr, int unsigned num_bytes);
  extern virtual function void do_write(axi_lite_addr_t addr, axi_lite_data_t data,
                                        axi_lite_strb_t strb, int unsigned num_bytes);

  // ---- What the driver actually calls -------------------------------
  // These apply the response policy and then the access, so a DECERR
  // read does not quietly return real data and a DECERR write does not
  // quietly land in the array.
  extern virtual function axi_lite_resp_e read(axi_lite_addr_t addr, int unsigned num_bytes,
                                               axi_lite_prot_t prot, output axi_lite_data_t data);
  extern virtual function axi_lite_resp_e write(axi_lite_addr_t addr, axi_lite_data_t data,
                                                axi_lite_strb_t strb, int unsigned num_bytes,
                                                axi_lite_prot_t prot);

  // ---- Backdoor access, for a test that wants to preload or inspect
  // without generating bus traffic.
  extern virtual function byte unsigned peek_byte(axi_lite_addr_t addr);
  extern virtual function void poke_byte(axi_lite_addr_t addr, byte unsigned value);
  extern virtual function int unsigned num_bytes_written();

  // The value an untouched byte reads back as.
  extern protected virtual function byte unsigned fill_byte(axi_lite_addr_t addr);

  // Which region, if any, covers this address.
  extern protected virtual function axi_lite_resp_e region_resp(axi_lite_addr_t addr);

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function string convert2string();

endclass : axi_lite_mem

function axi_lite_mem::new(string name = "axi_lite_mem");
  super.new(name);
endfunction : new

function void axi_lite_mem::add_region(axi_lite_addr_t lo, axi_lite_addr_t hi, axi_lite_resp_e resp,
                                       string region_name = "");
  axi_lite_region_t region;
  if (hi < lo) begin
    `uvm_error("MEM_REGION", $sformatf("region '%s' has hi (0x%0h) below lo (0x%0h); ignored",
                                       region_name, hi, lo))
    return;
  end
  region.lo   = lo;
  region.hi   = hi;
  region.resp = resp;
  region.name = (region_name == "") ? $sformatf("[0x%0h:0x%0h]", lo, hi) : region_name;
  m_regions.push_back(region);
endfunction : add_region

function void axi_lite_mem::clear_regions();
  m_regions.delete();
endfunction : clear_regions

// First match wins, so a narrow OKAY hole added before a broad SLVERR
// range behaves the way the reading order suggests.
function axi_lite_resp_e axi_lite_mem::region_resp(axi_lite_addr_t addr);
  foreach (m_regions[i])
  if ((addr >= m_regions[i].lo) && (addr <= m_regions[i].hi)) return m_regions[i].resp;
  return AXI_LITE_OKAY;
endfunction : region_resp

// The default response policy ignores AxPROT: a model that wants to
// answer an unprivileged access to a privileged register with SLVERR
// overrides this and reads prot[0].
function axi_lite_resp_e axi_lite_mem::resp_for_read(axi_lite_addr_t addr, axi_lite_prot_t prot);
  return region_resp(addr);
endfunction : resp_for_read

function axi_lite_resp_e axi_lite_mem::resp_for_write(axi_lite_addr_t addr, axi_lite_prot_t prot);
  return region_resp(addr);
endfunction : resp_for_write

function byte unsigned axi_lite_mem::fill_byte(axi_lite_addr_t addr);
  // The XOR is there so that address 0 does not read back as 0 and
  // accidentally look like a correct zero-filled memory.
  return fill_from_address ? (byte'(addr[7:0]) ^ 8'hA5) : default_byte;
endfunction : fill_byte

function byte unsigned axi_lite_mem::peek_byte(axi_lite_addr_t addr);
  return m_bytes.exists(addr) ? m_bytes[addr] : fill_byte(addr);
endfunction : peek_byte

function void axi_lite_mem::poke_byte(axi_lite_addr_t addr, byte unsigned value);
  m_bytes[addr] = value;
endfunction : poke_byte

function int unsigned axi_lite_mem::num_bytes_written();
  return m_bytes.num();
endfunction : num_bytes_written

// Little-endian, which is what AXI is: byte lane 0 carries the lowest
// address, and every lane is DATA_WIDTH/8 of the way up the word.
function axi_lite_data_t axi_lite_mem::do_read(axi_lite_addr_t addr, int unsigned num_bytes);
  axi_lite_data_t data = '0;
  for (int unsigned i = 0; i < num_bytes; i++) data[i*8+:8] = peek_byte(addr + i);
  return data;
endfunction : do_read

// WSTRB is applied here rather than by the caller: a byte with its
// strobe low is not written at all, which is the whole point of having
// byte-granular storage.
function void axi_lite_mem::do_write(axi_lite_addr_t addr, axi_lite_data_t data,
                                     axi_lite_strb_t strb, int unsigned num_bytes);
  for (int unsigned i = 0; i < num_bytes; i++) if (strb[i]) m_bytes[addr+i] = data[i*8+:8];
endfunction : do_write

function axi_lite_resp_e axi_lite_mem::read(axi_lite_addr_t addr, int unsigned num_bytes,
                                            axi_lite_prot_t prot, output axi_lite_data_t data);
  axi_lite_resp_e resp = resp_for_read(addr, prot);
  num_reads++;
  // A slave that could not service the access has no data to return, so
  // returning zeros here is both what real hardware does and what stops
  // a scoreboard from checking data that was never meaningful.
  data = (resp == AXI_LITE_OKAY) ? do_read(addr, num_bytes) : '0;
  return resp;
endfunction : read

function axi_lite_resp_e axi_lite_mem::write(axi_lite_addr_t addr, axi_lite_data_t data,
                                             axi_lite_strb_t strb, int unsigned num_bytes,
                                             axi_lite_prot_t prot);
  axi_lite_resp_e resp = resp_for_write(addr, prot);
  num_writes++;
  // An errored write must not land, or a later read of the same address
  // would return data the slave said it never accepted.
  if (resp == AXI_LITE_OKAY) do_write(addr, data, strb, num_bytes);
  return resp;
endfunction : write

function void axi_lite_mem::do_copy(uvm_object rhs);
  axi_lite_mem rhs_;
  if (rhs == null) `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs)) `uvm_fatal("DO_COPY", "cast of rhs to axi_lite_mem failed")
  super.do_copy(rhs);
  m_bytes           = rhs_.m_bytes;
  m_regions         = rhs_.m_regions;
  default_byte      = rhs_.default_byte;
  fill_from_address = rhs_.fill_from_address;
  num_reads         = rhs_.num_reads;
  num_writes        = rhs_.num_writes;
endfunction : do_copy

function string axi_lite_mem::convert2string();
  string s;
  s = $sformatf(
      "%0d bytes held, %0d reads, %0d writes, fill=%s",
      m_bytes.num(),
      num_reads,
      num_writes,
      fill_from_address ? "address-derived" : $sformatf(
          "0x%02h", default_byte
      )
  );
  foreach (m_regions[i])
  s = {
    s,
    $sformatf(
        "\n  region %s [0x%0h:0x%0h] -> %s",
        m_regions[i].name,
        m_regions[i].lo,
        m_regions[i].hi,
        m_regions[i].resp.name()
    )
  };
  return s;
endfunction : convert2string
