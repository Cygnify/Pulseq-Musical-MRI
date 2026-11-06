"""Read sheet music (MusicXML, .mxl, MIDI, ...) with music21 and write its notes.

Called by scoreToTrk.m; runs in the .venv-basicpitch environment (install music21
there too). Writes, for an output prefix P:
    P_notes.csv   onset_s, offset_s, midi, amplitude (1)   at the chosen tempo
    P_score.json  tempo, measure numbers and start times (s), and what was
                  changed on the way: repeats expanded, 8va/8vb lines (MusicXML
                  stores sounding pitch under them, so no shift is needed),
                  ties merged, grace notes skipped

Pitches are sounding pitches. Arpeggiated chords become block chords.
Dynamics are ignored (every amplitude is 1).

usage: python -I score_to_notes.py SCORE PREFIX [--bpm 60]
"""
import argparse
import csv
import json
import warnings

warnings.filterwarnings("ignore")
import music21 as m21


def main():
    """Parse the score, write P_notes.csv and P_score.json, print a summary."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("score")
    ap.add_argument("prefix")
    ap.add_argument("--bpm", type=float, default=0, help="tempo for the seconds (default: the score's first tempo mark)")
    a = ap.parse_args()

    s = m21.converter.parse(a.score)
    expanded = False
    try:
        e = s.expandRepeats()
        expanded = len(e.flatten().notes) != len(s.flatten().notes)
        s = e
    except Exception:
        pass
    n_ottava = len(list(s.recurse().getElementsByClass("Ottava")))
    try:
        s = s.toSoundingPitch()
    except m21.exceptions21.StreamException:
        pass                       # MIDI: pitches already sound as stored ("atSoundingPitch unknown")
    s = s.stripTies()

    marks = list(s.recurse().getElementsByClass("MetronomeMark"))
    bpm_score = marks[0].getQuarterBPM() if marks else None
    bpm = a.bpm or bpm_score or 60.0
    spq = 60.0 / bpm                                   # seconds per quarter note

    rows, n_grace = [], 0
    for el in s.recurse().notes:
        if isinstance(el, m21.harmony.ChordSymbol):    # chord names, not notes
            continue
        if el.duration.isGrace:
            n_grace += 1
            continue
        on = float(el.getOffsetInHierarchy(s))
        dur = float(el.duration.quarterLength)
        for p in el.pitches:
            rows.append((on * spq, (on + dur) * spq, int(p.midi)))
    rows.sort()
    with open(a.prefix + "_notes.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["onset_s", "offset_s", "midi", "amplitude"])
        for on, off, m in rows:
            w.writerow([f"{on:.4f}", f"{off:.4f}", m, "1.0000"])

    part = s.parts[0] if s.parts else s
    meas = list(part.getElementsByClass("Measure"))
    ts = list(s.recurse().getElementsByClass("TimeSignature"))
    info = {
        "bpm": bpm,
        "bpm_score": bpm_score,
        "n_tempo_marks": len(marks),
        "time_signature": ts[0].ratioString if ts else None,
        "measure_numbers": [m.number for m in meas],
        "measure_starts_s": [round(float(m.getOffsetInHierarchy(s)) * spq, 4) for m in meas],
        "end_s": round(float(s.highestTime) * spq, 4),
        "n_notes": len(rows),
        "n_grace_skipped": n_grace,
        "n_ottava_lines": n_ottava,
        "repeats_expanded": expanded,
    }
    with open(a.prefix + "_score.json", "w") as f:
        json.dump(info, f)
    print(f"{len(rows)} notes, {len(meas)} measures, tempo {bpm:g} bpm "
          f"(score {bpm_score}), {n_grace} grace notes skipped, {n_ottava} 8va/8vb lines (pitches read as sounding)")


if __name__ == "__main__":
    main()
