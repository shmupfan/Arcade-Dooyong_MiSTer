# M4 findings: MiSTer shell, SDRAM, MRA, Quartus

Date: 2026-09-28. Scope: flytiger and bluehawk (game IDs 3 and 4).

## 1. Built

| File | Content |
|---|---|
| `rtl/dy_sdram.sv` | SDRAM controller for three clients (download words, 2-word graphics reads on dy_video's pipelined port, OKI byte reads) plus refresh. Close-page, CL2, capture 3 clocks after CAS, full-word writes only (the MiSTer SDRAM board ties DQM low), tRCD/tRP 3 clocks at 96 MHz (the modules' AS4C32M16SB-7 needs 21 ns; 2 clocks would be 20.8 ns). Protocol and constants from Hyper Duel's hardware-proven controller |
| `rtl/dy_board.sv` | everything below the framework: dy_sys + dy_sdram + ioctl handling (index 0 ROM stream = SDRAM image, program ranges also copied into BRAM; index 1 game ID; index 254 DIPs); core held in reset during downloads and until the SDRAM is initialised |
| `Arcade-Dooyong.sv` | Template_MiSTer `emu`: hps_io, inputs (spec 9.2), dy_board at 96 MHz, arcade_video, screen_rotate (MISTER_FB=1) for the ROT270 games, aspect 3:4 rotated |
| `Arcade-Dooyong.qsf/.sdc/.qpf/.srf`, `files.qip`, `pll.v`, `pll/`, `sys/` | Quartus project; qsf settings and sys/ copied from Hyper Duel (BALANCED, timing-driven synthesis off); PLL 96 MHz + 96 MHz at -90 degrees (-2,604 ps) for SDRAM_CLK; multicycle 2 inside the clock-enabled T80s, jt51 and jt6295 |
| `tools/make_mra.py` | generates the MRAs from the driver's ROM_START blocks and proves each one: a Python replay of Main_MiSTer's mra_loader.cpp assembly (part/interleave/map/repeat rules read from its source) rebuilds the stream from the zip, compared with sdram.bin byte for byte |
| `releases/mra/*.mra` | 5 MRAs (Flying Tiger sets 1-2, Blue Hawk and its two NTC sets), all verified |
| `tools/deploy_mister.sh` | finds the MiSTer by MAC, copies RBF, MRAs and ROM zips if missing, MD5 on both sides, never overwrites |
| `sim/m4/tb_board.sv`, `tb_board.cpp`, `sdram_model.sv` | board simulation: the MRA stream through ioctl into dy_sdram and Hyper Duel's SDRAM model (flags protocol errors), 96 MHz |

Video timing on hardware: 8 MHz pixel clock (96 MHz / 12), 512 x 260 = 60.10
Hz. Simulation keeps MAME's 512 x 256 at 60.00 Hz for the MAME comparisons.
Real totals remain research item R1.

## 2. Simulation results

| Check | Result |
|---|---|
| MRA streams | 5/5 byte-identical to the SDRAM images |
| Board boot, MAME parity timing (`make m4-boot`) | 1,200 frames from power-on through the 7.6 MB download and the SDRAM model: 83 frames exact vs MAME, 67 line-exact against the live-read model (m2_findings 3), 0 unexplained; all 452 RAM dumps match; no SDRAM protocol errors; 0 line overruns, worst line 4,697 of 6,144 clocks with the real controller |
| Board soak, hardware timing (V_TOTAL 260, integer 8 MHz) | 2,100 frames, 0 overruns (run stopped for the timing fixes below; to repeat on the final RTL) |

## 3. First Quartus build: timing failure and fixes

Compile 1 (Quartus 17.0 Lite on the compile PC, E-cores): synthesis, fit and
assembly clean, but setup slack -2.165 ns on the 96 MHz core clock (TNS
-1,730 ns); all other clocks met. Not deployed.

