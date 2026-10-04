# M3 findings: sound (YM2151 + M6295 games)

Date: 2026-09-28. Scope: flytiger and bluehawk sound systems: sound Z80
(T80) with the sound ROM in BRAM, 2 KB RAM, the latch, jt51 (YM2151) and
jt6295 (M6295), in `rtl/dy_snd.sv`, inside `dy_sys`. Reproduce: `cd sim &&
make m3-wav m3` (7,300 frames = 121.7 s of each game from power-on, about
an hour with both games in parallel).

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| Mix level within 1 dB of MAME | PASS | flytiger +0.17 dB, bluehawk +0.29 dB over 121.7 s against MAME's WAV of the same run; 5 s segments: flytiger -0.26 to +0.50 dB, bluehawk -0.39 to +2.65 dB (the larger ones after its streams diverge, when different sounds play); 20 ms envelope correlation 0.988 / 0.90 |
| Register-stream parity for 2 minutes | PARTIAL | identical in order and value for 47 s on flytiger (YM2151 writes to frame 6,224 = 104 s, M6295 commands to frame 2,810) and 35 s on bluehawk (M6295 to frame 2,125, YM2151 to frame 3,224); after that the sound programs take different decisions (section 3) |
| Sound-ROM writes (spec T4) | PASS | order and values identical to MAME over the whole run: flytiger 73,266 of 73,266, bluehawk 98,050 against MAME's 98,054 (the 4 fall at the window edge) |

## 2. What was checked and matches MAME

- Sound CPU timing: T80's cycle count per instruction equals the documented
  Z80 timing for every opcode in the boot path, and MAME's sound CPU
  follows the same counts (its delay-loop registers sampled at 1/60 s put
  it at cycle 66,666 of 66,667). Both CPUs execute the same instruction
  sequence from reset to the first timer interrupt.
- MAME's logged beam positions for sound-CPU writes sit a constant 8 lines
  before ours, although both CPUs reach the write at the same cycle count
  from reset. The offset is in MAME's timestamps for the sound CPU, not in
  the core; `compare_snd.py` reports it as drift and allows 32 lines.
  **Corrected 2026-09-29 (ym2203_findings 4.1):** the offset was real. MAME's
  screen starts at the vblank line with its first vblank one frame later;
  our video counters started 8 lines further on. Fixed in dy_video; the
  drift is now -1..0 lines.
- YM2151 timer A period: 20,883 CPU cycles measured against 20,883.1 in
  theory (NA = 732 at 3.579545 MHz).
- M6295 status: MAME's status polled at each frame end from frame 320 to
  360 equals our channel busy bits on all 41 frames.
- Mix gains: MAME routes YM left and right at 0.35 and the M6295 at 0.42
  into one speaker; the core uses the same gains, with the M6295's 12-bit
  channel sum converted at MAME's 1/2048 of full scale.

## 3. Where the streams diverge

The sound programs poll the latch and the chip status from a YM timer
interrupt, and some of their decisions (for example whether to stop a
channel before starting a sample) depend on timing at the sub-millisecond
level. Two differences affect that timing:

1. Timer phase. jt51 steps its timers on its internal 64-clock sample
   cycle, so the first overflow after a load comes up to 64 YM clocks after
   the exact duration; MAME's ymfm counts the exact duration from the write.
   A real YM2151 is also clocked by its internal cycle, so jt51 is plausibly
   the closer of the two. A simulation-only MAME-style timer
   (`JT51_TIMER_EXACT`) moves the divergence points (bluehawk M6295 from
   frame 2,125 to 1,269; flytiger YM2151 identical through at least frame
   5,180) but does not remove them, so it is not the only cause.
2. Something not identified. With the MAME-style timer the flytiger M6295
   stream still diverges at frame 2,810 (a different sample chosen about a
   frame later). At one bluehawk status read MAME returns a channel as idle
   in the middle of a stop-and-restart sequence where the frame-end poll and
   our core both show it busy; the ordering inside one MAME scheduler slice
   decides that value.

