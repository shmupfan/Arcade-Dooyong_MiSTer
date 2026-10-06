# Releases

Released bitstreams and MRA files, in the MiSTer-devel arcade layout.

Copy `Arcade-Dooyong_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`, the
MRA files to `/media/fat/_Arcade/`, and the ROM sets (MAME 0.288/0.289
naming) to `/media/fat/games/mame/`.

Alternative versions live in `_alternatives/_<game>/` and are copied to
`/media/fat/_Arcade/_alternatives/_<game>/`.

| File | md5 | Notes |
|------|-----|-------|
| `Arcade-Dooyong_20261006.rbf` | `64109b3d93f719a8a0af178ec81f9564` | Vertical sync on the horizontal sync edge, so composite sync no longer disturbs the top of a CRT picture (it starts one line later: at the default the picture sits about 2 lines higher on a CRT, CRT V Position +2 restores the old place); new OSD options CRT H Position, CRT V Position (not for Sadari, Gun Dealer '94, Primella) and Flip Screen for the vertical games. |
| `Arcade-Dooyong_20261004.rbf` | `d1e427221be7c1f96ba48086fa8a5ded` | Replaced by 20261006 (in git history). Updated the same day (first build `feafc9e4066f203c5d04789f7bcf3be2`): the YM2151 and YM2203s now reset properly (their clock enable runs during reset), so Sadari's tone and Pollux's noise in the first seconds after power-on are gone and R-Shark and Flying Tiger start at the right level; audio matches MAME from power-on. Also: M6295 BUSY timed as the datasheet, phrase end and start handling as MAME, YM2151 writes timed to the chip clock (docs/m3_findings.md); video sync keeps running (black) during the ROM download instead of stopping; HDMI scale options (docs/m4_findings.md section 6). |
| `Arcade-Dooyong_20260930.rbf` | `29d749eb7c4166184e12fde7f8eeccdf` | First release: all ten games, 25 sets. Replaced by 20261004 (in git history). |

Every released RBF passed, in order: frame replay against MAME for
every game (video pixel-exact), full-system boots against MAME from
power-on, a board-level simulation through the MRA stream and the SDRAM
model, and a clean Quartus timing summary (every clock non-negative);
20260930 was also deployed to a MiSTer with an md5 check and played.
