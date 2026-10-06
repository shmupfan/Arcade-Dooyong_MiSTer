// M4 board-level testbench top: dy_board + SDRAM model on one DQ bus.
// Driven from sim/m4/tb_board.cpp.
module tb_board #(
    parameter int V_TOTAL = 256,
    parameter int PIX_NUM = 786432,
    parameter int PIX_DEN = 9600000
) (
    input  logic        clk,
    input  logic        i_sdram_rst_n,
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
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_ce_pix,
    output logic [11:0] o_pen,
    output logic        o_vbl_irq,
    output logic signed [15:0] o_audio,
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc
);
  wire [12:0] A;
  wire [1:0]  BA;
  wire [15:0] DQ;
  wire        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
  logic hb, vb;
  logic hs /* verilator public_flat_rd */, vs /* verilator public_flat_rd */;
  logic [3:0] game;

  dy_board #(.CPU_DIV(12), .CLK_HZ(96000000), .V_TOTAL(V_TOTAL),
             .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN), .SHORT_INIT(1'b1)) u_board (
    .clk(clk), .i_sdram_rst_n(i_sdram_rst_n), .i_reset(i_reset),
    .i_ioctl_download(i_ioctl_download), .i_ioctl_wr(i_ioctl_wr),
    .i_ioctl_addr(i_ioctl_addr), .i_ioctl_dout(i_ioctl_dout),
    .i_ioctl_index(i_ioctl_index), .o_ioctl_wait(o_ioctl_wait),
    .i_p1(i_p1), .i_p2(i_p2), .i_system(i_system),
    .i_crt_h(4'd0), .i_crt_v(3'd0), .i_osd_flip(1'b0),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_hblank(hb), .o_vblank(vb),
    .o_hs(hs), .o_vs(vs), .o_de(o_de), .o_ce_pix(o_ce_pix),
    .o_audio(o_audio), .o_game(game), .o_pen(o_pen), .o_vbl_irq(o_vbl_irq),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc),
    .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML),
    .SDRAM_DQMH(DQMH), .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));

  sdram_model u_mem (
    .clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));
endmodule
