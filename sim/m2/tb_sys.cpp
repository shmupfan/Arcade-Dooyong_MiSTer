// M2 full-system harness for dy_sys (Verilator, C++).
//
// Downloads the main CPU ROM from the set's sdram.bin, resets, and runs the
// system from power-on. Displayed frame N = the pixels scanned out between
// vblank IRQ N and N+1 (vblank N = the N-th start of line 248, MAME's frame
// notifier; line 256 = 0 on the primella family). Requested frames are
// written as .rgbp (384 x 240 x 5, or 384 x 256 x 5 on the primella family:
// R, G, B, pen low, pen high), and at each requested vblank the video RAMs are dumped
// in the oracle's byte order (.pal/.txt/.spr/.wram). For each requested
// displayed frame, every CPU write to 0xC000-0xFFFF during it is logged in
// .wlog ("line hpos addr data", beam position at the write).
//
// Plusargs: +sdram=FILE +frames=N (run until vblank N) +cap=FILE (frame
// numbers to capture, one per line) +out=DIR +intv=N +lat=N (ROM model, see
// sim/m1/tb_video.cpp) +dswa=HEX +dswb=HEX +game=N (dy_pkg game ID)
// +inputs=FILE: lines "frame p1 p2 system" (hex bytes, active low), each
// applied from that vblank onward (input replay).
// Sound (M3): the sound ROM is downloaded from SDRAM 0x040000; the M6295
// reads its samples from SDRAM 0x080000 with +okilat=N clocks of latency
// after each address change. +snd=FILE logs every sound CPU write to
// 0xF808-0xF80A and to its ROM range as "vblank line hpos addr data" (the
// same beam position the MAME oracle logs). +wav=FILE writes the mono mix
// as 16-bit 48 kHz samples (raw, little-endian).
// OSD (m4_findings 7): +osdflip=1 (Flip Screen), +crth=N (-8..7) and
// +crtv=N (-4..3) (CRT position; sync only, the captured pixels do not move).

#include "Vdy_sys.h"
#include "Vdy_sys___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <map>
#include <set>
#include <tuple>
#include <string>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vdy_sys> top;
static std::vector<uint8_t> sdram;
static int lat = 5, intv = 4;
static uint64_t cycles = 0, last_acc = (uint64_t)-1000;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

static int okilat = 8, oki_cnt = 0;
static uint32_t oki_last = 0xFFFFFFFF;