The 400 worst paths were two structures:
- 394: CPU address -> palette/text/sprite address mux -> 1,024-to-1 lookup
  of the sprite copy's `copied` bitmap -> 487 write enables, in one clock.
  Fix: the sprite-RAM write is pipelined (register the write, look up the
  bit the next clock, save and read the old word the clock after, write the
  live RAM at the third clock).
- 6: the sprite engine's record queue (a RAM block) feeding the pixel
  logic. Fix: latch the head record into registers at draw start and split
  the pixel step into two stages.

After the fixes: M1 all suites unchanged (3,875/3,875, 900/900, 408/408).

## 4. Compiles 2 and 3

Compile 2: -0.232 ns, 73 failing paths:
- 51: the copy engine's own lookup of the `copied` bitmap at its running
  counter, decided and written back in the same clock. Fix: the bitmap
  now only records CPU saves during the copy (cleared at vblank); the
  engine's lookup is registered one clock ahead, in step with its live-RAM
  read, and a save is only needed for words at or beyond the copy counter.
  (A one-bit generation scheme in RAM was tried first and broke M1: marks
  never written read as saved every other frame. Reverted.)
- 21: the framework's HQ2x scaler inside arcade_video cannot run at 96 MHz.
  Fix: a third PLL output, 48 MHz phase aligned, drives arcade_video and
  screen_rotate; the core's pixel outputs (changing every 12 core clocks)
  are re-registered there and sampled by a divide-by-6 enable.
- 1: the scan-out read of the output line buffer was conditional, which
  kept it out of block RAM. Now unconditional, blanked one stage later.

Compile 3: timing met on every clock (0 negative slack entries):

| Clock | Setup | Hold |
|---|---|---|
| core 96 MHz | +0.802 ns | +0.256 ns |
| video 48 MHz | +3.091 ns | +0.243 ns |

Fit: 18,140 / 41,910 ALMs (43%), 291 / 553 RAM blocks (53%), 2.25 Mbit
block memory (40%). RBF `builds/Dooyong_20260928.rbf`, MD5
c2a73ac3e531ba471670b4dc5e12186a (same on the compile PC), timestamp from
the compile-3 flow (21:30:07, flow end 21:30:27).

M1 re-run on the compile-3 RTL: all suites pass (3,875/3,875 gate,
408/408 synthetic). M2 flytiger 7,500-frame re-run and the hardware-timing
board soak: section 5.

## 5. Final checks on the compile-3 RTL, deploy

| Check | Result |
|---|---|
| M2 flytiger re-run, 7,500 frames (covers the vblank-7408 sprite-copy case) | 1,296 exact vs MAME, 166 line-exact against the live-read model, 0 unexplained; RAM: 2 transient, 0 persistent |
| Board soak, hardware timing (260 lines, exact 8 MHz), 2,200 frames | 0 overruns, worst line 4,698 of 6,144 clocks |

Deployed 2026-09-28 22:20 to the MiSTer (found by its MAC address) with
tools/deploy_mister.sh, new files only, MD5 checked both sides:
`_Arcade/cores/Dooyong_20260928.rbf`, the 5 MRAs in `_Arcade/`, and
`games/mame/flytiger.zip`, `bluehawk.zip`.

Hardware result (Lee, 2026-09-28/29): Flying Tiger boots and plays; the
first build had no keyboard handling (gamepads only), fixed in compile 4
(MAME-style keys, timing +0.549 ns, RBF md5 5ab961f6, deployed with the
first build kept as `.bak`). On compile 4: "working perfectly, sound and
controller, graphics look great." Blue Hawk and the open items (R13 sound
divergence by ear, DIPs, long play) remain for M5 QA.

## 6. Video during the ROM download, HDMI options, 20261004 release (2026-10-04)

**Green screen at start.** Lee saw a solid green screen for about a
second when the core starts (Pop Bingo, Pollux). dy_board held
core_rst_n low through the ROM download and SDRAM init, which also reset
the pixel enable and froze the video counters: no hsync or vsync for a
second, shown by the MiSTer output as its no-signal state (likely cause,
not confirmed on hardware; the board sim shows the missing sync).

