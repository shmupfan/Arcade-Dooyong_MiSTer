# Dooyong - MiSTer FPGA Core

The Dooyong arcade hardware family (1990-1996) for MiSTer: ten games and
25 MAME sets from one RBF.

<img src="docs/images/lastday.png" width="13.5%" alt="The Last Day"> <img src="docs/images/gulfstrm.png" width="13.5%" alt="Gulf Storm"> <img src="docs/images/pollux.png" width="13.5%" alt="Pollux"> <img src="docs/images/flytiger.png" width="13.5%" alt="Flying Tiger"> <img src="docs/images/bluehawk.png" width="13.5%" alt="Blue Hawk"> <img src="docs/images/superx.png" width="13.5%" alt="Super-X"> <img src="docs/images/rshark.png" width="13.5%" alt="R-Shark">

<img src="docs/images/sadari.png" width="32.5%" alt="Sadari"> <img src="docs/images/gundl94.png" width="32.5%" alt="Gun Dealer '94"> <img src="docs/images/popbingo.png" width="32.5%" alt="Pop Bingo">

*Frames rendered by this core (Verilator simulation of the RTL, which is
pixel-exact against MAME and identical to what the MiSTer displays).*

| Game | Year | Main CPU | Sound | Screen |
|---|---|---|---|---|
| The Last Day (+ set 2, Chulgyeok D-Day) | 1990 | Z80 | 2x YM2203 | vertical |
| Gulf Storm (+ 4 alternates) | 1991 | Z80 | 2x YM2203 | vertical |
| Pollux (+ 3 alternates) | 1991 | Z80 | 2x YM2203 | vertical |
| Flying Tiger (+ set 2) | 1992 | Z80 | YM2151 + M6295 | vertical |
| Blue Hawk (+ 2 NTC sets) | 1993 | Z80 | YM2151 + M6295 | vertical |
| Sadari | 1993 | Z80 | YM2151 + M6295 | horizontal |
| Gun Dealer '94 (+ Primella) | 1994 | Z80 | YM2151 + M6295 | horizontal |
| Super-X (+ Mitchell set) | 1994 | 68000 | YM2151 + M6295 | vertical |
| R-Shark (+ set 2) | 1995 | 68000 | YM2151 + M6295 | vertical |
| Pop Bingo | 1996 | 68000 | YM2151 + M6295 | horizontal |

Every game's video is pixel-exact against MAME in simulation.

The CPUs and sound chips use established cores: T80 (Daniel Wallner),
fx68k (Jorge Cwik), and jt51, jt6295, jt03 and jt49 (Jose Tejada,
jotego; see CREDITS.md). The video hardware (ROM tilemaps, sprites,
text layer) is new work, one renderer covering all ten games.

## Install

### With Update All (recommended)

Add these two lines to `/media/fat/downloader.ini` on your SD card:

```ini
[shmupfan]
db_url = https://raw.githubusercontent.com/shmupfan/Distribution/main/db.json
```