static void tick() {
    uint32_t oa = top->o_oki_addr;
    if (oa != oki_last) { oki_last = oa; oki_cnt = 0; }
    else if (oki_cnt < okilat) oki_cnt++;
    top->i_oki_data = sdram[0x80000 + (oa & 0x3FFFF)];
    top->i_oki_ok = oki_cnt >= okilat;
    bool rv = !rq.empty() && rq.front().t <= cycles;
    top->i_rom_rv = rv;
    if (rv) { top->i_rom_data = rq.front().d; rq.pop_front(); }
    bool gnt = cycles - last_acc >= (uint64_t)intv;
    top->i_rom_gnt = gnt;
    top->clk = 0; top->eval();
    if (gnt && top->o_rom_req) {
        rq.push_back({cycles + (uint64_t)lat, rd32(top->o_rom_addr)});
        last_acc = cycles;
    }
    top->clk = 1; top->eval();
    cycles++;
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void dump(const std::string &path, const void *p, size_t n) {
    std::ofstream o(path, std::ios::binary);
    o.write((const char *)p, n);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vdy_sys>();
    std::string sd = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", "");
    long nframes = atol(plus("frames", "600").c_str());
    lat = atoi(plus("lat", "5").c_str());
    intv = atoi(plus("intv", "4").c_str());
    int game = atoi(plus("game", "3").c_str());
    // primella family (5, 6): 256 visible lines, vblank at line 256
    const size_t frame_px = (game == 5 || game == 6) ? 384 * 256 : 384 * 240;
    okilat = atoi(plus("okilat", "8").c_str());
    std::string sndf = plus("snd", ""), wavf = plus("wav", "");
    FILE *fsnd = sndf.empty() ? nullptr : fopen(sndf.c_str(), "w");
    FILE *fwav = wavf.empty() ? nullptr : fopen(wavf.c_str(), "wb");
    std::string m68f = plus("m68w", "");
    FILE *fm68 = m68f.empty() ? nullptr : fopen(m68f.c_str(), "w");
    std::string wtf = plus("wtrace", "");
    FILE *fwt = wtf.empty() ? nullptr : fopen(wtf.c_str(), "w");
    int wtaddr = strtol(plus("wtaddr", "0").c_str(), nullptr, 16) & 0xFFFE;
    std::string sysf = plus("sysrd", "");
    FILE *fsys = sysf.empty() ? nullptr : fopen(sysf.c_str(), "w");
    int sysaddr = strtol(plus("sysaddr", "F004").c_str(), nullptr, 16);
    std::string wxf = plus("opnwav", "");         // YM2203 FM and SSG sums, int32 pairs at 48 kHz
    FILE *fwx = wxf.empty() ? nullptr : fopen(wxf.c_str(), "wb");
    std::string trf = plus("cputrace", "");       // sound CPU opcode fetch addresses
    FILE *ftr = trf.empty() ? nullptr : fopen(trf.c_str(), "w");
    bool m1_prev = true;
    const uint64_t clk_hz = 48000000;               // sim clock (Makefile -GCLK_HZ)
    uint64_t wav_acc = 0;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sd.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::set<long> cap;
    if (!capf.empty()) {
        std::ifstream f(capf);
        long n;
        while (f >> n) cap.insert(n);
    }

    std::map<long, std::tuple<int, int, int>> inputs;
    {
        std::string inf = plus("inputs", "");
        if (!inf.empty()) {
            std::ifstream f(inf);
            long n;
            std::string a, b, c;
            while (f >> n >> a >> b >> c)
                inputs[n] = {(int)strtol(a.c_str(), nullptr, 16), (int)strtol(b.c_str(), nullptr, 16),
                             (int)strtol(c.c_str(), nullptr, 16)};
        }
    }
    top->i_game = game;
    top->i_p1 = top->i_p2 = top->i_system = 0xFF;
    top->i_dswa = strtol(plus("dswa", "FF").c_str(), nullptr, 16);
    top->i_dswb = strtol(plus("dswb", "FF").c_str(), nullptr, 16);
    top->i_osd_flip = atoi(plus("osdflip", "0").c_str()) & 1;
    top->i_crt_h = atoi(plus("crth", "0").c_str()) & 15;
    top->i_crt_v = atoi(plus("crtv", "0").c_str()) & 7;
    top->rst_n = 0;
    top->i_dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    for (int a = 0; a < 0x40000; a++) {            // main CPU region at SDRAM 0 (256 KB for the 68000)
        top->i_dl_we = 1; top->i_dl_addr = a; top->i_dl_data = sdram[a];
        tick();
    }
    for (int a = 0; a < 0x10000; a++) {            // sound CPU region at SDRAM 0x040000
        top->i_dl_we = 1; top->i_dl_addr = 0x40000 + a; top->i_dl_data = sdram[0x40000 + a];
        tick();
    }
    top->i_dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    top->rst_n = 1;

    auto *r = top->rootp;
    long frame = 0;                                 // vblanks seen
    std::vector<uint8_t> px;
    px.reserve(384 * 240 * 5);
    std::string wlog;
    while (frame < nframes) {
        bool ce = r->dy_sys__DOT__ce_pix;          // enable going into this edge
        {   // OKI status reads: value on the bus at the end of the read cycle
            static bool rd_prev = true;
            bool rdn = r->dy_sys__DOT__u_snd__DOT__rd_n;
            if (fsnd && rdn && !rd_prev && r->dy_sys__DOT__u_snd__DOT__A == 0xF80A)
                fprintf(fsnd, "R %ld %d %d %02x\n", frame, r->dy_sys__DOT__u_video__DOT__vcnt,
                        r->dy_sys__DOT__u_video__DOT__hcnt, r->dy_sys__DOT__u_snd__DOT__din);
            rd_prev = rdn;
        }
        if (fsnd && r->dy_sys__DOT__u_snd__DOT__wr) {
            uint16_t a = r->dy_sys__DOT__u_snd__DOT__A;
            // sound chip and ROM-range writes per sound map (spec 4)
            bool log = (game == 0 || game == 1) ? ((a >= 0xF000 && a <= 0xF003) || a < 0x8000)
                     : (game == 2) ? ((a >= 0xF802 && a <= 0xF805) || a < 0xF000)
                     : ((a >= 0xF808 && a <= 0xF80A) || a < 0xF000);
            if (log)
                fprintf(fsnd, "%ld %d %d %04x %02x\n", frame, r->dy_sys__DOT__u_video__DOT__vcnt,
                        r->dy_sys__DOT__u_video__DOT__hcnt, a, r->dy_sys__DOT__u_snd__DOT__dout);
        }
        if (ftr) {
            bool m1 = r->dy_sys__DOT__u_snd__DOT__m1_n;
            if (!m1 && m1_prev) fprintf(ftr, "%04X %llu\n", r->dy_sys__DOT__u_snd__DOT__A, (unsigned long long)(cycles / 12));
            m1_prev = m1;
        }
        if (fwav) {
            wav_acc += 48000;
            if (wav_acc >= clk_hz) {
                wav_acc -= clk_hz;
                int16_t v = (int16_t)top->o_audio;
                fwrite(&v, 2, 1, fwav);
                if (fwx) {
                    int32_t p[2] = {(int32_t)(r->dy_sys__DOT__u_snd__DOT__dbg_fm << 15) >> 15,
                                    (int32_t)r->dy_sys__DOT__u_snd__DOT__dbg_ssg};
                    fwrite(p, 4, 2, fwx);
                }
            }
        }
        if (fsys) {   // main CPU reads of the SYSTEM port (+sysrd=FILE, +sysaddr=HEX)
            static bool rdp = true;
            bool rdn = r->dy_sys__DOT__rd_n;
            if (!rdn && rdp && r->dy_sys__DOT__A == sysaddr)
                fprintf(fsys, "%ld %d %d %d pc %04x\n", frame, r->dy_sys__DOT__u_video__DOT__vcnt,
                        r->dy_sys__DOT__u_video__DOT__hcnt, (int)r->dy_sys__DOT__vbl_in, top->o_cpu_pc_dbg);
            rdp = rdn;
        }
        if (fm68 && r->dy_sys__DOT__m_wstb) {       // +m68w=FILE: 68000 writes to I/O (0x080000-0x0CFFFF)
            uint32_t ba = (r->dy_sys__DOT__m_a << 1) & 0xFFFFF;
            if (ba >= 0x80000 && ba < 0xD0000)
                fprintf(fm68, "%ld %d %d %05x %04x\n", frame, r->dy_sys__DOT__u_video__DOT__vcnt,
                        r->dy_sys__DOT__u_video__DOT__hcnt, ba, r->dy_sys__DOT__m_dout);
        }
        if (fwt && r->dy_sys__DOT__wr && (r->dy_sys__DOT__A & 0xFFFE) == wtaddr)   // +wtrace=FILE +wtaddr=HEX
            fprintf(fwt, "%ld %d %d %04x %02x pc %04x\n", frame, r->dy_sys__DOT__u_video__DOT__vcnt,
                    r->dy_sys__DOT__u_video__DOT__hcnt, r->dy_sys__DOT__A, r->dy_sys__DOT__cpu_dout,
                    top->o_cpu_pc_dbg);
        if (r->dy_sys__DOT__wr && r->dy_sys__DOT__A >= 0xC000 && cap.count(frame)) {
            char b[48];
            snprintf(b, sizeof b, "%d %d %04x %02x\n", r->dy_sys__DOT__u_video__DOT__vcnt,
                     r->dy_sys__DOT__u_video__DOT__hcnt, r->dy_sys__DOT__A, r->dy_sys__DOT__cpu_dout);
            wlog += b;
        }
        tick();
        if (ce && top->o_de) {
            px.push_back(top->o_r);
            px.push_back(top->o_g);
            px.push_back(top->o_b);
            px.push_back(top->o_pen & 0xFF);
            px.push_back(top->o_pen >> 8);
        }
        if (top->o_vbl_irq) {
            // close displayed frame `frame` (pixels since the previous vblank)
            if (frame > 0 && cap.count(frame)) {
                char fn[64];
                snprintf(fn, sizeof fn, "%s/%06ld.rgbp", out.c_str(), frame);
                if (px.size() != frame_px * 5)
                    fprintf(stderr, "frame %ld: %zu pixels\n", frame, px.size() / 5);
                dump(fn, px.data(), px.size());
                snprintf(fn, sizeof fn, "%s/%06ld.wlog", out.c_str(), frame);
                dump(fn, wlog.data(), wlog.size());
            }
            wlog.clear();
            px.clear();
            frame++;
            auto it = inputs.find(frame);
            if (it != inputs.end()) {
                top->i_p1 = std::get<0>(it->second);
                top->i_p2 = std::get<1>(it->second);
                top->i_system = std::get<2>(it->second);
            }
            if (cap.count(frame)) {
                // RAM state at vblank N (MAME's frame notifier point)
                char fn[64];
                std::vector<uint8_t> b;
                b.resize(4096);
                for (int i = 0; i < 2048; i++) {        // palette, CPU byte order (68000: big-endian)
                    uint16_t w = r->dy_sys__DOT__u_video__DOT__u_pal__DOT__mem[i];
                    if (game >= 7 && game <= 9) { b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF; }
                    else                        { b[2 * i] = w & 0xFF; b[2 * i + 1] = w >> 8; }
                }
                snprintf(fn, sizeof fn, "%s/%06ld.pal", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 2048; i++) {        // text, logical big-endian words
                    uint16_t w = r->dy_sys__DOT__u_video__DOT__u_txt__DOT__mem[i];
                    b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.txt", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 1024; i++) {       // sprite RAM, 32-bit words, byte 4w in [31:24]
                    uint32_t w = r->dy_sys__DOT__u_video__DOT__u_spr_live__DOT__mem[i];
                    for (int k = 0; k < 4; k++) b[4 * i + k] = (w >> (24 - 8 * k)) & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.spr", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 4096; i++) {       // Z80 work RAM: bytes 0-4095 of the 16-bit RAM
                    uint16_t w = r->dy_sys__DOT__u_ram__DOT__mem[i >> 1];
                    b[i] = (i & 1) ? (w & 0xFF) : (w >> 8);
                }
                snprintf(fn, sizeof fn, "%s/%06ld.wram", out.c_str(), frame); dump(fn, b.data(), 4096);
            }
            if (fsnd)
                fprintf(fsnd, "# vblank %ld oki busy %x start %x stop %x\n", frame,
                        r->dy_sys__DOT__u_snd__DOT__u_oki__DOT__busy, r->dy_sys__DOT__u_snd__DOT__u_oki__DOT__start,
                        r->dy_sys__DOT__u_snd__DOT__u_oki__DOT__stop);
            if (frame % 100 == 0) {
                printf("vblank %ld pc %04x overruns %d maxcyc %d romwr %d bankhi %d\n", frame,
                       top->o_cpu_pc_dbg, top->o_dbg_overruns, top->o_dbg_maxcyc,
                       top->o_dbg_rom_writes, top->o_dbg_bank_hi);
                fflush(stdout);
            }
        }
    }
    printf("DONE vblanks %ld cycles %llu overruns %d maxcyc %d romwr %d bankhi %d sndromwr %d\n", frame,
           (unsigned long long)cycles, top->o_dbg_overruns, top->o_dbg_maxcyc,
           top->o_dbg_rom_writes, top->o_dbg_bank_hi, top->o_dbg_snd_rom_writes);
    if (fsnd) fclose(fsnd);
    if (fwav) fclose(fwav);
    if (fwx) fclose(fwx);
    if (fwt) fclose(fwt);
    if (fm68) fclose(fm68);
    if (fsys) fclose(fsys);
    if (ftr) fclose(ftr);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(0);
}
