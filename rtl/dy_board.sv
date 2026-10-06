// Dooyong board (PLAN M4): everything below the MiSTer framework.
// dy_sys (CPUs, video, sound) + dy_sdram, plus the ioctl download handling,
// so the simulation exercises exactly what the RBF contains.
//
// ioctl indices (MRA):
//   0    ROM stream = the SDRAM image of PLAN 4.3 from byte 0
//        (tools/make_mra.py proves each MRA reproduces it). The main and
//        sound program ranges (0x000000-0x03FFFF, 0x040000-0x04FFFF) are
//        also copied into dy_sys's program-ROM BRAMs as they stream past.
//   1    game ID byte (dy_pkg G_*), sampled while the core is held in reset
//   254  DIP switches: byte 0 = DSWA, byte 1 = DSWB (raw port values)
// The core is held in reset during any download and until the SDRAM is
// initialised.

module dy_board #(
    parameter int  CPU_DIV   = 12,
    parameter int  CLK_HZ    = 96000000,
    parameter int  V_TOTAL   = 260,
    parameter int  PIX_NUM   = 1,
    parameter int  PIX_DEN   = 12,
    parameter bit  SHORT_INIT = 1'b0
) (
    input  logic        clk,
    input  logic        i_sdram_rst_n,  // PLL locked
    input  logic        i_reset,

    input  logic        i_ioctl_download,
    input  logic        i_ioctl_wr,
    input  logic [26:0] i_ioctl_addr,
    input  logic [7:0]  i_ioctl_dout,
    input  logic [15:0] i_ioctl_index,
    output logic        o_ioctl_wait,

    input  logic [7:0]  i_p1,
    input  logic [7:0]  i_p2,
    input  logic [7:0]  i_system,
    input  logic [3:0]  i_crt_h,        // OSD CRT position (2 px steps) and flip
    input  logic [2:0]  i_crt_v,
    input  logic        i_osd_flip,

    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_de,
    output logic        o_ce_pix,
    output logic signed [15:0] o_audio,
    output logic [3:0]  o_game,
    output logic [11:0] o_pen,          // sim/debug: {black, pen} with the pixel
    output logic        o_vbl_irq,      // sim/debug: start of line 248

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,

    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

  // ------------------------------------------------------------------ ioctl
  wire rom_wr = i_ioctl_download && i_ioctl_wr && i_ioctl_index[7:0] == 8'd0;

  logic [3:0] game = 4'd3;
  logic [7:0] dswa = 8'hFF, dswb = 8'hFF;
  always_ff @(posedge clk) begin
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd1 && i_ioctl_addr == 27'd0)
      game <= i_ioctl_dout[3:0];
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd254) begin
      if (i_ioctl_addr == 27'd0) dswa <= i_ioctl_dout;
      if (i_ioctl_addr == 27'd1) dswb <= i_ioctl_dout;
    end
  end
  assign o_game = game;

  // program ROMs into BRAM: main 0x000000-0x01FFFF, sound 0x040000-0x04FFFF
  wire        dl_main  = rom_wr && i_ioctl_addr[26:18] == 9'd0;          // 0x000000-0x03FFFF
  wire        dl_snd   = rom_wr && i_ioctl_addr[26:16] == 11'h004;       // 0x040000-0x04FFFF
  wire [18:0] dl_baddr = dl_snd ? {3'b100, i_ioctl_addr[15:0]} : {1'b0, i_ioctl_addr[17:0]};

  // ------------------------------------------------------------------ SDRAM
  logic        sd_ready, dl_busy;
  logic        rom_req, rom_gnt, rom_rv;
  logic [22:0] rom_addr;
  logic [31:0] rom_data;
  logic [17:0] oki_addr;
  logic [7:0]  oki_data;
  logic        oki_ok;

  dy_sdram #(.P_SHORT_INIT(SHORT_INIT), .REFRESH_PERIOD(CLK_HZ / 128000),
             .INIT_CYCLES(CLK_HZ / 10000)) u_sdram (
    .clk(clk), .rst_n(i_sdram_rst_n), .o_ready(sd_ready),
    .i_dl_wr(rom_wr), .i_dl_addr(i_ioctl_addr[24:0]), .i_dl_data(i_ioctl_dout),
    .o_dl_busy(dl_busy),
    .i_gfx_req(rom_req), .i_gfx_addr(rom_addr), .o_gfx_gnt(rom_gnt),
    .o_gfx_rv(rom_rv), .o_gfx_data(rom_data),
    .i_oki_addr(oki_addr), .o_oki_data(oki_data), .o_oki_ok(oki_ok),
    .o_dbg_refreshes(), .o_dbg_dl_words(),
    .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));
  assign o_ioctl_wait = dl_busy;

  // ------------------------------------------------------------------ core
  logic core_rst_n;
  always_ff @(posedge clk) core_rst_n <= !i_reset && !i_ioctl_download && sd_ready;

  logic        latch_we_unused;
  logic [7:0]  latch_unused;
  logic [15:0] d0, d1, d2, d3;

  // FREE_TIMING: sync keeps running (black picture) during the ROM download
  // and SDRAM init instead of stopping, so the MiSTer scaler never loses the
  // signal (it showed a green "no input" screen for about a second); dy_sys
  // releases the core on the timing's power-on phase, so the game starts as
  // a plain reset release would.
  dy_sys #(.CPU_DIV(CPU_DIV), .CLK_HZ(CLK_HZ), .V_TOTAL(V_TOTAL),
           .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN), .FREE_TIMING(1'b1)) u_sys (
    .clk(clk), .rst_n(core_rst_n), .i_pwr_rst_n(i_sdram_rst_n), .i_game(game),
    .i_crt_h(i_crt_h), .i_crt_v(i_crt_v), .i_osd_flip(i_osd_flip),
    .i_dl_we(dl_main || dl_snd), .i_dl_addr(dl_baddr), .i_dl_data(i_ioctl_dout),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data), .i_oki_ok(oki_ok),
    .o_audio(o_audio),
    .i_p1(i_p1), .i_p2(i_p2), .i_system(i_system), .i_dswa(dswa), .i_dswb(dswb),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr),
    .i_rom_gnt(rom_gnt), .i_rom_rv(rom_rv), .i_rom_data(rom_data),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de),
    .o_hblank(o_hblank), .o_vblank(o_vblank), .o_hs(o_hs), .o_vs(o_vs),
    .o_pen(o_pen), .o_vbl_irq(o_vbl_irq), .o_ce_pix(o_ce_pix),
    .o_snd_latch(latch_unused), .o_snd_latch_we(latch_we_unused),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc),
    .o_dbg_rom_writes(d0), .o_dbg_bank_hi(d1), .o_cpu_pc_dbg(d2),
    .o_dbg_snd_rom_writes(d3));

endmodule
