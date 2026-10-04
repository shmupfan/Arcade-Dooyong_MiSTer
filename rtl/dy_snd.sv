// Dooyong sound system, YM2151 variant (PLAN M3; spec 2, 4): sound Z80,
// sound ROM (BRAM), 2 KB RAM, sound latch, YM2151 (jt51), M6295 (jt6295).
// Used by flytiger, bluehawk and the primella family (and later the 68000
// games, which share this map).
//
// Sound map (spec 4, YM2151 games): 0x0000-0xEFFF ROM, 0xF000-0xF7FF RAM,
// 0xF800 latch (read; no NMI, reading does not clear), 0xF808-0xF809
// YM2151, 0xF80A M6295. Unmapped reads return 0. The YM2151 IRQ drives the
// Z80 INT line directly; the acknowledge cycle reads 0xFF.
//
// Clock enables from the system clock:
//   CPU  : clk / CPU_DIV (4 MHz)
//   YM   : fractional YM_NUM / YM_DEN of clk (3.579545 MHz on flytiger,
//          bluehawk "3.579545MHz or 4Mhz ???" in MAME, spec 2), or
//          YM4_NUM / YM_DEN with i_ym_4m (4 MHz, primella family); cen_p1 is
//          every other YM enable, as jt51 expects
//   OKI  : clk / OKI_DIV (1 MHz), pin 7 high (ss = 1, sample rate /132)
//
// Mix (MAME parity, spec 2, driver 1492-1495): YM2151 left and right at
// 0.35 each and the M6295 at 0.42 into one mono speaker. jt51's xleft /
// xright are 16-bit full scale; jt6295's sound is the sum of the channels
// in 12-bit units, which MAME converts at 1/2048 of full scale, so the
// OKI term is 0.42 * 16 = 6.72 in 16-bit units. Calibrated in M3 against
// MAME's WAV output (m3_findings).

// YM2203 variant (i_opn, spec 2, 4, 5.1; lastday, gulfstrm, pollux): two
// jt03 (YM2203 with SSG) instead of the YM2151 and M6295, both IRQs ORed
// into the Z80 INT (MAME's INPUT_MERGER_ANY_HIGH; T7), port A reads 0.
//   lastday / gulfstrm map (i_opn_map_ld): ROM 0000-7FFF, RAM C000-C7FF,
//     latch C800, YM #1 F000-F001, YM #2 F002-F003
//   pollux map: ROM 0000-EFFF, RAM F000-F7FF, latch F800, YM #1 F802-F803,
//     YM #2 F804-F805
// Clocks: YM2203 at OPN_NUM / YM_DEN (4 MHz lastday) or OPN15_NUM / YM_DEN
// with i_opn_15 (1.5 MHz gulfstrm, pollux); sound CPU doubled to 8 MHz with
// i_cpu_fast (gulfstrm, MAME's "jerky music" hack, spec 2). Mix: every
// YM2203 output at 0.40 into mono (driver 1476-1482); gains calibrated
// against MAME's WAV (see FM_GAIN).