Finding the remaining cause would need cycle-level co-simulation against
MAME's scheduler. MAME is not the ground truth here either (its scheduler
interleaves the two CPUs and the chips in time slices). The audible result
matches on level and envelope; which sample plays in a few overlapping
sound effects can differ. Open item R13 below; the core ships jt51's own
timers.

## 4. Built

| File | Content |
|---|---|
| `rtl/dy_snd.sv` | sound Z80 at 4 MHz, 64 KB ROM (BRAM, download port), 2 KB RAM, latch, jt51 at 3.579545 MHz (fractional enable, cen_p1 every other enable), jt6295 at 1 MHz pin 7 high, IRQ from the YM2151, mono mix with clamp |
| `rtl/vendor/jt51`, `rtl/vendor/jt6295` | from Hyper Duel (proven on hardware), see `rtl/vendor/SOUND_PROVENANCE.md` |
| `sim/m2/tb_sys.cpp` | now downloads the sound ROM, models the M6295 ROM port with latency, logs sound writes (`+snd`), OKI status reads and channel state, writes the mix at 48 kHz (`+wav`), and can trace sound-CPU opcode fetches with cycle counts (`+cputrace`) |
| `sim/m3/compare_snd.py` | register-stream comparison with MAME's write log |
| `sim/m3/compare_audio.py` | level and envelope comparison with MAME's WAV |

Simulation cost: 0.49 s per frame with sound (0.23 s without).

## 5. Open items

- R13: sound-program divergence from MAME after 35-47 s (section 3). Settle
  on hardware by ear first; if a difference is audible, compare with a PCB
  recording.
- lastday, gulfstrm, pollux: 2x YM2203 (jt03) sound and their main-system
  decode, per PLAN section 3.
- The OKI sample ROM is read through the harness model; on hardware it
  comes from SDRAM (M4).

## 6. Sound fixes from the 1945k III and Tecmo 16 cores (2026-10-03)

Two jt6295 patches (from the 1945k III core) and one change to the YM2151
write path (from the Tecmo 16 core); details and evidence in
`rtl/vendor/SOUND_PROVENANCE.md`, research item R17:

1. jt6295 phrase end: a phrase now plays through the second nibble of its
   stop byte, 2 x (stop - start + 1) samples, as MAME's okim6295 does.
   Before, busy cleared one sample (about 132 us) early.
2. jt6295 start to a busy channel: ignored, as MAME (okim6295.cpp
   L281-284) and jt6295's own README describe. Before, it restarted the
   phrase.
3. YM2151 writes (`rtl/dy_snd.sv`): held until the next `cen_p1`, because
   jt51 sets its busy flag only for a write on a `cen_p1` clock and the
   one-clock chip select hit it about once in 50 writes.

Believed accurate: the patched behaviour in all three (MAME's model, the
phrase table format, jt6295's documented intent and jt51's busy logic
agree; the OKI datasheet was not checked, R17).

### 6.1 Verification

Every YM2151/M6295 game booted from power-on in the dy_sys harness, built
from the same tree in three variants: base (HEAD jt6295 and dy_snd), patch
(jt6295 patches 1 and 2 only) and final (patches 1 and 2 plus the YM2151
write hold), with captures, the sound register log and the 48 kHz mix, at
the MRA DIP defaults (sadari/gundl94 DSWB FD, popbingo DSWA FB). Runs
stopped at frames 2,800 to 3,500 (47 to 58 s), past every known divergence
point; the shared machine ran them at about 750 frames an hour. Outputs:
`sim/build/m2/oki_base`, `oki_patch`, `oki_fix2` (final), comparison log
`sim/build/m2/oki_compare.txt`. The YM2203 games (lastday, gulfstrm,
pollux) have no M6295 and use jt03, which needed no change; they were not
re-run.

