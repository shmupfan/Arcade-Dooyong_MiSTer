// Dooyong Z80-family video (PLAN M1): timing, register latch, video RAMs,
// scanline renderer and scan-out.
//
// Reference model: sim/oracle/dy_render.py, which is pixel-exact against
// MAME 0.288 on every M0 capture. Spec sections cited as "spec N".
//
// Geometry is MAME's parity frame (spec 5.3): 512 x 256 at the pixel
// enable, visible x 64-447, y 8-247, vblank IRQ at line 248. Real totals are
// an M4 decision (research item R1).
//
// Register latch (spec 5.4, m0_findings 7.1, m1_findings 6): tilemap
// registers and the video control bits are copied at the start of line
// LATCH_LINE and the following active lines are drawn from that copy. The
// sprite list is copied into the draw buffer at line 248
// (BUFFERED_SPRITERAM8, spec 10.1). With the default latch at line 7 (end of
// vblank) the active period after vblank N shows the registers as the
// vblank handler left them with the sprite list copied at vblank N, which
// is MAME's frame N+1 whenever the game writes the registers only during
// vblank; writes during the active lines take effect from the next frame.
//
// Primella family (sadari, gundl94; spec 5.3, 11.6): MAME's visible area is
// all 256 lines and vblank starts at line 256, so here every line 0-255 is
// rendered and shown, the vblank IRQ fires at line 256 (with the 256-line
// parity frame that is line 0 of the next frame; never at power-on), and
// the registers latch at the start of the last line of the frame, when
// line 0 is rendered. The displayed frame after vblank N therefore shows
// the state MAME draws at vblank N. No sprites; the text layer goes below
// fg0 when ctrl bit 3 is set (i_pri_swap).
//
// 68000 family (superx, rshark, popbingo; spec 10.2, 11.7, 11.9): four ROM
// layers (bg0, bg1, fg0, fg1; 16x16 with the colour ROM on superx/rshark),
// pass order bg0 (pri 1), bg1 (pri 2 if ctrl bit 4 = i_pri_swap, else 1),
// fg0 (2), fg1 (2); the sprite engine in 68000 mode; popbingo combines its
// two layers into 0x100 | bg0 << 4 | bg1. CPU writes are 16-bit big-endian
// words with byte enables (i_cpu_be = {UDS, LDS}). IRQ6 at line 120.
//
// Per line L (rendered during line L-1 into one half of a double buffer):
//   1. tilemap passes in the game's order (spec 11), each setting its
//      priority bit where opaque and overwriting the pen; in parallel the
//      sprite engine (dy_spr_z80) fills its own line buffer,
//   2. resolve: sprite pen where the sprite owns the pixel and is not
//      masked, else the layer pen, else the black pen; clears the buffers.
// The pass and the sprite engine share the graphics ROM port through a
// round-robin arbiter; the port is pipelined and returns data in order.
// Scan-out reads the finished line and the palette at the pixel enable.