module dy_snd #(
    parameter int CPU_DIV = 24,
    parameter int YM_NUM  = 3579545,
    parameter int YM4_NUM = 4000000,  // with i_ym_4m (primella family)
    parameter int YM_DEN  = 96000000,
    parameter int OKI_DIV = 96,
    parameter int OPN_NUM   = 4000000,
    parameter int OPN15_NUM = 1500000,
    // YM2203 gains, fitted against MAME's WAV (20 ms window power over
    // stretches where the sound streams are identical; sim/m3/fit_opn.py):
    // FM 100-102/256 on all three games = MAME's 0.40 routing (102/256);
    // SSG on jt49's summed output depends on the chip clock: 4,465/256 at
    // 4 MHz (lastday 9.5-28 s), 5,500-5,600/256 at 1.5 MHz (gulfstrm 1-30 s,
    // pollux 5-11 s)
    parameter int FM_GAIN    = 102,
    parameter int SSG_GAIN   = 4465,
    parameter int SSG15_GAIN = 5550,
    parameter int YM_GAIN  = 90,     // x/256: 0.352
    parameter int OKI_GAIN = 1720    // x/256: 6.72
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_ym_4m,       // YM clock YM4_NUM / YM_DEN instead
    input  logic        i_opn,         // 2x YM2203 variant
    input  logic        i_opn_map_ld,  // with i_opn: lastday/gulfstrm map (else pollux)
    input  logic        i_opn_15,      // with i_opn: YM2203 at 1.5 MHz (else 4 MHz)
    input  logic        i_cpu_fast,    // sound CPU at twice the rate (gulfstrm)

    // sound ROM download (64 KB)
    input  logic        i_dl_we,
    input  logic [15:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,

    input  logic [7:0]  i_latch,

    // M6295 sample ROM (256 KB); data valid when i_oki_ok
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,

    output logic signed [15:0] o_audio,
    output logic signed [15:0] o_ym_l,
    output logic signed [15:0] o_ym_r,
    output logic signed [13:0] o_oki,

    // debug
    output logic [15:0] o_dbg_rom_writes
);

  // ================================================================ enables
  logic [5:0]  cpu_cnt, oki_cnt;
  logic        ce_cpu, ym_cen, ym_ph, oki_cen;
  logic [27:0] ym_acc;
  wire  [27:0] ym_num = i_ym_4m ? 28'(YM4_NUM) : 28'(YM_NUM);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cpu_cnt <= '0;
      oki_cnt <= '0;
      ce_cpu  <= 1'b0;
      ym_cen  <= 1'b0;
      ym_ph   <= 1'b0;
      oki_cen <= 1'b0;
      ym_acc  <= '0;
    end else begin
      ce_cpu  <= (cpu_cnt == 6'd0) || (i_cpu_fast && cpu_cnt == 6'(CPU_DIV / 2));
      cpu_cnt <= (cpu_cnt == 6'(CPU_DIV - 1)) ? 6'd0 : cpu_cnt + 6'd1;
      oki_cen <= (oki_cnt == 6'd0);
      oki_cnt <= (oki_cnt == 6'(OKI_DIV - 1)) ? 6'd0 : oki_cnt + 6'd1;
      if (ym_acc + ym_num >= 28'(YM_DEN)) begin
        ym_acc <= ym_acc + ym_num - 28'(YM_DEN);
        ym_cen <= 1'b1;
        ym_ph  <= !ym_ph;
      end else begin
        ym_acc <= ym_acc + ym_num;
        ym_cen <= 1'b0;
      end
    end
  end
  wire ym_cen_p1 = ym_cen && ym_ph;

  // Reset-time enable for the FM chips. jt51 and jt03 load their reset values
  // only by shifting with cen while rst is high (jt51_sh, jt12_sh: "rst should
  // be at least 6 clk&cen cycles long", jt03.v; YM2151 and YM2203 data sheets:
  // the IC pulse must cover many clock cycles). With the enables held at 0
  // in reset, every operator kept zero attenuation (full volume) and the FM
  // outputs sat at a large constant until the program's first writes, where
  // MAME outputs 0 (m3_findings 7). This enable runs only while rst_n is low,
  // one pulse every 8 clocks for RST_CEN pulses, so the chips reset fully;
  // the normal enables above still restart from 0 at the release, so every
  // enable after reset is unchanged.
  localparam logic [12:0] RST_CEN = 13'd4608;   // 72 x 64: whole jt03 and jt51 slot cycles
  logic [2:0]  rst_div;
  logic [12:0] rst_cnt;
  logic        rst_cen, rst_ph;
  always_ff @(posedge clk) begin
    rst_cen <= 1'b0;
    if (rst_n) begin
      rst_div <= '0;
      rst_cnt <= '0;
      rst_ph  <= 1'b0;
    end else if (rst_cnt != RST_CEN) begin
      rst_div <= rst_div + 3'd1;
      if (rst_div == 3'd0) begin
        rst_cen <= 1'b1;
        rst_ph  <= !rst_ph;
        rst_cnt <= rst_cnt + 13'd1;
      end
    end
  end
  wire fm_cen    = rst_n ? ym_cen    : rst_cen;
  wire fm_cen_p1 = rst_n ? ym_cen_p1 : (rst_cen && rst_ph);

  // YM2203 clock enable (chip clock; jt03 divides internally)
  logic [27:0] opn_acc;
  logic        opn_cen;
  wire  [27:0] opn_num = i_opn_15 ? 28'(OPN15_NUM) : 28'(OPN_NUM);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      opn_acc <= '0;
      opn_cen <= 1'b0;
    end else if (opn_acc + opn_num >= 28'(YM_DEN)) begin
      opn_acc <= opn_acc + opn_num - 28'(YM_DEN);
      opn_cen <= 1'b1;
    end else begin
      opn_acc <= opn_acc + opn_num;
      opn_cen <= 1'b0;
    end
  end
  wire opn_cen_c = rst_n ? opn_cen : rst_cen;   // reset-time enable (above)

  // ================================================================ CPU
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  dout /* verilator public_flat_rd */;
  logic [7:0]  din /* verilator public_flat_rd */;
  logic        m1_n /* verilator public_flat_rd */;
  logic        rd_n /* verilator public_flat_rd */;
  logic        mreq_n, iorq_n, wr_n, rfsh_n, halt_n, busak_n;
  logic        ym_irq_n, opn1_irq_n, opn2_irq_n;
  wire         cpu_int_n = i_opn ? (opn1_irq_n && opn2_irq_n) : ym_irq_n;

  T80s u_cpu (
    .RESET_n(rst_n), .CLK(clk), .CEN(ce_cpu),
    .WAIT_n(1'b1), .INT_n(cpu_int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .DI(din),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
    .A(A), .DOUT(dout));

  wire mem     = !mreq_n && rfsh_n;
  wire int_ack = !m1_n && !iorq_n;
  logic wr_q;
  always_ff @(posedge clk) wr_q <= mem && !wr_n;
  wire wr /* verilator public_flat_rd */ = mem && !wr_n && !wr_q;

  logic s_rom, s_ram, s_lat, s_ym, s_oki, s_opn1, s_opn2;
  always_comb begin
    s_ym = 1'b0; s_oki = 1'b0; s_opn1 = 1'b0; s_opn2 = 1'b0;
    if (!i_opn) begin
      s_rom = A < 16'hF000;
      s_ram = A[15:11] == 5'b11110;            // F000-F7FF
      s_lat = A == 16'hF800;
      s_ym  = A[15:1] == 15'h7C04;             // F808-F809
      s_oki = A == 16'hF80A;
    end else if (i_opn_map_ld) begin
      s_rom  = !A[15];                         // 0000-7FFF
      s_ram  = A[15:11] == 5'b11000;           // C000-C7FF
      s_lat  = A == 16'hC800;
      s_opn1 = A[15:1] == 15'h7800;            // F000-F001
      s_opn2 = A[15:1] == 15'h7801;            // F002-F003
    end else begin
      s_rom  = A < 16'hF000;
      s_ram  = A[15:11] == 5'b11110;           // F000-F7FF
      s_lat  = A == 16'hF800;
      s_opn1 = A[15:1] == 15'h7C01;            // F802-F803
      s_opn2 = A[15:1] == 15'h7C02;            // F804-F805
    end
  end

  // ================================================================ memories
  logic [7:0] rom_q, ram_q;
  dy_dpram #(.AW(16), .DW(8)) u_rom (
    .clk(clk),
    .addr_a(i_dl_addr), .d_a(i_dl_data), .we_a(i_dl_we), .be_a(1'b1), .q_a(),
    .addr_b(A), .q_b(rom_q));
  dy_dpram #(.AW(11), .DW(8)) u_ram (
    .clk(clk),
    .addr_a(A[10:0]), .d_a(dout), .we_a(wr && s_ram), .be_a(1'b1), .q_a(ram_q),
    .addr_b(11'd0), .q_b());

  // ================================================================ chips
  logic [7:0] ym_dout, oki_dout;
  logic signed [15:0] ym_xl, ym_xr;
  // A Z80 write reaches jt51 on the next cen_p1 clock (fix ported from the
  // Tecmo 16 core, docs/m3_findings.md section 6). jt51 takes register
  // writes on any clock but sets its busy flag only for a write that
  // coincides with cen_p1 (jt51_mmr: busy updates under cen); a one-clock
  // strobe hit cen_p1 about once in 50 writes, so the status read after a
  // data write showed "not busy" where the chip (and MAME's ymfm) shows
  // busy, and busy-wait loops ran short. Holding the write until cen_p1
  // moves the register update by at most one P1 period (about 0.5 us).
  // jt03 (YM2203) sets busy on any write and needs no change.
  logic       ym_wpend;
  logic       ym_wa0;
  logic [7:0] ym_wd;
  always_ff @(posedge clk) begin
    if (!rst_n) ym_wpend <= 1'b0;
    else if (wr && s_ym) begin
      ym_wpend <= 1'b1;
      ym_wa0   <= A[0];
      ym_wd    <= dout;
    end else if (ym_cen_p1) ym_wpend <= 1'b0;
  end
  jt51 u_ym (
    .rst(!rst_n), .clk(clk), .cen(fm_cen), .cen_p1(fm_cen_p1),
    .cs_n(!(ym_wpend && ym_cen_p1)), .wr_n(1'b0), .a0(ym_wa0), .din(ym_wd),
    .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_xl), .xright(ym_xr));

  // YM2203 pair; writes are one-clock strobes (jt12 registers run at clk)
  logic [7:0]  opn1_dout, opn2_dout;
  logic signed [15:0] opn1_fm, opn2_fm;
  logic [9:0]  opn1_ssg, opn2_ssg;
  jt03 u_opn1 (
    .rst(!rst_n || !i_opn), .clk(clk), .cen(opn_cen_c),
    .din(dout), .addr(A[0]), .cs_n(!(wr && s_opn1)), .wr_n(1'b0),
    .dout(opn1_dout), .irq_n(opn1_irq_n),
    .IOA_in(8'd0), .IOB_in(8'd0), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
    .psg_A(), .psg_B(), .psg_C(), .fm_snd(opn1_fm), .psg_snd(opn1_ssg),
    .snd(), .snd_sample(), .debug_view());
  jt03 u_opn2 (
    .rst(!rst_n || !i_opn), .clk(clk), .cen(opn_cen_c),
    .din(dout), .addr(A[0]), .cs_n(!(wr && s_opn2)), .wr_n(1'b0),
    .dout(opn2_dout), .irq_n(opn2_irq_n),
    .IOA_in(8'd0), .IOB_in(8'd0), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
    .psg_A(), .psg_B(), .psg_C(), .fm_snd(opn2_fm), .psg_snd(opn2_ssg),
    .snd(), .snd_sample(), .debug_view());

  // The FM outputs idle at 0 from reset now that the chips reset with an
  // enable (reset-time enable above); the earlier first-write gate on each
  // chip's FM output is no longer needed (m3_findings 7).
  wire signed [15:0] opn1_fm_g = opn1_fm;
  wire signed [15:0] opn2_fm_g = opn2_fm;

  // simulation taps for the YM2203 gain calibration (m3/fit_opn.py)
  logic signed [16:0] dbg_fm  /* verilator public_flat_rd */;
  logic        [10:0] dbg_ssg /* verilator public_flat_rd */;
  assign dbg_fm  = 17'(opn1_fm_g) + 17'(opn2_fm_g);
  assign dbg_ssg = 11'(opn1_ssg) + 11'(opn2_ssg);

  logic signed [13:0] oki_snd;
  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(!rst_n), .clk(clk), .cen(oki_cen), .ss(1'b1),
    .wrn(!(wr && s_oki)), .din(dout), .dout(oki_dout),
    .rom_addr(o_oki_addr), .rom_data(i_oki_data), .rom_ok(i_oki_ok),
    .sound(oki_snd), .sample());

  always_ff @(posedge clk) begin
    if (int_ack)    din <= 8'hFF;
    else if (s_rom) din <= rom_q;
    else if (s_ram) din <= ram_q;
    else if (s_lat) din <= i_latch;
    else if (s_ym)  din <= ym_dout;
    else if (s_oki) din <= oki_dout;
    else if (s_opn1) din <= opn1_dout;
    else if (s_opn2) din <= opn2_dout;
    else            din <= 8'h00;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) o_dbg_rom_writes <= '0;
    else if (wr && s_rom) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
  end

  // ================================================================ mix
  assign o_ym_l = ym_xl;
  assign o_ym_r = ym_xr;
  assign o_oki  = oki_snd;
  always_comb begin
    logic signed [27:0] m;
    if (i_opn)
      // every term signed: one unsigned operand would make the sum unsigned
      // and turn >>> into a logical shift (negative FM became large positive)
      m = (((28'(opn1_fm_g) + 28'(opn2_fm_g)) * $signed(28'(FM_GAIN))) +
           (($signed(28'({1'b0, opn1_ssg})) + $signed(28'({1'b0, opn2_ssg}))) *
            $signed(28'(i_opn_15 ? SSG15_GAIN : SSG_GAIN)))) >>> 8;
    else
      m = (((28'(ym_xl) + 28'(ym_xr)) * $signed(28'(YM_GAIN))) + (28'(oki_snd) * $signed(28'(OKI_GAIN)))) >>> 8;
    if (m > 28'sd32767)       o_audio = 16'sd32767;
    else if (m < -28'sd32768) o_audio = -16'sd32768;
    else                      o_audio = m[15:0];
  end

  wire unused = &{1'b0, halt_n, busak_n, rd_n};

endmodule