| Game | Streams vs MAME (base, patch and final identical) | First difference from base | Level vs MAME: base / final |
|---|---|---|---|
| flytiger | YM2151 21,510, M6295 408 and sound ROM 40,910 events identical to frame 2,950 | busy bits at vblank 2,285 (patch 1: a phrase ends one sample later) | +0.16 / +0.11 dB |
| bluehawk | YM2151 identical; M6295 first mismatch at frame 2,125 (R13, section 3) | busy bits at vblank 689 (patch 1) | +0.19 / +0.24 dB |
| sadari | YM2151 20,159 and M6295 76 identical to frame 2,950 | none | +0.23 / +0.43 dB |
| gundl94 | YM2151 20,159 and M6295 113 identical to frame 2,950 | none | +0.27 / +0.47 dB |
| superx | first mismatch M6295 frame 684, YM2151 frame 776 (R16, m68k_findings 4) | status read at frame 1,233 (0xF9 vs 0xF8, patch 1), program flow follows | +0.03 / +0.02 dB |
| rshark | first mismatch frame 1,481 (R16) | none | +0.50 / +0.44 dB |
| popbingo | YM2151 29,976 and M6295 39,227 identical to frame 2,800 | busy bits at vblank 2,428 (patch 1) | +0.49 / +0.36 dB |

The levels are over each run's common window with MAME's WAV (47 to 58 s),
so base and final columns cover slightly different lengths; base and patch
over the same window differed by 0.02 dB at most.

Results:
- Program flow and sound streams match MAME as far as before: the first
  MAME mismatch is the same event in all three variants on every game, and
  every one is a divergence documented before (R13, R16). The jt6295
  patches' own effects appear later (third column), so within the
  MAME-comparable window they neither improve nor worsen parity.
- The YM2151 write hold changed nothing in any logged stream: the final
  and patch logs are identical. In MAME the Dooyong sound drivers read the
  YM2151 status 10,814 (bluehawk) to 45,306 (superx) times per 1,200 frames
  and see busy set 0 times (read tap, `sim/build/ym_rd_tap.lua`): their
  writes are spaced wider than the busy time, so the flag never decides
  anything on these games. The fix stays for accuracy (the chip's busy flag
  now behaves) at no cost to parity.
- Loudness: none of these games re-sends start commands to a playing
  channel the way 1945k III and Solite Spirits do every frame (those were
  up to 15 dB too loud before patch 2), so the Dooyong mix is practically
  unchanged; every game stays within 0.5 dB of MAME.
- flytiger's streams now match MAME to frame 2,950 at least, past the
  2,810 of section 1. That predates these patches (base matches too): it
  came with the 2026-09-29 power-on timing fixes (ym2203_findings).

### 6.2 R13 status

Unchanged by these fixes. bluehawk still leaves MAME's path at frame 2,125
(M6295 event 1,455: the driver stops channel 1 before restarting it where
MAME restarts it directly), with all three variants. The YM2151 busy flag
is ruled out as a cause (6.1), as the YM timer period and M6295 status were
before (section 3). Still open; settle by ear on hardware first.

### 6.3 Not taken: the Tecmo 16 core's jt6295 busy patch

The Tecmo 16 core also updates jt6295's busy flags only at `cen4`, from the
committed channel state, to stop a start command's first byte from
cancelling a stop that is not yet committed (Ganbare Ginkun's stepped
fade-outs). Built and run here with the other patches, it moved bluehawk's
first MAME mismatch from frame 2,125 to 1,269: at frame 331 the driver
stops channel 1 and reads the status straight away; the patched chip still
showed channel 1 busy (0xF3), the unpatched one idle (0xF2), and later
decisions followed that read. MAME clears a voice at the stop write
(okim6295.cpp write(), silence command), so the status shows idle at once:
the patch moves jt6295 away from MAME on this pattern. Runs kept in
`sim/build/m2/oki_fix3_rejected`. A fix faithful to MAME on both games
needs a stop visible to status at once and a start's first byte that does
not clear pending stops in `jt6295_ctrl.v`; not done here (R17).