module dy_video #(
    parameter int LATCH_LINE = 7,
    // lines per frame: 256 = MAME's parity frame (sim, with the 60 Hz
    // fractional pixel enable); hardware uses 260 at an exact 8 MHz pixel
    // clock = 60.10 Hz (spec 5.3: PCB 15.68 kHz / 60 Hz suggests ~261; R1).
    // The extra lines are added after line 255, inside vblank.
    parameter int V_TOTAL = 256,
    // 1 (MiSTer board): the video counters run from power-on and keep sync
    // going while the core is held in reset (ROM download, SDRAM init), with
    // black RGB; i_tim_rst reloads their power-on state once a frame and the
    // system releases its reset on the clock after that reload (dy_sys), so
    // the core starts at exactly the beam position of a reset release.
    // 0 (simulation default): counters reset with rst_n, as verified in M1/M2.
    parameter bit FREE_TIMING = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ce_pix,
    input  logic        i_tim_rst,     // FREE_TIMING: synchronous counter reload
    output logic        o_tim_evt,     // FREE_TIMING: the next pixel starts the power-on line
    input  logic [3:0]  i_game,
    // OSD (m4_findings 7): CRT position, two's complement, taken at vblank
    // start; flip XORed into the board's flip screen register
    input  logic [3:0]  i_crt_h,        // picture right by 2 px a step (-16..+14)
    input  logic [2:0]  i_crt_v,        // picture down by 1 line a step (-4..+3; none on primella)
    input  logic        i_osd_flip,

    // CPU side, already decoded by the system (M2); byte wide
    input  logic [11:0] i_cpu_addr,
    input  logic [15:0] i_cpu_din,      // Z80: byte in [7:0]; 68000: word
    input  logic [1:0]  i_cpu_be,       // 68000 {UDS, LDS}; ignored on the Z80 games
    input  logic        i_pal_we,       // palette byte address (bank applied by the decoder)
    input  logic        i_txt_we,       // text RAM CPU offset (layout per game, spec 8)
    input  logic        i_spr_we,       // live sprite RAM
    output logic [7:0]  o_pal_dout,
    output logic [7:0]  o_txt_dout,
    output logic [7:0]  o_spr_dout,
    output logic [15:0] o_spr_dout16,   // 68000 word read
    input  logic        i_tm_we,
    input  logic [1:0]  i_tm_layer,     // 0 bg0, 1 fg0, 2 fg1, 3 bg1
    input  logic [2:0]  i_tm_reg,
    input  logic [7:0]  i_tm_din,
    input  logic        i_flip,
    input  logic        i_pal_bank,
    input  logic        i_pri_swap,     // flytiger ctrl bit 4; primella text priority; 68000 bg2_priority
    input  logic        i_spr_disable,  // lastday ctrl bit 4

    // graphics ROM port: accepted when o_rom_req && i_rom_gnt; i_rom_rv
    // returns accepted requests in order ([31:24] = byte at o_rom_addr)
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
    output logic [11:0] o_pen,          // {black, pen} with the pixel (sim/debug)
    output logic        o_vbl_irq,      // one clk at the start of line 248
    output logic        o_irq6,         // 68000 games: start of line 120 (spec 5.2)

    // always-on gate counters (PLAN M2)
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc
);

  import dy_pkg::*;
  cfg_t cfg;
  assign cfg = game_cfg(i_game);

  // ================================================================ timing
  logic [8:0] hcnt /* verilator public_flat_rd */;
  logic [8:0] vfull;                   // 0 .. V_TOTAL-1
  logic [7:0] vcnt /* verilator public_flat_rd */;
  assign vcnt = vfull[7:0];
  wire        vextra = vfull[8];          // lines 256.. (vblank only)
  // Power-on phase (MAME parity): MAME's screen starts at the vblank line
  // (vpos = visible bottom + 1) and its first vblank comes one frame later,
  // so the counters start at line 248 (line 256 = 0 on the primella family)
  // and that first line does not raise the IRQ. With the counters starting
  // at 0 instead, every CPU runs 8 lines late against the video from reset
  // (m3_findings 2 took this for a MAME timestamp artefact; the main CPU's
  // early writes and the stacked IRQ return addresses showed it is real).
  wire [8:0] v_pwr   = is_primella(i_game) ? 9'd0 : 9'd248;
  wire       tim_rst = FREE_TIMING ? i_tim_rst : !rst_n;
  // the pixel enable that ends line v_pwr - 1 (power-on line follows)
  assign o_tim_evt = ce_pix && hcnt == 9'd511 &&
                     ((vfull == 9'(V_TOTAL - 1)) ? 9'd0 : vfull + 9'd1) == v_pwr;
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      hcnt  <= '0;
      vfull <= v_pwr;
    end else if (ce_pix) begin
      hcnt <= hcnt + 9'd1;
      if (hcnt == 9'd511) vfull <= (vfull == 9'(V_TOTAL - 1)) ? 9'd0 : vfull + 9'd1;
    end
  end
  wire line_start = ce_pix && hcnt == 9'd0;
  wire last_line  = vfull == 9'(V_TOTAL - 1);
  wire prm        = is_primella(i_game);
  wire m68k       = is_m68k(i_game);
  // primella vblank = line 256; with V_TOTAL 256 that is the wrap to line 0,
  // which must not count at power-on (MAME's first vblank is one frame in)
  logic wrapped, started;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wrapped <= 1'b0;
      started <= 1'b0;
    end else begin
      if (line_start && last_line) wrapped <= 1'b1;
      if (line_start) started <= 1'b1;
    end
  end
  wire vbl_prm    = (V_TOTAL > 256) ? vfull == 9'd256 : (vfull == 9'd0 && wrapped);
  wire vbl_start  = line_start && (prm ? vbl_prm : (!vextra && vcnt == 8'd248 && started));
  wire latch_now  = line_start && (prm ? last_line : (!vextra && vcnt == 8'(LATCH_LINE)));
  assign o_vbl_irq = vbl_start;
  assign o_irq6    = line_start && m68k && !vextra && vcnt == 8'd120;

  // ================================================================ sync
  // Sync positions are not in the driver (R1): hsync pixels 464-495 (the
  // visible pixels are 64-447), vsync three lines from line 251 at the
  // hsync (lines 250-252 from the line start before m4_findings 7; from
  // line 250 the +3 setting would start it on the last visible line). The
  // primella family has only lines 256-259 blank (at V_TOTAL 260), which a
  // 3-line vsync fills: its vsync is lines 256-259 and the CRT V position
  // does not apply (there is no vblank to move it in).
  // The OSD CRT position moves the sync pulses only (m4_findings 7): a later
  // sync moves the picture left (up), so the sync moves against the offset.
  // Taken at the start of vblank (whole frames only). Margins: hsync starts
  // at 450-480 and ends by pixel 511, inside the blanking of 448-511 and
  // 0-63; vsync starts on lines 248-255 and ends by line 258, inside the
  // blank lines 248-259 and 0-7.
  localparam int HS_START = 464, HS_LEN = 32, VS_START = 251;
  wire [8:0] vs_prm   = 9'd256;
  wire [8:0] vbl_line = prm ? ((V_TOTAL > 256) ? 9'd256 : 9'd0) : 9'd248;
  logic [8:0] hs_beg, vs_beg;
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      hs_beg <= 9'(HS_START);
      vs_beg <= prm ? vs_prm : 9'(VS_START);
    end else if (line_start && vfull == vbl_line) begin
      hs_beg <= 9'(HS_START) - {{4{i_crt_h[3]}}, i_crt_h, 1'b0};
      vs_beg <= prm ? vs_prm : 9'(VS_START) - {{6{i_crt_v[2]}}, i_crt_v};
    end
  end
  // vsync starts and ends on an hsync leading edge: MiSTer's composite sync
  // is HS XOR VS, so a VS edge between hsyncs is a false sync pulse that
  // pulls the CRT's line timing just above the picture (m4_findings 7).
  // vs_d = lines since vs_beg, modulo the frame (in the 256-line parity
  // frame the pulse runs past the last line). No vsync on the primella
  // family in the parity frame (no blank lines).
  wire [9:0] vs_dw = {1'b0, vfull} + 10'(V_TOTAL) - {1'b0, vs_beg};
  wire [8:0] vs_d  = (vfull >= vs_beg) ? vfull - vs_beg : vs_dw[8:0];
  wire       vs_on = !(prm && V_TOTAL <= 256) &&
                     ((vs_d == 9'd0 && hcnt >= hs_beg) || vs_d == 9'd1 || vs_d == 9'd2 ||
                      (vs_d == 9'd3 && hcnt < hs_beg));
  wire       hs_on = hcnt >= hs_beg && {1'b0, hcnt} < {1'b0, hs_beg} + 10'(HS_LEN);

  // ================================================================ registers
  logic [7:0] tm_live [4][8];
  logic [7:0] tm_l    [4][8];
  logic       flip_l, bank_l, pri_l, sdis_l;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int l = 0; l < 4; l++)
        for (int r = 0; r < 8; r++) begin
          tm_live[l][r] <= 8'd0;
          tm_l[l][r]    <= 8'd0;
        end
      {flip_l, bank_l, pri_l, sdis_l} <= '0;
    end else begin
      // a write only takes effect on change (spec 7.2); storing the value
      // is equivalent here because this renderer has no tile cache
      if (i_tm_we) tm_live[i_tm_layer][i_tm_reg] <= i_tm_din;
      if (latch_now) begin
        tm_l   <= tm_live;
        flip_l <= i_flip ^ i_osd_flip;   // OSD flip (m4_findings 7)
        bank_l <= i_pal_bank;
        pri_l  <= i_pri_swap;
        sdis_l <= i_spr_disable;
      end
    end
  end

  // ================================================================ RAMs
  // palette: 2048 x 16, CPU bytes little-endian (spec 6)
  logic [10:0] pal_vaddr;
  logic [15:0] pal_q, pal_vq;
  logic        pal_lane_q, txt_lane_q;
  dy_dpram #(.AW(11), .DW(16)) u_pal (
    .clk(clk),
    .addr_a(i_cpu_addr[11:1]), .d_a(m68k ? i_cpu_din : {i_cpu_din[7:0], i_cpu_din[7:0]}), .we_a(i_pal_we),
    .be_a(m68k ? i_cpu_be : (i_cpu_addr[0] ? 2'b10 : 2'b01)), .q_a(pal_q),
    .addr_b(pal_vaddr), .q_b(pal_vq));

  // text: 2048 x 16 logical entries; CPU lane per layout (spec 8)
  wire [10:0] txt_caddr = cfg.tx_lane0 ? i_cpu_addr[11:1] : i_cpu_addr[10:0];
  wire        txt_clane = cfg.tx_lane0 ? i_cpu_addr[0]    : i_cpu_addr[11];
  logic [10:0] txt_vaddr;
  logic [15:0] txt_q, txt_vq;
  dy_dpram #(.AW(11), .DW(16)) u_txt (
    .clk(clk),
    .addr_a(txt_caddr), .d_a({i_cpu_din[7:0], i_cpu_din[7:0]}), .we_a(i_txt_we),
    .be_a(txt_clane ? 2'b10 : 2'b01), .q_a(txt_q),
    .addr_b(txt_vaddr), .q_b(txt_vq));

  always_ff @(posedge clk) begin
    pal_lane_q <= i_cpu_addr[0];
    txt_lane_q <= txt_clane;
  end
  assign o_pal_dout = pal_lane_q ? pal_q[15:8] : pal_q[7:0];
  assign o_txt_dout = txt_lane_q ? txt_q[15:8] : txt_q[7:0];

  // live sprite RAM and the draw buffer, both 1024 x 32 (word w = bytes
  // 4w..4w+3, [31:24] = byte 4w)
  //
  // The vblank copy must equal an instant snapshot of the live RAM at the
  // start of line 248, as MAME's BUFFERED_SPRITERAM8 (spec 10.1): the
  // vblank handler starts writing sprite RAM within the copy time (seen at
  // flytiger vblank 7408, m2_findings). A CPU write during the copy to a
  // word not yet copied first saves that word's old value into the buffer
  // (the copy engine gives up its read port for that clock and skips the
  // word later). Pipelined for 96 MHz timing (m4 STA): the write is
  // registered (p1), the word's copied bit looked up (p2), the save
  // decided and the old word read (p2 clock), and the live RAM written at
  // p3. The CPU's next access is at least 6 clocks away, so the delay is
  // invisible to it.
  logic [9:0]  cp_raddr;
  logic [31:0] cp_q, live_qa;
  logic        p1_we, p2_we, p3_we, p1_sn, p2_sn;
  logic [11:0] p1_a, p2_a, p3_a;
  logic [15:0] p1_d, p2_d, p3_d;       // halfword, bytes in address order
  logic [1:0]  p1_be, p2_be, p3_be;    // {even byte, odd byte}
  logic        p2_cb_w;                // p2's word already copied by the engine
  wire         p2_cb = p2_cb_w || mk_cq;             // ... or already saved
  logic [1:0]  spr_lane_q;
  dy_dpram #(.AW(10), .DW(32)) u_spr_live (
    .clk(clk),
    .addr_a(p3_we ? p3_a[11:2] : i_cpu_addr[11:2]), .d_a({2{p3_d}}), .we_a(p3_we),
    .be_a(p3_a[1] ? {2'b00, p3_be} : {p3_be, 2'b00}), .q_a(live_qa),
    .addr_b(cp_raddr), .q_b(cp_q));
  always_ff @(posedge clk) spr_lane_q <= i_cpu_addr[1:0];
  assign o_spr_dout   = live_qa[8 * (3 - spr_lane_q) +: 8];
  assign o_spr_dout16 = spr_lane_q[1] ? live_qa[15:0] : live_qa[31:16];

  logic        cp_we;
  logic [9:0]  cp_waddr;
  logic [31:0] cp_word;
  logic [9:0]  sb_raddr;
  logic [31:0] sb_q, sb_qa_unused;
  // Two halves on the 68000 games: the copy at vblank N goes into half
  // bsel and the frame shown after vblank N draws from the other half, the
  // copy of vblank N-1. Their scroll registers are written at lines 120-135
  // (IRQ6), so the registers latched at line 7 are frame N's; MAME's frame
  // N pairs them with the sprite list of vblank N-1, which is also what the
  // board shows below the write line. The Z80 games write their registers
  // in vblank and use one half (their latch picks up frame N+1's registers,
  // which MAME pairs with the copy of vblank N).
  logic bsel;
  always_ff @(posedge clk) begin
    if (!rst_n)                 bsel <= 1'b0;
    else if (vbl_start && m68k) bsel <= !bsel;
  end
  dy_dpram #(.AW(11), .DW(32)) u_spr_buf (
    .clk(clk),
    .addr_a({bsel, cp_waddr}), .d_a(cp_word), .we_a(cp_we), .be_a(4'hF), .q_a(sb_qa_unused),
    .addr_b({m68k & ~bsel, sb_raddr}), .q_b(sb_q));

  // "saved during this copy" bitmap, cleared at vblank. A CPU write needs a
  // save if its word is at or beyond the copy counter and not already
  // saved; the engine drops its copy of a word that was saved. Both
  // lookups are registered one clock ahead of their use (m4 STA: the
  // unregistered lookup-and-decide was the failing path).
  logic        snap;                   // snapshot window: vblank start to copy end
  logic [2:0]  cp_wait;
  logic [10:0] cp_i;                   // next word to copy (1024 = done)
  logic [1023:0] saved;
  logic        mk_cq, mk_eq;
  logic        rd_v, rd_eng;           // live word on cp_q this clock; from the engine
  logic [9:0]  rd_w;
  wire  [9:0]  sv_w  = p2_a[11:2];
  wire         save  = p2_we && p2_sn && !p2_cb;
  wire         eng   = snap && cp_wait == 3'd0 && !cp_i[10] && !save;
  assign cp_raddr = save ? sv_w : cp_i[9:0];
  always_ff @(posedge clk) begin
    if (vbl_start)  saved <= '0;
    else if (save)  saved[sv_w] <= 1'b1;
    mk_cq <= saved[p1_a[11:2]];
    mk_eq <= saved[cp_i[9:0]];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      snap   <= 1'b0;
      rd_v   <= 1'b0;
      rd_eng <= 1'b0;
      cp_we  <= 1'b0;
      p1_we  <= 1'b0;
      p2_we  <= 1'b0;
      p3_we  <= 1'b0;
    end else begin
      // CPU write pipeline
      p1_we <= i_spr_we;
      p1_a  <= i_cpu_addr;
      // Z80 byte: both halves, enable by address bit 0; 68000 word as is
      p1_d  <= m68k ? i_cpu_din : {i_cpu_din[7:0], i_cpu_din[7:0]};
      p1_be <= m68k ? i_cpu_be : (i_cpu_addr[0] ? 2'b01 : 2'b10);
      p1_sn <= snap;                   // issued inside the snapshot window
      p2_we <= p1_we;
      p2_a  <= p1_a;
      p2_d  <= p1_d;
      p2_be <= p1_be;
      p2_sn <= p1_sn;
      p2_cb_w <= p1_a[11:2] < cp_i[9:0] || cp_i[10];   // engine already past it
      p3_we <= p2_we;
      p3_a  <= p2_a;
      p3_d  <= p2_d;
      p3_be <= p2_be;
      // buffer writes one clock after each live read; an engine read is
      // dropped if its word was saved (mk_eq, read in the same clock)
      cp_we    <= rd_v && !(rd_eng && mk_eq);
      cp_waddr <= rd_w;
      cp_word  <= cp_q;
      rd_v     <= 1'b0;
      rd_eng   <= 1'b0;
      if (vbl_start) begin
        snap    <= 1'b1;
        cp_wait <= 3'd4;               // let writes issued before vblank land
        cp_i    <= '0;
      end else if (snap) begin
        if (cp_wait != 3'd0) cp_wait <= cp_wait - 3'd1;
        if (save) begin
          rd_v   <= 1'b1;
          rd_w   <= sv_w;
        end else if (eng) begin
          rd_v   <= 1'b1;
          rd_eng <= 1'b1;
          rd_w   <= cp_i[9:0];
          cp_i   <= cp_i + 11'd1;
        end
        if (cp_i[10] && !rd_v && !cp_we) snap <= 1'b0;
      end
    end
  end

  // ================================================================ line buffers
  logic [383:0] lvalid, lp0, lp1, lp2;
  logic [10:0]  lpen [384];
  logic [3:0]   lpen2 [384];           // popbingo: bg1's raw pen
  logic [383:0] lvalid2;               // popbingo: bg1 written (a disabled layer gives the black pen)
  logic [11:0]  obuf [2048];           // {valid, pen}; index {line[1:0], x}, x < 384

  // ================================================================ renderer
  typedef enum logic [2:0] {R_IDLE, R_PASS, R_PASS_WAIT, R_SPR_WAIT, R_RES, R_RES_END} rstate_t;
  rstate_t     rs;
  logic [7:0]  rline;
  logic [2:0]  pi;                     // pass index
  logic [15:0] rcyc;

  // pass list (spec 11): source 0 bg0, 1 fg0, 2 fg1, 3 bg1, 4 text; bit =
  // priority bit (0: pri 1, 1: pri 2, 2: pri 4). primella: no sprites, the
  // bits are unused (pri_l = text below fg0). 68000: pri_l = bg2_priority.
  // popbingo: bg1's pass writes the second pen buffer (composite).
  logic [2:0] p_src [4];
  logic [1:0] p_bit [4];
  logic [2:0] p_n;
  always_comb begin
    p_src = '{3'd0, 3'd1, 3'd4, 3'd4};
    p_bit = '{2'd0, 2'd1, 2'd2, 2'd2};
    p_n   = 3'd3;
    if (i_game == G_FLYTIGER && pri_l) begin
      p_src = '{3'd1, 3'd0, 3'd4, 3'd4};
    end else if (i_game == G_BLUEHAWK) begin
      p_src = '{3'd0, 3'd1, 3'd2, 3'd4};
      p_n   = 3'd4;
    end else if (prm && pri_l) begin
      p_src = '{3'd0, 3'd4, 3'd1, 3'd4};
    end else if (cfg.pbingo) begin
      p_src = '{3'd0, 3'd3, 3'd4, 3'd4};
      p_n   = 3'd2;
    end else if (m68k) begin
      p_src = '{3'd0, 3'd3, 3'd1, 3'd2};
      p_bit = '{2'd0, pri_l ? 2'd1 : 2'd0, 2'd1, 2'd1};
      p_n   = 3'd4;
    end
  end

  wire [2:0]       cur_src = p_src[pi[1:0]];
  wire             cur_txt = (cur_src == 3'd4);
  layer_cfg_t      cur_lc;
  always_comb begin
    case (cur_src)
      3'd0:    cur_lc = cfg.bg0;
      3'd1:    cur_lc = cfg.fg0;
      3'd3:    cur_lc = cfg.bg1;
      default: cur_lc = cfg.fg1;
    endcase
  end
  wire [1:0] lidx    = cur_txt ? 2'd0 : cur_src[1:0];
  wire [7:0] cur_r6  = tm_l[lidx][6];
  wire       cur_off = !cur_txt && (!cur_lc.present || cur_r6[4]);

  logic        lp_start, lp_done, lp_req, lp_we;
  logic [22:0] lp_addr;
  logic [8:0]  lp_x;
  logic [10:0] lp_pen;
  logic        sp_start, sp_done, sp_req, sp_fin;
  logic        lp_gnt, sp_gnt, lp_rv, sp_rv;
  logic [22:0] sp_addr;
  logic        rs_en;
  logic [8:0]  rs_x;
  logic        rs_occ, rs_cls;
  logic [10:0] rs_pen;
  logic [1:0]  wbit;
  logic        wsec;

  dy_layer_pass u_pass (
    .clk(clk), .rst_n(rst_n),
    .i_start(lp_start), .i_text(cur_txt), .i_line(rline), .i_flip(flip_l), .i_bank(bank_l),
    .i_gfx_base(cur_lc.gfx_base), .i_tile_mask(cur_lc.tile_mask),
    .i_map_base(cur_lc.map_base), .i_map_mask(cur_lc.map_mask),
    .i_opaque(cur_lc.opaque), .i_cbase(cur_lc.cbase),
    .i_reg0(tm_l[lidx][0]), .i_reg1(tm_l[lidx][1]), .i_reg3(tm_l[lidx][3]),
    .i_reg4(tm_l[lidx][4]), .i_t16(cur_lc.t16), .i_crom(cur_lc.crom),
    .i_crom_base(cur_lc.crom_base), .i_col0(cur_lc.col0), .i_layer(lidx),
    .i_fmt_a(cur_r6[5]),
    .i_tx_packed(cfg.tx_packed), .i_tx_base(SD_TX), .i_tx_half(cfg.tx_half),
    .i_tx_mask(cfg.tx_mask), .i_tx_yscroll(flip_l ? 8'(-cfg.tx_yscroll) : cfg.tx_yscroll),
    .o_rom_req(lp_req), .o_rom_addr(lp_addr),
    .i_rom_gnt(lp_gnt), .i_rom_rv(lp_rv), .i_rom_data(i_rom_data),
    .o_txt_addr(txt_vaddr), .i_txt_data(txt_vq),
    .o_lb_we(lp_we), .o_lb_x(lp_x), .o_lb_pen(lp_pen), .o_done(lp_done));

  dy_spr_z80 u_spr (
    .clk(clk), .rst_n(rst_n),
    .i_start(sp_start), .i_line(rline), .i_flip(flip_l), .i_bank(bank_l),
    .i_code_mask(cfg.spr_mask), .i_f12(cfg.spr_12bit), .i_fheight(cfg.spr_height),
    .i_ysh_ft(cfg.spr_ysh_ft), .i_ysh_bh(cfg.spr_ysh_bh), .i_m68k(m68k),
    .o_buf_addr(sb_raddr), .i_buf_data(sb_q),
    .o_rom_req(sp_req), .o_rom_addr(sp_addr),
    .i_rom_gnt(sp_gnt), .i_rom_rv(sp_rv), .i_rom_data(i_rom_data),
    .o_done(sp_done),
    .i_rs_en(rs_en), .i_rs_x(rs_x), .o_rs_occ(rs_occ), .o_rs_cls(rs_cls), .o_rs_pen(rs_pen));

  // arbiter: alternate when both request; a FIFO of owner IDs routes the
  // in-order responses back
  logic        last_sp;
  logic [31:0] own;                    // owner bit per in-flight request (1 = sprite)
  logic [4:0]  own_wp, own_rp;
  wire         pick_sp = sp_req && (!lp_req || !last_sp);
  assign o_rom_req  = lp_req || sp_req;
  assign o_rom_addr = pick_sp ? sp_addr : lp_addr;
  assign lp_gnt     = i_rom_gnt && !pick_sp;
  assign sp_gnt     = i_rom_gnt && pick_sp;
  assign lp_rv      = i_rom_rv && !own[own_rp];
  assign sp_rv      = i_rom_rv && own[own_rp];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last_sp <= 1'b0;
      own_wp  <= '0;
      own_rp  <= '0;
    end else begin
      if (o_rom_req && i_rom_gnt) begin
        own[own_wp] <= pick_sp;
        own_wp      <= own_wp + 5'd1;
        last_sp     <= pick_sp;
      end
      if (i_rom_rv) own_rp <= own_rp + 5'd1;
    end
  end

  // layer pass writes
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lvalid <= '0;
      lvalid2 <= '0;
      lp0 <= '0;
      lp1 <= '0;
      lp2 <= '0;
    end else begin
      if (lp_we && wsec) begin
        lpen2[lp_x]   <= lp_pen[3:0];
        lvalid2[lp_x] <= 1'b1;
      end
      else if (lp_we) begin
        lvalid[lp_x] <= 1'b1;
        lpen[lp_x]   <= lp_pen;
        case (wbit)
          2'd0:    lp0[lp_x] <= 1'b1;
          2'd1:    lp1[lp_x] <= 1'b1;
          default: lp2[lp_x] <= 1'b1;
        endcase
      end
      if (rs_en) begin
        lvalid[rs_x] <= 1'b0;
        lvalid2[rs_x] <= 1'b0;
        lp0[rs_x] <= 1'b0;
        lp1[rs_x] <= 1'b0;
        lp2[rs_x] <= 1'b0;
      end
    end
  end

  // resolve stage 2 (registered reads of stage 1)
  logic        r2_v, r2_lv, r2_p1, r2_p2;
  logic [10:0] r2_lpen;
  logic [8:0]  r2_x;
  wire         blocked = rs_cls ? (r2_p1 || r2_p2) : r2_p2;
  wire [11:0]  r2_out  = (rs_occ && !blocked) ? {1'b1, rs_pen}
                        : r2_lv ? {1'b1, r2_lpen} : 12'd0;

  // Render scheduling. The renderer may run up to three lines ahead of the
  // scan-out (four output line buffers), so a heavy line borrows time from
  // lighter neighbours (m1: rshark's densest lines need up to ~6,800 clocks
  // against 6,144 per line). A frame is armed one clock after its register
  // latch (line 7, or the last line on the primella family) and renders
  // lines 8-247 (0-255 on primella) in order. inuse counts lines started and
  // not yet fully scanned out (at most 4 buffers); ready counts finished
  // lines not yet shown. A displayed line whose render is not finished at
  // its start is an overrun.
  wire       arm_now  = line_start && (prm ? last_line : (!vextra && vcnt == 8'd7));
  wire [7:0] first_ln = prm ? 8'd0 : 8'd8;
  wire [7:0] last_ln  = prm ? 8'd255 : 8'd247;
  wire       disp     = prm ? !vextra : (!vextra && vcnt >= 8'd8 && vcnt <= 8'd247);
  wire       no_spr   = prm || (sdis_l && i_game == G_LASTDAY);
  logic go_arm, rarm, prev_disp, armed_once;
  logic [7:0] rnext;
  logic [2:0] inuse, ready;
  wire        can_start = rarm && inuse < 3'd4;
  // render start one clock after the latch, so the latched values are
  // visible to everything the renderer reads
  always_ff @(posedge clk) go_arm <= rst_n && arm_now;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rs             <= R_IDLE;
      rarm           <= 1'b0;
      armed_once     <= 1'b0;
      inuse          <= '0;
      ready          <= '0;
      prev_disp      <= 1'b0;
      lp_start       <= 1'b0;
      sp_start       <= 1'b0;
      rs_en          <= 1'b0;
      r2_v           <= 1'b0;
      o_dbg_overruns <= '0;
      o_dbg_maxcyc   <= '0;
    end else begin
      lp_start <= 1'b0;
      sp_start <= 1'b0;
      if (sp_done) sp_fin <= 1'b1;
      if (rs != R_IDLE) rcyc <= rcyc + 16'd1;
      // buffer accounting (see above)
      begin
        logic inc_u, dec_u, inc_r, dec_r;
        inc_u = (rs == R_IDLE) && can_start && !go_arm;
        dec_u = line_start && prev_disp;
        inc_r = (rs == R_RES_END) && !r2_v;
        dec_r = line_start && disp && ready != 3'd0;
        if (line_start) prev_disp <= disp;
        inuse <= inuse + 3'(inc_u) - 3'(dec_u);
        // an overrun leaves ready one ahead; each frame starts from 0
        ready <= go_arm ? 3'd0 : ready + 3'(inc_r) - 3'(dec_r);
        // (not before the first frame has been armed after reset)
        if (line_start && disp && ready == 3'd0 && !inc_r && armed_once)
          o_dbg_overruns <= o_dbg_overruns + 16'd1;
      end
      if (go_arm) begin
        rarm       <= 1'b1;
        rnext      <= first_ln;
        armed_once <= 1'b1;
      end
      case (rs)
        R_IDLE: if (can_start && !go_arm) begin
          rline    <= rnext;
          rnext    <= rnext + 8'd1;
          if (rnext == last_ln) rarm <= 1'b0;
          pi       <= 3'd0;
          rcyc     <= 16'd0;
          rs       <= R_PASS;
          // lastday ctrl bit 4 suppresses the sprite pass (spec 10.1); the
          // primella family has no sprites
          sp_start <= !no_spr;
          sp_fin   <= no_spr;
        end
        R_PASS: begin
          if (pi == p_n) begin
            rs   <= R_SPR_WAIT;
            rs_x <= 9'd0;
          end else if (cur_off) begin
            pi <= pi + 3'd1;
          end else begin
            lp_start <= 1'b1;
            wbit     <= p_bit[pi[1:0]];
            wsec     <= cfg.pbingo && pi[0];
            rs       <= R_PASS_WAIT;
          end
        end
        R_PASS_WAIT: if (lp_done) begin
          pi <= pi + 3'd1;
          rs <= R_PASS;
        end
        R_SPR_WAIT: if (sp_fin || sp_done) rs <= R_RES;
        R_RES: begin
          rs_en <= 1'b1;
          if (rs_en) rs_x <= rs_x + 9'd1;
          if (rs_en && rs_x == 9'd383) begin
            rs_en <= 1'b0;
            rs    <= R_RES_END;
          end
        end
        R_RES_END: if (!r2_v) begin
          rs <= R_IDLE;
          if (rcyc > o_dbg_maxcyc) o_dbg_maxcyc <= rcyc;
        end
        default: rs <= R_IDLE;
      endcase

      // resolve pipeline: stage 1 is rs_en with rs_x (reads registered here
      // and inside u_spr), stage 2 writes the output line
      r2_v <= rs_en;
      if (rs_en) begin
        r2_x    <= rs_x;
        r2_lv   <= lvalid[rs_x] && (!cfg.pbingo || lvalid2[rs_x]);
        r2_lpen <= cfg.pbingo ? {3'b001, lpen[rs_x][3:0], lpen2[rs_x]} : lpen[rs_x];
        r2_p1   <= lp1[rs_x];
        r2_p2   <= lp2[rs_x];
      end
      if (r2_v) obuf[{rline[1:0], r2_x}] <= r2_out;
    end
  end

  // ================================================================ scan-out
  // ce k: out-buffer read; ce k+1: palette read; ce k+2: RGB out
  logic        s1_de, s2_de;
  logic        s1_hb, s1_vb, s2_hb, s2_vb, s1_hs, s1_vs, s2_hs, s2_vs;
  logic [11:0] s1_raw, s2_px;
  wire  [11:0] s1_px = s1_de ? s1_raw : 12'd0;
  wire         h_act = (hcnt >= 9'd64) && (hcnt <= 9'd447);
  wire         v_act = prm ? !vextra : (!vextra && (vcnt >= 8'd8) && (vcnt <= 8'd247));
  wire [8:0]   ox    = 9'(hcnt - 9'd64);

  function automatic logic [23:0] to_rgb(logic [15:0] w, logic is444);
    if (is444) return {w[3:0], w[3:0], w[7:4], w[7:4], w[11:8], w[11:8]};
    else       return {w[14:10], w[14:12], w[9:5], w[9:7], w[4:0], w[4:2]};
  endfunction

  always_ff @(posedge clk) begin
    if (ce_pix) begin
      s1_de <= h_act && v_act;
      s1_hb <= !h_act;
      s1_vb <= !v_act;
      s1_hs <= hs_on;                  // sync: see the sync section above
      s1_vs <= vs_on;
      s1_raw <= obuf[{vcnt[1:0], ox}]; // unconditional: lets the buffer be a RAM
      s2_de <= s1_de;
      s2_hb <= s1_hb;
      s2_vb <= s1_vb;
      s2_hs <= s1_hs;
      s2_vs <= s1_vs;
      s2_px <= s1_px;
      pal_vaddr <= s1_px[10:0];
      o_de     <= s2_de;
      o_hblank <= s2_hb;
      o_vblank <= s2_vb;
      o_hs     <= s2_hs;
      o_vs     <= s2_vs;
      o_pen    <= {!s2_px[11], s2_px[10:0]};
      // black while the core is held in reset (FREE_TIMING keeps sync running)
      {o_r, o_g, o_b} <= (s2_de && s2_px[11] && (rst_n || !FREE_TIMING))
                         ? to_rgb(pal_vq, cfg.pal_444) : 24'd0;
    end
  end

  wire unused = &{1'b0, sb_qa_unused, rs_x[8], cfg.tx_lane0, vs_dw[9]};

endmodule
