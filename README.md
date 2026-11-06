# Pulseq Musical MRI

Plays music on the gradient coils of a GE MRI scanner. A score is converted to a simple
tracker format (`.trk`), and each note becomes a sine gradient waveform on one axis: each
column of the score drives one gradient axis (x, y, z, in the order given by its `axes`
line), with up to two notes per axis played as their sum. The score converters place the
bass on x, inner voices on y and the melody on z. Each score line becomes one Pulseq block,
and notes are struck and decay like a piano's. The sequence is written in MATLAB with
[Pulseq](https://github.com/pulseq/pulseq) and converted for GE scanners with
[pulseg](https://github.com/HarmonizedMRI/pulseg) and
[pge2](https://github.com/HarmonizedMRI/pge2). It was run on a GE SIGNA Premier 3T and a
GE SIGNA PET/MR 3T. There is no imaging: the output is sound.

## Contents

| File | Purpose |
| --- | --- |
| `sequence/writePianoTracker.m` | The writer: `.trk` -> `.seq` -> `.pge` for each scanner, plus a `_preview.wav` of the gradient waveforms. Options are `PIANO_*` environment variables, listed in its header. |
| `sequence/readTracker.m` | Reads a `.trk` score. |
| `sequence/previewTracker.m` | Renders a `.trk` as piano-like audio to check the notes by ear (not what the scanner plays). |
| `sequence/notesToTrk.m` | Reduces a note list to a 3- or 6-voice `.trk` that fits the interpreter's limits. |
| `sequence/scoreToTrk.m`, `sequence/score_to_notes.py` | Sheet music (MusicXML, `.mxl`, MIDI) -> `.trk`, read with music21. |
| `sequence/mp3ToTrk.m`, `sequence/transcribe_basic_pitch.py` | Audio (mp3, wav, ...) -> `.trk`, transcribed with Spotify's basic-pitch. |
| `sequence/setup_basic_pitch.sh` | Creates the Python environment `sequence/.venv-basicpitch` for the two converters. |
| `sequence/scores/moonlight1_6note_b1_24.trk` | Included score: Beethoven, Piano Sonata No. 14 ("Moonlight"), 1st movement, bars 1-24, 6 voices. |
| `checkGELimits.m` | Checks a sequence against the pge2 interpreter's limits: segments, blocks per segment, parent blocks, waveform memory, ADC blocks and a gradient-heating estimate. |
| `geScannerOpts.m` | Per-scanner pge2 settings (`pge2.opts`, PNS weights, file suffix, header slew option). |
| `matlab/startup_pulseq.m` | Puts the pinned Pulseq / pulseg / pge2 toolboxes from `libs/` on the MATLAB path. |
| `setup.sh`, `versions.lock` | Clone the pinned toolchain into `libs/`. |
| `LICENSE` | MIT license. |

### The `.trk` format

A plain-text score (see `readTracker.m`). An excerpt of the included score:

```
bpm 47.5
steps_per_beat 12
axes x y z

[1]
4   C#2      C#3      G#3
4   .        .        C#4
4   -        B2       G#3

play 1 2 3
```

- `bpm` and `steps_per_beat` set the length of a step, the duration unit of event lines.
- `axes` lists the gradient axis of each note column, in order.
- `[label]` starts a section. Each section becomes one segment on GE; a section played again
  reuses its segment.
- An event line is a duration in steps, then one token per axis: a note (letter, optional
  `#` or `b`, octave: `F#2`, `Bb3`, `C4`), `.` to hold what that axis played on the line
  above (not re-struck), `-` for silence, or `a+b` for two notes on the axis (each a note,
  `.` or `-`: `E2+B2`, `.+D3`).
- `play` gives the section order (default: file order). `#` starts a comment.

## Requirements

- MATLAB.
- Pulseq v1.5.1, pulseg and pge2 at the commits pinned in `versions.lock`, fetched by
  `./setup.sh` into `libs/` (needs git).
- Optional, to import scores or audio: Python with
  [music21](https://github.com/cuthbertLab/music21) (MIDI/MusicXML) and/or
  [basic-pitch](https://github.com/spotify/basic-pitch) (audio).
  `sequence/setup_basic_pitch.sh` creates `sequence/.venv-basicpitch` with basic-pitch
  (it uses [uv](https://github.com/astral-sh/uv) and macOS's `/usr/bin/python3`; edit it
  to point at another Python 3.8-3.11 elsewhere).
- To play on a scanner: the pge2 interpreter on the GE scanner, see
  [HarmonizedMRI/pge2](https://github.com/HarmonizedMRI/pge2).

## Quick start

```bash
cd Pulseq-Musical-MRI
./setup.sh
```

Then in MATLAB, from the repository root, build the included score. The writer is a script
that starts with `clear`, so it takes its options from environment variables:

```matlab
setenv('PIANO_SCORE', 'scores/moonlight1_6note_b1_24.trk');  % relative to sequence/, or a full path
setenv('PIANO_SCANNER', 'premier');
setenv('PIANO_RASTER', '48');                                 % gradient raster in us
run('sequence/writePianoTracker.m')
```

Always set `PIANO_SCORE`: the writer's built-in default score is not included in this
repository.

These are the settings the score was played with on the Premier. The writer sizes the
loudness to the heating limit, checks the result (see below) and writes to `sequence/`
(or to `PIANO_OUTDIR`):

- `moonlight1_6note_b1_24.seq`: the Pulseq sequence;
- `moonlight1_6note_b1_24.pge` (and a `.mat`): the file for the scanner;
- `moonlight1_6note_b1_24_preview.wav`: the summed gradient waveforms, to listen to first.

Without `PIANO_SCANNER`, it writes a `.pge` for each scanner (`_petmr` suffix for the
PET/MR). Built files are not included because they are large (the `.seq` and `.pge` are
about 20-25 MB each).

`PIANO_SCANNER=premier` checks the file against an interpreter built with larger limits than
the stock pge2 interpreter: 128 segments, 1024 blocks per segment and 1024 parent blocks
instead of 32, 256 and 128 (`tp_defs.h`). The included score has more distinct blocks than
the stock limit allows (233, see its header), so it needs such a build. Without
`PIANO_SCANNER`, the writer checks against the stock limits and stops with an error if the
score does not fit.

The other options (`PIANO_AMP`, `PIANO_MAXSAMPLES`, `PIANO_MAXBLOCK`, `PIANO_LEADIN`,
`PIANO_SEGMENTS`) are described in the header of `writePianoTracker.m`.

## Making your own score

- **MIDI or MusicXML** (e.g. exported from MuseScore): run `sequence/setup_basic_pitch.sh`,
  install music21 into the same environment
  (`uv pip install --python sequence/.venv-basicpitch/bin/python music21`), then in MATLAB:

  ```matlab
  addpath sequence
  scoreToTrk('mypiece.mid', 'measures', [1 16]);   % writes sequence/mypiece_score.trk
  ```

  Up to 6 notes sound at a time (two per axis); a picker chooses which when more do.
- **Audio**: run `sequence/setup_basic_pitch.sh`, then
  `mp3ToTrk('mysong.mp3', 'tStart', 0, 'tEnd', 30)` (writes `sequence/mysong_mp3.trk`).
  Automatic transcription is approximate, so expect to edit the result.
- **By hand**: write a `.trk` in the format above.

`notesToTrk` (used by both converters) fits the score to the stock interpreter limits by
default, dropping short notes and inner voices if needed, and reports whether the waveform
memory fits; its options are listed in its header (for example `'maxParentBlocks'` for an
interpreter with larger limits). Converted files are written as `<name>_score.trk` or
`<name>_mp3.trk`, and transcriptions are cached in `sequence/transcriptions/`.

Check a score by ear with `previewTracker('sequence/mypiece_score.trk', 'preview.wav')`,
then build it with `writePianoTracker` as in the quick start (`PIANO_SCORE`).

## Safety and limits

- The writer sizes the note amplitude so that the worst 20 s window of a gradient-heating
  estimate (`checkGELimits.m`, a model of the interpreter's check calibrated on the PET/MR)
  is just under 95% of the limit. Each note is also capped in slew rate, and the summed
  amplitude per axis in peak gradient.
- `checkGELimits.m` checks the interpreter's structural limits, the waveform memory and the
  heating estimate; `pge2.check` checks gradient amplitude, slew and PNS for each scanner,
  and `pge2.validate` compares the converted waveforms with the `.seq`.
- Scanner limits and PNS weights are in `geScannerOpts.m`; review them for your system.
  It writes 0 as the peak slew in the `.pge` header, which skips the interpreter's own slew
  check on the scanner, so slew is enforced only by the desktop checks above. With
  `PIANO_SCANNER=premier`, heating over the estimate's limit is a warning only, and the
  scanner's own heating check decides.
- Only play these files on a scanner you are authorised to use, following your site's MR
  safety rules. Gradient music is loud: use hearing protection for anyone in the scanner
  room.

## Notes

The included score is an arrangement of the first movement of Beethoven's Piano Sonata
No. 14 ("Moonlight"), a public-domain composition. Please only convert music you have the
rights to use.

## Citation

An abstract describing this work has been submitted to ISMRM 2027; a citation will be added.

## License

MIT, see [LICENSE](LICENSE).