### 6.4 Build

Compile on 2026-10-03 15:23 (Quartus 17.0 Lite, E-core task `dycompile`):
every clock non-negative (96 MHz core setup +0.894 ns, hold +0.243 ns;
video setup +3.530 ns), 22,767 ALMs (54%), 497 of 553 RAM blocks (90%), 46
DSP. RBF md5 `211c23913a474de03e9d4e9356ef3c4a`. An earlier attempt that
morning did not run: the PC crashed a minute after Quartus started
(Kernel-Power 41), the known instability; a compile at 11:32 with the
jt6295 patches only (no YM2151 change) also met timing (+0.472 ns) and was
superseded.

### 6.5 jt6295 patch 3: BUSY as the datasheet (2026-10-03, R17, R13)

Section 6.3 left a stop/start fix open. It is now in
(rtl/vendor/SOUND_PROVENANCE.md, patch 3; the same jt6295 files as the
1945k III, Tecmo 16 and Hyper Duel cores): the status read (BUSY) is timed as the MSM6295 datasheet
(p. 73: "BUSY becomes "H" after 15 x n clock" from a start's second
byte; after a stop, "voice playback stops all the next sample and BUSY
becomes "L""); whether a start is accepted follows MAME's per-voice
"playing" flag, since the datasheet does not cover a start to a playing
channel or a restart within one sample of a stop; a start's first byte no
longer clears pending stops; a stop cancels a queued start for its
channel; the ADPCM decoder resets on every start.

Two versions were run here (dy_sys harness, recipe of 6.1; compared with
MAME by `m3/compare_snd.py`; scripts `sim/build/m2/fixd_runs.sh`,
`fixe_runs.sh`):

| Game | MAME-timed status (tried, not kept) | Datasheet-timed status (kept) |
|---|---|---|
| bluehawk | YM2151 13,274, M6295 1,491, sound ROM 28,210 events identical to MAME to frame 2,400 | first difference frame 2,121 (status read 0xFB, MAME 0xFA, 8 us after a stop); M6295 first mismatch frame 2,125, event 1,455, as in 6.1 |
| flytiger | identical to MAME to frame 2,400 | identical to MAME to frame 1,200 |
| sadari | identical to MAME to frame 2,400 | not re-run |
| popbingo | identical to MAME to frame 2,400 | not re-run |

R13 explained: at frame 2,121 the driver stops channel 0 and reads the
status 8 us later. The datasheet says BUSY stays high until the next
sample (up to 132 us), so the real chip almost certainly answers busy
(0xFB) there, as the core does; MAME answers idle at once. The driver
then remembers channel 0 as busy and, at frame 2,125, stops it again
before restarting it, where MAME restarts it directly. Class: MAME wrong
per datasheet. The MAME-timed version, which removes the divergence,
confirms that this read is the whole cause. Whether a given read lands
before the sample point depends on the chip's sample phase, so a real
board may take either path at that frame.

| Game | Result against MAME | Class |
|---|---|---|
| Blue Hawk (Dooyong) | first difference frame 2,121: a status read 8 us after a stop returns 0xFB (busy), MAME 0xFA; the program then differs from frame 2,125 (the old R13 point) | MAME wrong per datasheet |
| Flying Tiger (Dooyong) | identical to MAME (to frame 1,200) | none |
| Sadari, Pop Bingo (Dooyong) | identical to MAME with the MAME-timed version (to frame 2,400); not re-run with the datasheet timing | not measured |
| Ganbare Ginkun (Tecmo 16) | commands identical in order and value; M6295 writes up to 280 us later (its fade polls wait for the real BUSY); level -0.01 dB, correlation 0.999 | MAME wrong per datasheet, timing only |
| Final Star Force play (Tecmo 16) | M6295 writes up to 99 us later; level -0.02 dB | MAME wrong per datasheet, timing only |
| 1945k III, Solite Spirits, '96 Flag Rally | output and I/O identical to the previous build (1945k III 2,001 frames, Solite Spirits 4,001, Flag Rally 2,001) | none |
| Hyper Duel, Magical Error | the games never read the status; MAME's OKI streams replayed through the chip: level within 0.004 dB | none |

Not built: a video change is being added first, then one build.

## 7. FM chips reset with a clock enable (2026-10-04)

**Cause.** jt51 and jt03 load their reset values only by shifting with
their clock enable while `rst` is high (`jt51_sh`, `jt12_sh`; jt03.v: "rst
should be at least 6 clk&cen cycles long"; the YM2151 and YM2203 data sheets
ask for an IC pulse covering many clock cycles). `dy_snd.sv` held both
enables at 0 in reset, so the operator state (attenuation, envelope phase)
was never initialised. The YM2203 FM outputs sat at a large constant until
the first writes; the first-write gate from the YM2203 work (ym2203
findings) hid that constant but not the uninitialised operators behind it.
Found by the Side Arms variants core's M3 (sidearms-mister e3bc730) and the
DEC8 core's M3 (dec8-mister fb9b52f).

**Fix.** A reset-only enable drives jt51 and jt03 while `rst_n` is low: one
pulse every 8 clocks, 4,608 pulses. 4,608 = 72 x 64 is a whole number of
jt03 slot cycles (prescaler 6 x 12 slots) and jt51 slot cycles (64 enables),
so the chips' free-running counters (`jt12_div` prescaler, `jt12_reg` slot
counter, which `rst` does not clear) leave reset at the same phase as before
and every timer and busy edge after the release is unchanged. A first build
with 4,096 pulses left the YM2203 slot counter at a different phase; Pollux's
timer-driven writes then landed 31 pixels earlier and its sound program left
MAME's path at write 91,818, so the count matters. The normal enables still
restart from 0 at the release. The first-write FM gate is removed: the raw
FM tap is 0 before the first write without it (Pollux, frames 1-12).

