// Dooyong Z80-family main system (PLAN M2): main Z80, program ROM, work RAM,
// bus decode, control registers, inputs, and the video (dy_video).
//
// Sound (M3): dy_snd, the sound Z80 with YM2151 and M6295, fed by the
// sound latch. The main CPU never reads anything back from it (spec 4).
//
// Clocks: one system clock (96 MHz on hardware; the simulation may run it
// lower). CPU enable = clk / CPU_DIV (8 MHz). The pixel enable comes from a
// fractional divider: PIX_NUM / PIX_DEN of the clock. MAME's parity frame
// is 512 x 256 at 60 Hz = 7,864,320 pixels per second (spec 5.3), which
// keeps the CPU/video cycle ratio identical to MAME's for M2 comparisons.
// Hardware (M4): PIX_NUM/PIX_DEN = 1/12 (exact 8 MHz at 96 MHz) and
// V_TOTAL = 260 (60.10 Hz); the MAME parity values stay the defaults for
// simulation. Real totals remain research item R1.
//
// Program ROM is in BRAM (zero wait states, as MAME's Z80 has none; no
// SDRAM arbitration with the renderer). Loaded through the download port.
//
// Games: lastday, gulfstrm, pollux, flytiger, bluehawk and primella-family
// memory maps (driver 802-918; spec 3).
//
// i_system is the generic Z80 SYSTEM port (spec 9.2: 0 Coin1, 1 Start1,
// 2 Coin2, 3 Start2, 4 Service1, active low). lastday, gulfstrm and pollux
// read their own bit orders; they are rebuilt here, including the vblank
// input of gulfstrm and pollux (bit 4, low during MAME's 2.5 ms vblank).
//
// 68000 family (superx, rshark, popbingo; spec 3.7, 5.2): fx68k main CPU at
// 8 MHz (10 MHz on popbingo) from two-phase fractional enables, no wait
// states (DTACK within the cycle, as MAME's memory model), IRQ5 at line 248
// and IRQ6 at line 120, both HOLD_LINE, autovectored. The T80 is held in
// reset on these games and fx68k on the others. One 128K x 16 program ROM
// and one 32K x 16 work RAM serve both CPU families (the Z80 uses byte
// lanes: its 4 KB work RAM at offset 0, the primella 1 KB RAM at 0x1000).

