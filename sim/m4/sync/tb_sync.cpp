// Sync check for dy_video (m4_findings 7): at the hardware raster (512 x 260,
// V_TOTAL=260) with every OSD CRT position, vsync edges land on hsync leading
// edges, the pulses have the right lengths and periods, hsync stays inside
// hblank and vsync inside vblank, and the sync sits where the offset puts it
// relative to the picture (first active pixel of a line, first visible line).
// Flying Tiger (Z80), R-Shark (68000) and Sadari (primella family: vsync fixed
// at lines 256-259, no vertical offset). The pixel enable is one clock in 4
// here (12 on hardware); the sync logic only counts pixel enables.
//
// Build (from sim/):
//   verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style \
//     --top-module dy_video -GV_TOTAL=260 --Mdir build/m4/sync -CFLAGS -O2 \
//     ../rtl/dy_pkg.sv ../rtl/dy_dpram.sv ../rtl/dy_layer_pass.sv \
//     ../rtl/dy_spr_z80.sv ../rtl/dy_video.sv m4/sync/tb_sync.cpp
#include "Vdy_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vdy_video *top;
static long px = 0;
static void tick(bool ce) {
    top->ce_pix = ce; top->clk = 0; top->eval(); top->clk = 1; top->eval();
}
static void pixel() { for (int i = 0; i < 4; i++) tick(i == 3); px++; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vdy_video;
    const long HT = 512, VT = 260, HS0 = 464, VS0 = 251, ACT_X0 = 64;
    const int games[3] = {3, 8, 5};                     // flytiger, rshark, sadari
    const char *names[3] = {"flytiger", "rshark", "sadari"};
    int fails_all = 0;
    top->i_rom_gnt = 0; top->i_rom_rv = 0; top->i_tim_rst = 0;
    for (int gi = 0; gi < 3; gi++) {
        const bool prm = games[gi] == 5;
        const long vis0 = prm ? 0 : 8;                  // first visible line
        int fails = 0;
        top->i_game = games[gi]; top->i_crt_h = 0; top->i_crt_v = 0;
        top->rst_n = 0; for (int i = 0; i < 64; i++) tick(false);
        top->rst_n = 1;
        for (int h = -8; h <= 7; h++) for (int v = -4; v <= 3; v++) {
            top->i_crt_h = h & 15; top->i_crt_v = v & 7;
            for (long i = 0; i < 2 * HT * VT; i++) pixel();   // offsets taken at vblank
            // measure two frames
            bool phs = top->o_hs, pvs = top->o_vs, pde = top->o_de, pvb = top->o_vblank;
            long hs_rise = -1, hs_len = -1, vs_rise = -1, vs_fall = -1;
            long vb_fall = -1, first_de = -1, outside = 0, vs_rises = 0;
            bool vs_on_hs_r = true, vs_on_hs_f = true, hs_period_ok = true, hs_len_ok = true;
            for (long i = 0; i < 2 * HT * VT; i++) {
                pixel();
                bool hs = top->o_hs, vs = top->o_vs, de = top->o_de, vb = top->o_vblank, hb = top->o_hblank;
                if ((hs && !hb) || (vs && !vb)) outside++;
                if (hs && !phs) {
                    if (hs_rise >= 0 && px - hs_rise != HT) hs_period_ok = false;
                    hs_rise = px;
                }
                if (!hs && phs && hs_rise >= 0) { hs_len = px - hs_rise; if (hs_len != 32) hs_len_ok = false; }
                if (vs && !pvs) { vs_rise = px; vs_rises++; if (!(hs && !phs)) vs_on_hs_r = false; }
                if (!vs && pvs && vs_rise >= 0) { vs_fall = px; if (!(hs && !phs)) vs_on_hs_f = false; }
                if (!vb && pvb) vb_fall = px;
                if (de && !pde && first_de < 0 && vb_fall >= 0) first_de = px;
                phs = hs; pvs = vs; pde = de; pvb = vb;
            }
            const long hs_beg = HS0 - 2 * h;
            const long vs_beg = prm ? 256 : VS0 - v;
            // hsync start relative to the line's first active pixel
            long hs_rel = ((hs_rise - first_de) % HT + HT) % HT;
            // pixels from the vsync start (line vs_beg, at the hsync) to the first visible pixel
            long vs_px = ((first_de - vs_rise) % (HT * VT) + HT * VT) % (HT * VT);
            long vs_len = vs_fall - vs_rise;
            long exp_vs_px = (VT - vs_beg + vis0) * HT + ACT_X0 - hs_beg;
            bool ok = hs_period_ok && hs_len_ok && hs_len == 32 && vs_on_hs_r && vs_on_hs_f && vs_rises == 2 &&
                      vs_len == 3 * HT && outside == 0 && hs_rel == hs_beg - ACT_X0 && vs_px == exp_vs_px;
            if (!ok) {
                fails++;
                printf("FAIL %s h=%d v=%d: hs_period_ok=%d hs_len=%ld vs_on_hs=%d/%d vs_rises=%ld vs_len=%ld "
                       "outside_blank=%ld hs_rel=%ld (exp %ld) vs_px=%ld (exp %ld)\n",
                       names[gi], h, v, hs_period_ok, hs_len, vs_on_hs_r, vs_on_hs_f, vs_rises, vs_len,
                       outside, hs_rel, hs_beg - ACT_X0, vs_px, exp_vs_px);
            }
        }
        printf("sync %s: 128 offset pairs, %d fail\n", names[gi], fails);
        fails_all += fails;
    }
    printf("sync: 3 games x 128 offset pairs, %d fail\n", fails_all);
    delete top;
    return fails_all ? 1 : 0;
}