**Verification** (600 frames from power-on, old build vs fix, 48 MHz
harness; MAME 0.288 WAVs from `make m3-wav`):

| Game | Sound CPU write log | Window | RMS old | RMS fix | RMS MAME |
|---|---|---|---|---|---|
| Flying Tiger (Z80, YM2151) | identical (9,912 lines) | 1.0-1.5 s | 3,597 | 2,753 | 2,846 |
| | | 2-6 s | 2,292 | 2,296 | 2,349 |
| Sadari (Primella, YM2151) | identical (7,182 lines) | 1-4 s | 4,024 | 3,187 | 3,217 |
| | | 5-9 s | 2,703 | 0 | 0 |
| Pollux (YM2203 x2) | identical (134,066 lines) | 0.5-4 s | 15.7 | 0 | 0 |
| | | 5-8 s | 9,197 | 9,151 | 9,220 |
| R-Shark (68000, YM2151) | identical (58,467 lines) | 0.5-2 s | 10,392 | 3,960 | 3,988 |
| | | 2.5-6 s | 6,354 | 6,356 | 6,463 |

Every sound CPU write, status read and vblank marker is identical in all four
runs, so program flow is unchanged. The audio now matches MAME in every
window. The old build played sound MAME does not: Sadari a sustained tone
from about 5 s where MAME is silent (and +2 dB from 1 to 4 s; over the whole
run Sadari was 3.9 dB above MAME, now -0.13 dB), R-Shark about 8 dB of extra
sound in its first two seconds, Flying Tiger 2 dB extra around 1 s, Pollux
faint noise for its first four seconds. Accurate side: the fix; the real
chips are reset by IC on the board, and MAME's reset matches.

This explains the earlier "FM sits at a constant until the first write"
note in the YM2203 work: it was this missing reset, not a property of the
chip.