module dy_sys #(
    parameter int CPU_DIV = 12,
    parameter int CLK_HZ  = 96000000,
    parameter int V_TOTAL = 256,           // dy_video lines per frame
    parameter int PIX_NUM = 786432,        // 7,864,320 / 10
    parameter int PIX_DEN = 9600000,       // 96,000,000 / 10
    // 1 on the MiSTer board: video timing runs from i_pwr_rst_n and keeps
    // sync during the core reset (dy_video FREE_TIMING); 0 = M1/M2 behaviour
    parameter bit FREE_TIMING = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,          // core reset request (active low)
    input  logic        i_pwr_rst_n,    // FREE_TIMING: power-on reset of the video timing
    input  logic [3:0]  i_game,
    input  logic [3:0]  i_crt_h,        // OSD CRT position and flip (dy_video)
    input  logic [2:0]  i_crt_v,
    input  logic        i_osd_flip,

    // program ROM download: 0x00000-0x3FFFF main CPU, 0x40000-0x4FFFF sound CPU
    input  logic        i_dl_we,
    input  logic [18:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,

    // M6295 sample ROM (256 KB, SDRAM 0x080000)
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,
    output logic signed [15:0] o_audio,

    // inputs, active low (spec 9.2, 9.3)
    input  logic [7:0]  i_p1,
    input  logic [7:0]  i_p2,
    input  logic [7:0]  i_system,
    input  logic [7:0]  i_dswa,
    input  logic [7:0]  i_dswb,

    // graphics ROM port (see dy_video)
    output logic        o_rom_req,
    output logic [22:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic [11:0] o_pen,
    output logic        o_vbl_irq,
    output logic        o_ce_pix,

    // to the sound side (M3)
    output logic [7:0]  o_snd_latch,
    output logic        o_snd_latch_we,

    // debug / gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_rom_writes,  // writes into 0x0000-0xBFFF (spec 3.8, T2)
    output logic [15:0] o_dbg_bank_hi,     // bankswitch writes with bits 3-7 set
    output logic [15:0] o_cpu_pc_dbg,      // address of the last opcode fetch
    output logic [15:0] o_dbg_snd_rom_writes  // sound CPU writes into its ROM range (spec T4)
);

  import dy_pkg::*;

  // ================================================================ reset
  // FREE_TIMING: the video counters and the pixel enable run from power-on;
  // tim_evt (dy_video) marks the pixel enable that would start the power-on
  // line, and while the core is in reset that enable reloads the counters
  // and the pixel accumulator to their reset values instead. The core reset
  // is released on the clock after such a reload (tim_fresh), so the first
  // clock of the running core sees exactly the state a plain reset release
  // gives (M1/M2 verified) and the CPUs start at MAME's beam position.
  logic tim_evt, tim_fresh, run_q;
  logic crst_n;
  wire  tim_load = FREE_TIMING && !crst_n && tim_evt;
  wire  tim_rst  = FREE_TIMING ? (!i_pwr_rst_n || tim_load) : !rst_n;
  assign crst_n  = FREE_TIMING ? (rst_n && i_pwr_rst_n && (run_q || tim_fresh)) : rst_n;
  always_ff @(posedge clk) begin
    tim_fresh <= tim_rst;
    run_q     <= crst_n;
  end

  // ================================================================ enables
  logic [4:0]  cpu_cnt;
  logic        ce_cpu;
  logic        ce_pix /* verilator public_flat_rd */;
  logic [23:0] pix_acc;
  always_ff @(posedge clk) begin
    if (!crst_n) begin
      cpu_cnt <= '0;
      ce_cpu  <= 1'b0;
    end else begin
      ce_cpu  <= (cpu_cnt == 5'd0);
      cpu_cnt <= (cpu_cnt == 5'(CPU_DIV - 1)) ? 5'd0 : cpu_cnt + 5'd1;
    end
  end
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      ce_pix  <= 1'b0;
      pix_acc <= '0;
    end else begin
      if (pix_acc + 24'(PIX_NUM) >= 24'(PIX_DEN)) begin
        pix_acc <= pix_acc + 24'(PIX_NUM) - 24'(PIX_DEN);
        ce_pix  <= 1'b1;
      end else begin
        pix_acc <= pix_acc + 24'(PIX_NUM);
        ce_pix  <= 1'b0;
      end
    end
  end

  // ================================================================ CPU
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  cpu_dout /* verilator public_flat_rd */;
  logic [7:0]  cpu_din;
  logic        m1_n, mreq_n, iorq_n, wr_n, rfsh_n, halt_n, busak_n;
  logic        rd_n /* verilator public_flat_rd */;
  logic        int_n;

  wire m68k = is_m68k(i_game);

  T80s u_cpu (
    .RESET_n(crst_n && !m68k), .CLK(clk), .CEN(ce_cpu),
    .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .DI(cpu_din),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
    .A(A), .DOUT(cpu_dout));

  // vblank IRQ, held until acknowledged (irq0_line_hold, spec 5.1); the
  // acknowledge cycle reads 0xFF (RST 38h in IM0, ignored in IM1)
  wire int_ack = !m1_n && !iorq_n;
  logic vbl_irq;
  always_ff @(posedge clk) begin
    if (!crst_n)       int_n <= 1'b1;
    else if (vbl_irq) int_n <= 1'b0;
    else if (int_ack) int_n <= 1'b1;
  end

  // ================================================================ decode
  wire is_ft = (i_game == G_FLYTIGER);
  wire is_bh = (i_game == G_BLUEHAWK);
  wire is_pr = is_primella(i_game);
  wire is_ld = (i_game == G_LASTDAY);
  wire is_gs = (i_game == G_GULFSTRM);
  wire is_px = (i_game == G_POLLUX);
  wire is_gp = is_gs || is_px;          // gulfstrm and pollux share a map
  wire mem   = !mreq_n && rfsh_n;

  typedef enum logic [3:0] {
    D_NONE, D_ROM, D_BANK, D_WRAM, D_SPR, D_PAL, D_TXT, D_IO, D_XRAM
  } dsel_t;
  dsel_t sel;
  always_comb begin
    sel = D_NONE;
    if (A[15] == 1'b0)          sel = D_ROM;
    else if (A[15:14] == 2'b10) sel = D_BANK;
    else if (is_ft) begin
      case (A[15:12])
        4'hC: sel = D_SPR;
        4'hD: sel = D_WRAM;
        4'hE: sel = A[11] ? D_PAL : D_IO;
        4'hF: sel = D_TXT;
        default: ;
      endcase
    end else if (is_bh) begin
      case (A[15:12])
        4'hC: sel = A[11] ? D_PAL : D_IO;
        4'hD: sel = D_TXT;
        4'hE: sel = D_SPR;
        4'hF: sel = D_WRAM;
        default: ;
      endcase
    end else if (is_ld) begin
      // C000-C7FF I/O and tilemap regs, C800 palette, D000 text, E000 work
      // RAM, F000 sprite RAM
      case (A[15:12])
        4'hC: sel = A[11] ? D_PAL : D_IO;
        4'hD: sel = D_TXT;
        4'hE: sel = D_WRAM;
        4'hF: sel = D_SPR;
        default: ;
      endcase
    end else if (is_gp) begin
      // C000 work RAM, D000 sprite RAM, E000 text, F000-F7FF I/O, F800
      // palette (banked on pollux)
      case (A[15:12])
        4'hC: sel = D_WRAM;
        4'hD: sel = D_SPR;
        4'hE: sel = D_TXT;
        4'hF: sel = A[11] ? D_PAL : D_IO;
        default: ;
      endcase
    end else if (is_pr) begin
      // C000 work RAM, D000-D3FF extra RAM ("scratchpad?", T15), E000 text,
      // F000-F7FF palette (write-only: reads are unmapped = 0), F800 I/O
      case (A[15:12])
        4'hC: sel = D_WRAM;
        4'hD: sel = (A[11:10] == 2'b00) ? D_XRAM : D_NONE;
        4'hE: sel = D_TXT;
        4'hF: sel = A[11] ? D_IO : D_PAL;
        default: ;
      endcase
    end
  end

  // write strobe: one clock at the start of each memory write cycle
  logic wr_q;
  always_ff @(posedge clk) wr_q <= mem && !wr_n;
  wire wr /* verilator public_flat_rd */ = mem && !wr_n && !wr_q;

  // ================================================================ memories
  // 68000 main CPU signals (declared here, used from the memories on)
  logic        m_rw, m_asn, m_ldsn, m_udsn, m_fc0, m_fc1, m_fc2;
  logic [23:1] m_a /* verilator public_flat_rd */;
  logic [15:0] m_dout /* verilator public_flat_rd */;
  logic [15:0] m_din;
  wire  [19:0] m_ba = {m_a[19:1], 1'b0};         // global_mask(0xfffff)
  logic        m_ram_we, m_pbx, m_ctrl_w, m_latch_w;
  logic [15:0] m_ram_off;

  // program ROM, 16-bit words, byte 2n = high byte (68000 order; the Z80
  // reads byte lanes)
  logic [2:0]  bank;
  logic [7:0]  rom_q, wram_q, xram_q;
  logic [15:0] rom16_q;
  wire  [16:0] rom_a = (sel == D_BANK) ? {bank, A[13:0]} : {2'b00, A[14:0]};
  logic        rom_lane_q;
  dy_dpram #(.AW(17), .DW(16)) u_rom (
    .clk(clk),
    .addr_a(i_dl_addr[17:1]), .d_a({i_dl_data, i_dl_data}), .we_a(i_dl_we && !i_dl_addr[18]),
    .be_a(i_dl_addr[0] ? 2'b01 : 2'b10), .q_a(),
    .addr_b(m68k ? m_a[17:1] : {1'b0, rom_a[16:1]}), .q_b(rom16_q));
  always_ff @(posedge clk) rom_lane_q <= rom_a[0];
  assign rom_q = rom_lane_q ? rom16_q[7:0] : rom16_q[15:8];

  // work RAM, 16-bit words. Z80: 4 KB work RAM at byte 0, primella
  // 0xD000-0xD3FF at byte 0x1000. 68000: the 64 KB work RAM window (the
  // sprite hole 0xD000-0xDFFF is in dy_video), popbingo 0x0DC000 RAM in
  // that hole.
  wire  [15:0] z_ram_off = (sel == D_XRAM) ? {6'b000100, A[9:0]} : {4'b0000, A[11:0]};
  wire  [15:0] ram_off   = m68k ? m_ram_off : z_ram_off;
  logic [15:0] ram16_q;
  logic        ram_lane_q;
  dy_dpram #(.AW(15), .DW(16)) u_ram (
    .clk(clk),
    .addr_a(ram_off[15:1]),
    .d_a(m68k ? m_dout : {cpu_dout, cpu_dout}),
    .we_a(m68k ? m_ram_we : (wr && (sel == D_WRAM || sel == D_XRAM))),
    .be_a(m68k ? {~m_udsn, ~m_ldsn} : (z_ram_off[0] ? 2'b01 : 2'b10)),
    .q_a(ram16_q),
    .addr_b(15'd0), .q_b());
  always_ff @(posedge clk) ram_lane_q <= z_ram_off[0];
  assign wram_q = ram_lane_q ? ram16_q[7:0] : ram16_q[15:8];
  assign xram_q = wram_q;

  // ================================================================ registers
  logic [7:0] ctrl;
  logic       flip, pal_bank, pri_swap, spr_dis;
  always_comb begin
    flip     = 1'b0;
    pal_bank = 1'b0;
    pri_swap = 1'b0;
    spr_dis  = 1'b0;
    if (is_ld) begin
      flip     = ctrl[6];
      spr_dis  = ctrl[4];               // sprites off (spec 10.1)
    end else if (is_gp) begin
      flip     = ctrl[0];
      pal_bank = is_px && ctrl[1];      // gulfstrm has no banked palette (spec 6.1)
    end else if (is_ft) begin
      flip     = ctrl[0];
      pal_bank = ctrl[3];
      pri_swap = ctrl[4];
    end else if (is_bh) begin
      flip     = ctrl != 8'd0;          // whole byte (spec 9.1)
    end else if (is_pr) begin
      flip     = ctrl[4];
      pri_swap = ctrl[3];               // text layer below fg0 (spec 11.6)
    end else if (m68k) begin
      flip     = ctrl[0];
      pri_swap = ctrl[4];               // bg2_priority (spec 11.7)
    end
  end

  // I/O page offsets (A[11:0] within 0xE000 on flytiger, 0xC000 on bluehawk,
  // 0xF000 on the primella family)
  wire [11:0] io = A[11:0];
  logic       tm_we;
  logic [1:0] tm_layer;
  logic       io_bank_w, io_ctrl_w, io_latch_w;
  always_comb begin
    tm_we      = 1'b0;
    tm_layer   = 2'd0;
    io_bank_w  = 1'b0;
    io_ctrl_w  = 1'b0;
    io_latch_w = 1'b0;
    if (wr && sel == D_IO) begin
      if (is_ft) begin
        io_bank_w  = io == 12'h000;
        io_ctrl_w  = io == 12'h010;
        io_latch_w = io == 12'h020;
        if (io[11:3] == 9'h006) begin tm_we = 1'b1; tm_layer = 2'd0; end   // E030-E037 bg0
        if (io[11:3] == 9'h008) begin tm_we = 1'b1; tm_layer = 2'd1; end   // E040-E047 fg0
      end else if (is_bh) begin
        io_ctrl_w  = io == 12'h000;                                         // flip_screen_w
        io_bank_w  = io == 12'h008;
        io_latch_w = io == 12'h010;
        if (io[11:3] == 9'h003) begin tm_we = 1'b1; tm_layer = 2'd2; end   // C018-C01F fg1
        if (io[11:3] == 9'h008) begin tm_we = 1'b1; tm_layer = 2'd0; end   // C040-C047 bg0
        if (io[11:3] == 9'h009) begin tm_we = 1'b1; tm_layer = 2'd1; end   // C048-C04F fg0
      end else if (is_ld) begin
        io_ctrl_w  = io == 12'h010;                                         // lastday_ctrl_w
        io_bank_w  = io == 12'h011;
        io_latch_w = io == 12'h012;
        if (io[11:3] == 9'h000) begin tm_we = 1'b1; tm_layer = 2'd0; end   // C000-C007 bg0
        if (io[11:3] == 9'h001) begin tm_we = 1'b1; tm_layer = 2'd1; end   // C008-C00F fg0
      end else if (is_gp) begin
        io_bank_w  = io == 12'h000;
        io_ctrl_w  = io == 12'h008;                                         // pollux_ctrl_w
        io_latch_w = io == 12'h010;
        if (io[11:3] == 9'h003) begin tm_we = 1'b1; tm_layer = 2'd0; end   // F018-F01F bg0
        if (io[11:3] == 9'h004) begin tm_we = 1'b1; tm_layer = 2'd1; end   // F020-F027 fg0
      end else if (is_pr) begin
        io_ctrl_w  = io == 12'h800;                                         // primella_ctrl_w (+ bank)
        io_latch_w = io == 12'h810;
        if (io[11:3] == 9'h180) begin tm_we = 1'b1; tm_layer = 2'd0; end   // FC00-FC07 bg0
        if (io[11:3] == 9'h181) begin tm_we = 1'b1; tm_layer = 2'd1; end   // FC08-FC0F fg0
      end
    end
  end

  // per-game SYSTEM ports (spec 9.2) from the generic one
  logic       vbl_in /* verilator public_flat_rd */;   // MAME screen vblank: 2.5 ms from line 248
  wire  [7:0] g = i_system;
  wire  [7:0] sys_ld = {g[0], g[2], g[4], 1'b1, 1'b0, g[3], 1'b1, g[1]};    // tilt active high, idle 0
  wire  [7:0] sys_gp = {1'b1, g[3], g[1], !vbl_in, 1'b1, g[4], g[2], g[0]};

  logic [7:0] io_q;
  always_comb begin
    io_q = 8'h00;                      // unmapped reads return 0 (spec 3)
    if (is_ld) begin
      case (io)
        12'h010: io_q = sys_ld;
        12'h011: io_q = i_p1;
        12'h012: io_q = i_p2;
        12'h013: io_q = i_dswa;
        12'h014: io_q = i_dswb;
        default: ;
      endcase
    end else if (is_gp) begin
      case (io)
        12'h000: io_q = i_dswa;
        12'h001: io_q = i_dswb;
        12'h002: io_q = is_gs ? i_p2 : i_p1;   // gulfstrm swaps P1/P2 (driver 850-851)
        12'h003: io_q = is_gs ? i_p1 : i_p2;
        12'h004: io_q = sys_gp;
        default: ;
      endcase
    end else if (is_ft) begin
      case (io)
        12'h000: io_q = i_p1;
        12'h002: io_q = i_p2;
        12'h004: io_q = i_system;
        12'h006: io_q = i_dswa;
        12'h008: io_q = i_dswb;
        default: ;
      endcase
    end else if (is_bh) begin
      case (io)
        12'h000: io_q = i_dswa;
        12'h001: io_q = i_dswb;
        12'h002: io_q = i_p1;
        12'h003: io_q = i_p2;
        12'h004: io_q = i_system;
        default: ;
      endcase
    end else if (is_pr) begin
      case (io)
        12'h800: io_q = i_dswa;
        12'h810: io_q = i_dswb;
        12'h820: io_q = i_p1;
        12'h830: io_q = i_p2;
        12'h840: io_q = i_system;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    o_snd_latch_we <= 1'b0;
    if (!crst_n) begin
      bank             <= 3'd0;
      ctrl             <= 8'd0;
      o_snd_latch      <= 8'd0;
      o_dbg_rom_writes <= '0;
      o_dbg_bank_hi    <= '0;
    end else begin
      if (io_bank_w) begin
        bank <= cpu_dout[2:0];
        if (cpu_dout[7:3] != 5'd0) o_dbg_bank_hi <= o_dbg_bank_hi + 16'd1;
      end
      if (io_ctrl_w) ctrl <= cpu_dout;
      if (m_ctrl_w)  ctrl <= m_dout[7:0];
      if (io_ctrl_w && is_pr) bank <= cpu_dout[2:0];   // ctrl bits 0-2 (spec 3.1)
      if (io_latch_w) begin
        o_snd_latch    <= cpu_dout;
        o_snd_latch_we <= 1'b1;
      end
      if (m_latch_w) begin
        o_snd_latch    <= m_dout[7:0];
        o_snd_latch_we <= 1'b1;
      end
      if (wr && (sel == D_ROM || sel == D_BANK)) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
    end
    if (!m1_n && mem) o_cpu_pc_dbg <= A;
  end

  // ================================================================ 68000 main CPU
  // two-phase enables at twice the CPU clock (8 MHz; 10 MHz on popbingo),
  // fractional so 10 MHz works from any system clock
  localparam int F68    = 8000000;
  localparam int F68_PB = 10000000;
  logic [27:0] m_acc;
  logic        m_ph, en_phi1, en_phi2;
  wire  [27:0] m_step = 28'(2 * ((i_game == G_POPBINGO) ? F68_PB : F68));
  always_ff @(posedge clk) begin
    en_phi1 <= 1'b0;
    en_phi2 <= 1'b0;
    if (!crst_n || !m68k) begin
      m_acc <= '0;
      m_ph  <= 1'b0;
    end else if (m_acc + m_step >= 28'(CLK_HZ)) begin
      m_acc <= m_acc + m_step - 28'(CLK_HZ);
      m_ph  <= !m_ph;
      if (m_ph) en_phi2 <= 1'b1;
      else      en_phi1 <= 1'b1;
    end else
      m_acc <= m_acc + m_step;
  end

  logic        m_dtackn, m_vpan;
  logic [2:0]  m_ipl;
  fx68k u_m68k (
    .clk(clk), .HALTn(1'b1),
    .extReset(!crst_n || !m68k), .pwrUp(!crst_n || !m68k),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(m_rw), .ASn(m_asn), .LDSn(m_ldsn), .UDSn(m_udsn),
    .E(), .VMAn(),
    .FC0(m_fc0), .FC1(m_fc1), .FC2(m_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(m_dtackn), .VPAn(m_vpan),
    .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(~m_ipl[0]), .IPL1n(~m_ipl[1]), .IPL2n(~m_ipl[2]),
    .iEdb(m_din), .oEdb(m_dout), .eab(m_a));

  // interrupts: IRQ6 (line 120) and IRQ5 (line 248), HOLD_LINE until the
  // acknowledge cycle of that level; autovectored (spec 5.2)
  wire  m_iack = m_fc2 && m_fc1 && m_fc0 && !m_asn;
  logic irq5_p, irq6_p;
  logic irq6_line;
  always_ff @(posedge clk) begin
    if (!crst_n || !m68k) begin
      irq5_p <= 1'b0;
      irq6_p <= 1'b0;
    end else begin
      if (vbl_irq)   irq5_p <= 1'b1;
      if (irq6_line) irq6_p <= 1'b1;
      if (m_iack && m_a[3:1] == 3'd5) irq5_p <= 1'b0;
      if (m_iack && m_a[3:1] == 3'd6) irq6_p <= 1'b0;
    end
  end
  assign m_ipl  = irq6_p ? 3'd6 : (irq5_p ? 3'd5 : 3'd0);
  assign m_vpan = !m_iack;

  // decode (spec 3.7): rshark/popbingo I/O at 0x0C0000 and RAM at 0x040000,
  // superx at 0x080000 and 0x0D0000
  wire        m_sx   = (i_game == G_SUPERX);
  wire        m_pb   = (i_game == G_POPBINGO);
  wire [3:0]  m_ioh  = m_sx ? 4'h8 : 4'hC;
  wire [3:0]  m_ramh = m_sx ? 4'hD : 4'h4;
  wire        m_selrom = m_ba < 20'h40000;
  wire        m_inram  = m_ba[19:16] == m_ramh;
  wire        m_selspr = m_inram && m_ba[15:12] == 4'hD;
  assign      m_pbx    = m_pb && m_ba[19:5] == 15'(20'h0DC000 >> 5);
  wire        m_selram = (m_inram && !m_selspr) || m_pbx;
  wire        m_inio   = m_ba[19:16] == m_ioh;
  wire [15:0] m_off    = m_ba[15:0];
  wire        m_selpal = m_inio && m_off[15:12] == 4'h8;
  assign      m_ram_off = m_pbx ? {11'h680, m_ba[4:0]} : m_ba[15:0];   // popbingo 0x0DC000 -> 0xD000

  // bus: writes are acknowledged at once and performed when a data strobe
  // appears; reads take the registered memory output. DTACK arrives well
  // inside S4, so no wait states.
  typedef enum logic [1:0] {MB_IDLE, MB_RD, MB_ACK} mbst_t;
  mbst_t       mbst;
  logic        m_wdone;
  logic [15:0] m_rdata;
  wire         m_ds    = !(m_udsn && m_ldsn);
  wire         m_wstb /* verilator public_flat_rd */ = (mbst == MB_ACK) && !m_rw && m_ds && !m_wdone;
  assign m_dtackn = !(mbst == MB_ACK);
  assign m_din    = m_rdata;
  always_ff @(posedge clk) begin
    if (!crst_n || !m68k) begin
      mbst    <= MB_IDLE;
      m_wdone <= 1'b0;
    end else begin
      case (mbst)
        MB_IDLE: if (!m_asn && !m_iack) begin
          if (!m_rw) begin
            mbst    <= MB_ACK;
            m_wdone <= 1'b0;
          end else if (m_ds) mbst <= MB_RD;
        end
        MB_RD: mbst <= MB_ACK;     // memory address presented last clock
        MB_ACK: begin
          if (m_wstb) m_wdone <= 1'b1;
          if (m_asn) mbst <= MB_IDLE;
        end
        default: mbst <= MB_IDLE;
      endcase
    end
  end

  // read mux (one clock after the address: BRAM outputs)
  logic [15:0] m_spr_q16;
  always_ff @(posedge clk) begin
    if (mbst == MB_RD) begin
      if (m_selrom)       m_rdata <= rom16_q;
      else if (m_selram)  m_rdata <= ram16_q;
      else if (m_selspr)  m_rdata <= m_spr_q16;
      else if (m_inio && m_off == 16'h0002) m_rdata <= {i_dswb, i_dswa};
      else if (m_inio && m_off == 16'h0004) m_rdata <= {i_p2, i_p1};
      else if (m_inio && m_off == 16'h0006) m_rdata <= {8'h00, i_system};   // upper byte reads 0 (MAME)
      else                m_rdata <= 16'h0000;                              // unmapped (and palette) read 0
    end
  end

  // writes
  assign m_ram_we  = m_wstb && m_selram;
  wire   m_spr_we  = m_wstb && m_selspr;
  wire   m_pal_we  = m_wstb && m_selpal;
  wire   m_lds_w   = m_wstb && !m_ldsn && m_inio;         // byte registers on the low lane
  assign m_latch_w = m_lds_w && m_off == 16'h0012;        // 0x..0013
  assign m_ctrl_w  = m_lds_w && m_off == 16'h0014;        // 0x..0015
  // tilemap registers: umask16(0x00ff), register N at base + 2N + 1
  wire   m_tm_bg   = m_lds_w && m_off[15:5] == 11'h200;   // 0x4000-0x401F: bg0, bg1
  wire   m_tm_fg   = m_lds_w && m_off[15:5] == 11'h600 && !m_pb;   // 0xC000-0xC01F: fg0, fg1
  wire   m_tm_we   = m_tm_bg || m_tm_fg;
  wire [1:0] m_tm_layer = m_tm_bg ? (m_off[4] ? 2'd3 : 2'd0) : (m_off[4] ? 2'd2 : 2'd1);

  // ================================================================ video
  wire [11:0] pal_a = (is_ft || is_px) ? {pal_bank, A[10:0]} : {1'b0, A[10:0]};
  wire        v_pal_we = m68k ? m_pal_we : (wr && sel == D_PAL);
  wire        v_txt_we = !m68k && wr && sel == D_TXT;
  wire        v_spr_we = m68k ? m_spr_we : (wr && sel == D_SPR);
  wire [11:0] v_addr   = m68k ? m_ba[11:0] : ((sel == D_PAL) ? pal_a : A[11:0]);
  logic [7:0] pal_q, txt_q, spr_q;

  dy_video #(.V_TOTAL(V_TOTAL), .FREE_TIMING(FREE_TIMING)) u_video (
    .clk(clk), .rst_n(crst_n), .ce_pix(ce_pix), .i_game(i_game),
    .i_tim_rst(tim_rst), .o_tim_evt(tim_evt),
    .i_crt_h(i_crt_h), .i_crt_v(i_crt_v), .i_osd_flip(i_osd_flip),
    .i_cpu_addr(v_addr), .i_cpu_din(m68k ? m_dout : {8'h00, cpu_dout}), .i_cpu_be({~m_udsn, ~m_ldsn}),
    .i_pal_we(v_pal_we), .i_txt_we(v_txt_we), .i_spr_we(v_spr_we),
    .o_pal_dout(pal_q), .o_txt_dout(txt_q), .o_spr_dout(spr_q), .o_spr_dout16(m_spr_q16),
    .i_tm_we(m68k ? m_tm_we : tm_we), .i_tm_layer(m68k ? m_tm_layer : tm_layer),
    .i_tm_reg(m68k ? m_off[3:1] : A[2:0]), .i_tm_din(m68k ? m_dout[7:0] : cpu_dout),
    .i_flip(flip), .i_pal_bank(pal_bank), .i_pri_swap(pri_swap), .i_spr_disable(spr_dis),
    .o_rom_req(o_rom_req), .o_rom_addr(o_rom_addr),
    .i_rom_gnt(i_rom_gnt), .i_rom_rv(i_rom_rv), .i_rom_data(i_rom_data),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de),
    .o_hblank(o_hblank), .o_vblank(o_vblank), .o_hs(o_hs), .o_vs(o_vs),
    .o_pen(o_pen), .o_vbl_irq(vbl_irq), .o_irq6(irq6_line),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc));
  assign o_vbl_irq = vbl_irq;
  assign o_ce_pix  = ce_pix;

  // MAME's screen vblank line (set_vblank_time 2500 us, spec 5.3): high
  // from the vblank IRQ for 2.5 ms, counted in pixel enables
  localparam longint PIX_HZ  = longint'(CLK_HZ) * PIX_NUM / PIX_DEN;
  localparam int     VBL_PIX = int'((PIX_HZ * 25 + 5000) / 10000);
  logic [15:0] vbl_cnt;
  always_ff @(posedge clk) begin
    if (!crst_n) begin
      vbl_in  <= 1'b0;
      vbl_cnt <= '0;
    end else if (vbl_irq) begin
      vbl_in  <= 1'b1;
      vbl_cnt <= 16'(VBL_PIX - 1);
    end else if (ce_pix && vbl_in) begin
      if (vbl_cnt == 16'd0) vbl_in <= 1'b0;
      else                  vbl_cnt <= vbl_cnt - 16'd1;
    end
  end

  // ================================================================ read mux
  // registered every clock; RAM outputs are one clock behind the address,
  // so the value is settled long before the CPU samples it (CPU_DIV clocks)
  always_ff @(posedge clk) begin
    if (int_ack) cpu_din <= 8'hFF;
    else begin
      case (sel)
        D_ROM, D_BANK: cpu_din <= rom_q;
        D_WRAM:        cpu_din <= wram_q;
        D_SPR:         cpu_din <= spr_q;
        D_PAL:         cpu_din <= is_pr ? 8'h00 : pal_q;
        D_XRAM:        cpu_din <= xram_q;
        D_TXT:         cpu_din <= txt_q;
        D_IO:          cpu_din <= io_q;
        default:       cpu_din <= 8'h00;
      endcase
    end
  end

  // ================================================================ sound
  // YM2151 3.579545 MHz (flytiger, bluehawk), 4 MHz on the primella family
  // (16 MHz / 4, spec 2). lastday, gulfstrm, pollux: 2x YM2203 at 4 MHz
  // (lastday) or 1.5 MHz, sound CPU 8 MHz on gulfstrm.
  dy_snd #(.CPU_DIV(2 * CPU_DIV), .YM_NUM(3579545), .YM4_NUM(4000000), .YM_DEN(CLK_HZ),
           .OKI_DIV(8 * CPU_DIV)) u_snd (
    .clk(clk), .rst_n(crst_n), .i_ym_4m(is_pr || m68k),
    .i_opn(is_ld || is_gp), .i_opn_map_ld(is_ld || is_gs), .i_opn_15(is_gp), .i_cpu_fast(is_gs),
    .i_dl_we(i_dl_we && i_dl_addr[18]), .i_dl_addr(i_dl_addr[15:0]), .i_dl_data(i_dl_data),
    .i_latch(o_snd_latch),
    .o_oki_addr(o_oki_addr), .i_oki_data(i_oki_data), .i_oki_ok(i_oki_ok),
    .o_audio(o_audio), .o_ym_l(), .o_ym_r(), .o_oki(),
    .o_dbg_rom_writes(o_dbg_snd_rom_writes));

  wire unused = &{1'b0, halt_n, busak_n, rd_n};

endmodule