Then run Update All (or `downloader`) from the Scripts menu. It installs the
core and every MRA, including the alternative sets, and keeps them up to
date on later runs. The same entry also brings in other
[shmupfan](https://github.com/shmupfan/Distribution) cores as they are
released.

### Manually

Copy `releases/Arcade-Dooyong_*.rbf` to `/media/fat/_Arcade/cores/` and
the MRA files in `releases/` to `/media/fat/_Arcade/`. Alternative sets
are in `releases/_alternatives/` and go to
`/media/fat/_Arcade/_alternatives/`.

### ROMs

You need the MAME ROM sets (0.288/0.289 naming) in
`/media/fat/games/mame/`: `lastday.zip`, `gulfstrm.zip`, `pollux.zip`,
`flytiger.zip`, `bluehawk.zip`, `sadari.zip`, `gundl94.zip`,
`superx.zip`, `rshark.zip`, `popbingo.zip`. Clone sets load from their
parent zip. No ROM data is included in this repository.

## Controls and options

Buttons: Button 1, Button 2, Start, Coin, Service, plus Button 3 on
Sadari and the 68000 games. Keyboard uses the MAME defaults (arrows,
Left Ctrl, Left Alt or Space, Left Shift, 1/2 start, 5/6 coin, 9
service; player 2 on R/F/D/G, A, S, Q).

OSD: DIP switches per game (from the MAME driver), aspect ratio,
orientation for the vertical games, the standard scandoubler options,
HDMI scale (Normal, V-Integer, Narrower or Wider HV-Integer), and the CRT
options below.

CRT options: Flip Screen (the vertical games only; not offered for
Sadari, Gun Dealer '94, Primella and Pop Bingo) turns the picture 180
degrees in the core (it inverts the game's own flip screen setting), so
it works on a CRT. CRT H Position (2 pixels a step, -16 to +14) and CRT V
Position (1 line a step, -4 to +3) move the picture on a CRT by moving
the sync pulses; the picture area and the game's timing do not change.
Vertical sync starts and ends on a horizontal sync pulse, so composite
sync (SCART) has no stray pulse above the picture. On Sadari, Gun Dealer
'94 and Primella the vertical position is fixed: these games show all 256
lines, and the vertical sync fills the 4 blank lines of the frame. I have
checked these options in simulation; I have not tried them on a CRT yet.

The vertical games are rotated only over HDMI. On a CRT the picture is
not rotated; all of them are ROT270 games, so on a monitor mounted for
ROT90 games, set Flip Screen to On.

## Accuracy notes

MAME is the reference: every video block was checked pixel for pixel
against MAME frame dumps, and each full system was booted from power-on
and compared with MAME frame by frame. Where MAME and the real hardware
are likely to differ, the core follows the hardware, and the difference
is logged as a research item in [docs/PLAN.md](docs/PLAN.md) and the
findings documents.

- **CPU timing.** T80 samples interrupts on the last clock of an
  instruction, as a real Z80 does, and fx68k runs the 68000's E-clock
  synchronised autovector cycle. MAME times both differently, so demo
  modes eventually drift apart from MAME (usually after tens of seconds
  to minutes). See docs/ym2203_findings.md and docs/m68k_findings.md.
- **Power-on state.** Video timing starts where MAME's screen does, and
  the Z80's IX/IY start at 0xFFFF as in MAME (Pollux reads IY before
  setting it).
- **Scroll registers** are latched once per frame, matching MAME's
  whole-frame draw. Whether the real boards latch is not known; on the
  68000 games an unlatched board would show a split near line 123.
- **Sadari / Gun Dealer '94 / Primella** show all 256 lines, as MAME
  does, which leaves only 4 blank lines per frame (the vertical sync
  fills them). That is fine over HDMI; analog CRT output is untested.
- **YM2203 levels** are fitted to MAME's audio (within 0.3 dB); the
  YM2203 core's output is held silent until its first register write,
  where it otherwise sits at a large DC level.

## Architecture

- Z80 main CPU (T80) or 68000 (fx68k), selected per game by the MRA
- Scanline renderer: up to four ROM tilemap layers (32x32, or 16x16 with
  a colour ROM), the RAM text layer, and the Z80 or 68000 sprite list;
  runs up to three lines ahead of the display to absorb heavy lines
- Sound Z80 with YM2151 + M6295 or 2x YM2203
- SDRAM for graphics and samples; program ROMs and RAM in BRAM
- 96 MHz system clock, 8 MHz pixel clock, 512 x 260 at 60.10 Hz

## Layout

```
Arcade-Dooyong.*    Quartus 17 project (qpf/qsf/sdc/srf) and the MiSTer
                    shell (Arcade-Dooyong.sv)
files.qip           Quartus file list, sourced by the qsf
sys/                MiSTer framework
rtl/                the core (dy_*.sv) + rtl/vendor/ cores
releases/           released RBF + MRA files (_alternatives/ for alt sets)
docs/               system spec, plan and research items, findings per
                    milestone
reference/          vendored MAME sources (BSD-3-Clause, the behavioural
                    reference)
sim/                Verilator harness: frame replay against MAME, system
                    boots, sound streams, board-level SDRAM simulation
tools/              ROM image builder, MRA generator (proves each MRA
                    rebuilds the SDRAM image byte for byte), deploy script
```

## Building and verifying

- Simulation: Verilator 5.x and Python 3; the MAME reference captures
  need MAME 0.288 and your ROM sets (`sim/Makefile` lists the targets:
  `m1-verify`, `m1-extra`, `m1-synth` for video, `m2-boot`,
  `m2-primella` for full systems, `m4-boot` for the board with SDRAM)
- Synthesis: Quartus 17 project at the repo root. Releases are only
  built from a fit with every clock meeting timing

## License and credits

GPL-3.0-or-later for the combined work. Vendored components keep their
own licences and headers. See `LICENSE` and `CREDITS.md`. The core
relies on MAME's Dooyong driver by Nicola Salmoria, Vas Crabb and contributors.
