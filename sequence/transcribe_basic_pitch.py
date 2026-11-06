"""Transcribe an audio file (mp3, wav, ...) into notes with Spotify's basic-pitch.

Called by mp3ToTrk.m; runs in the .venv-basicpitch environment (see
setup_basic_pitch.sh). Writes, for an output prefix P:
    P_notes.csv   onset_s, offset_s, midi, amplitude  (one row per note)
    P.mid         the same notes as MIDI, for listening/inspection
    P_tempo.json  {"bpm": ..., "beats_s": [...]} from librosa's beat tracker

usage: python -I transcribe_basic_pitch.py AUDIO PREFIX [--onset 0.5]
       [--frame 0.3] [--min-note-ms 127.7]
"""
import argparse
import csv
import json
import logging

logging.disable(logging.WARNING)       # basic-pitch warns about every backend it doesn't find

import librosa
import numpy as np
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import predict


def main():
    """Transcribe the audio, write P_notes.csv, P.mid and P_tempo.json, print a summary."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audio")
    ap.add_argument("prefix")
    ap.add_argument("--onset", type=float, default=0.5, help="note onset threshold (basic-pitch default 0.5)")
    ap.add_argument("--frame", type=float, default=0.3, help="note frame threshold (basic-pitch default 0.3)")
    ap.add_argument("--min-note-ms", type=float, default=127.70, help="shortest note kept (basic-pitch default)")
    a = ap.parse_args()

    _, midi, events = predict(a.audio, ICASSP_2022_MODEL_PATH,
                              onset_threshold=a.onset, frame_threshold=a.frame,
                              minimum_note_length=a.min_note_ms)
    events = sorted(events, key=lambda e: (e[0], e[2]))
    with open(a.prefix + "_notes.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["onset_s", "offset_s", "midi", "amplitude"])
        for on, off, pitch, amp, _ in events:
            w.writerow([f"{on:.4f}", f"{off:.4f}", int(pitch), f"{amp:.4f}"])
    midi.write(a.prefix + ".mid")

    y, sr = librosa.load(a.audio, sr=22050, mono=True)
    tempo, beats = librosa.beat.beat_track(y=y, sr=sr, units="time")
    with open(a.prefix + "_tempo.json", "w") as f:
        json.dump({"bpm": float(np.atleast_1d(tempo)[0]), "beats_s": [round(float(b), 4) for b in beats]}, f)

    print(f"{len(events)} notes, tempo {float(np.atleast_1d(tempo)[0]):.1f} bpm, {len(beats)} beats")


if __name__ == "__main__":
    main()