**Fix (dy_sys/dy_video parameter FREE_TIMING, set to 1 by dy_board).**
The pixel enable and video counters run from the PLL lock and keep
producing sync while the core is held in reset; RGB is 0 while the core
is in reset. Once a frame, the pixel enable that would start the power-on
line (248; 0 on the Primella family) reloads the counters and the pixel
accumulator to their reset values instead, and dy_sys releases the core
on the clock after such a reload, so the first running clock sees exactly
the state of a plain reset release (MAME comparisons unchanged).
FREE_TIMING = 0 (M1/M2 harness default) is the old logic.

**Board A/B (same harness; base = before the fix, 601 frames, captures at
frames 1-40 and every 25th, RAM dumps and write logs).**

| Game | Capture files identical | Before the core runs (fix) |
|---|---|---|
| flytiger | 378 / 378 (also on the final RTL with jt6295 variant e) | 24 vsyncs, 0 lit pixels (base: 1 vsync) |
| pollux | 378 / 378 | 24 vsyncs, 0 lit pixels |
| popbingo | 378 / 378 | 24 vsyncs, 0 lit pixels |
| sadari | 378 / 378 | 0 vsyncs, 0 lit pixels: the sim uses MAME's 256-line parity frame, which has no Primella vsync lines (the 260-line hardware frame does); hsync and DE run |

Only the worst render line changes slightly (2,404 vs 2,413 clocks on
flytiger), since the SDRAM refresh phase relative to the core start
differs; no overruns.

**M2 against MAME with jt6295 variant e** (requested for the two games
last verified with the MAME-timed jt6295), 3,001 frames from power-on:
- sadari: YM2151 20,829 and M6295 76 events identical to MAME; 81 images
  exact plus 19 explained by live reads, 0 unexplained; 200 RAM dump
  files match.
- popbingo: YM2151 32,115, M6295 41,975 and sound ROM 42,598 events
  identical to MAME. 1 to 2 bytes of live sprite RAM differ from vblank 60
  on (27 images); the same differences appear line for line in the
  previous run with the a+b jt6295 (build/m2/oki_fix2, up to vblank
  2,790), and every RAM dump to frame 2,800 is byte-identical between the
  two runs, so variant e does not change it. It predates the OKI work
  (68000 class, m68k_findings).

**HDMI options (shell only).** video_freak supplies VIDEO_ARX/ARY:
Aspect ratio as before and Scale (Normal, V-Integer, Narrower
HV-Integer, Wider HV-Integer). No 216p crop: the Dooyong pictures are
240 lines (256 on the Primella family). The shell lints clean with the
framework stubs.

**Release build** builds/20261004_0035_Arcade-Dooyong.rbf =
releases/Arcade-Dooyong_20261004.rbf, md5
feafc9e4066f203c5d04789f7bcf3be2: every clock non-negative (core 96 MHz
setup +0.878 / hold +0.253 ns, HDMI setup +0.222 / hold +0.177 ns,
recovery and removal positive), 55% ALMs, 90% RAM blocks. Not yet tested
on hardware.

## 7. CRT options: sync on the hsync edge, CRT position, OSD flip (2026-10-05)

Lee's core minimum standard (2026-10-05, after CRT tester reports on a
sibling core) adds three rules; the RTL follows the Tecmo 16 and 1945k
III cores.

**Vsync on the hsync leading edge.** MiSTer's composite sync is HS XOR
VS, so a VS edge between hsyncs is an extra sync pulse, which bends or
unsyncs the top of a CRT picture. dy_video changed o_vs with the line
counter at pixel 0 (hsync is pixels 464-495). Vsync now starts at the
hsync leading edge of its first line and ends at the hsync leading edge
three lines later (vs_on, same pixel enable as the HS rise).

**Default sync positions (R1 still open).** Hsync pixels 464-495, as
before. Vsync: lines 251-254 at the hsync (was lines 250-252 from pixel
0), so the whole -4..+3 range stays inside vblank (from line 250 the +3
setting would start it on the last visible line, 247). At the 0 setting a
CRT shows the picture about 2 lines higher than with the 20261004
release; +2 is within 48 pixels of the old position. Primella family
(sadari, gundl94, primella): only lines 256-259 are blank at V_TOTAL 260,
and the 3-line vsync fills them (lines 256-259 at the hsync; was 257-258,
two lines). The CRT V position therefore does not apply on these three
sets (range reduced to 0); H position works as on the other games. In
the 256-line parity frame (M1/M2 sims) the primella family has no vsync,
as before.

**OSD CRT H/V Position** (status[27:24], [30:28], two's complement, the
sibling cores' encoding): hs_beg = 464 - 2h (h -8..+7, picture right for
positive), vs_beg = 251 - v (v -4..+3, picture down for positive), both
taken at the start of vblank (line 248; 256 on the primella family), so
they change only on whole frames. Only the sync pulses move: active area,
blanking, totals and game timing are unchanged. Margins: hsync starts at
450-480 and ends by pixel 511 (hblank 448-511 and 0-63); vsync starts on
lines 248-255 and ends by line 258 (vblank 248-259 and 0-7).

**OSD Flip Screen** (status[31]): the board has its own flip register
(per game control bit, spec 9.1), already applied by the renderer (tile
passes, text y scroll, sprite engine) from the copy taken at the register
latch (line 7). The OSD bit is XORed into it at that latch, so it takes
effect on whole frames and the game's Flip Screen DIP stays in the MRAs.
screen_rotate only turns the HDMI picture; its flip input stays 0.

**Status bits.** 24-31 were free (used: 0, 2, 3-5, 12-13, 22-23).

**Pixel enable.** dy_sys's enable is the PIX_NUM/PIX_DEN accumulator set
to 1/12 by the shell, i.e. exactly every 12th clock of 96 MHz (8 MHz),
and the shell hands the video to arcade_video with a fixed divide-by-6
enable on CLK_VIDEO (48 MHz). No fractional enable on hardware.

**Tests.**
- sim/m4/sync/tb_sync.cpp (dy_video alone, V_TOTAL 260): flytiger,
  rshark and sadari, all 16 x 8 offset pairs each. Checked: VS rises and
  falls on an HS rising edge, HS 32 pixels with a 512-pixel period, VS
  3 lines (1,536 pixels), HS only inside hblank and VS only inside
  vblank, HS start 400 - 2h pixels after the line's first active pixel,
  VS start the expected number of pixels before the first visible pixel
  (line 8, or line 0 on sadari with vs_beg fixed at 256). 384 pairs, 0
  fail. The same test on a copy with the vsync switched at the line start
  fails all 384.
- M2 canary, flytiger, 301 frames from power-on, against the MAME
  attract capture: unmodified RTL (baseline) and the new RTL both give 27
  images exact, 10 explained by live reads, 0 unexplained, 114 RAM dump
  files match; all 450 capture files of the two runs are byte-identical.
- Flip canary, same run with +osdflip=1: 64 of 75 images are the normal
  run turned 180 degrees exactly. The other 11 differ in one static strip
  (native x 9-23, the full height, pens 0x4xx; 1,048 to 1,115 pixels),
  so the board's flip is not a pure rotation there. The same run against
  MAME's Flip Screen DIP capture (flytiger_flip, frames to 300): 28
  images exact, 2 explained by live reads, 0 unexplained, 93 RAM dump
  files match, so the OSD flip gives exactly MAME's flipped picture,
  including that strip.
- The emu shell lints under Verilator with the framework stubs; the M4
  board harness builds (tb_board ties the new inputs to 0). The M2
  harness takes +osdflip=1, +crth=N, +crtv=N.

Not yet compiled or tried on a CRT.
