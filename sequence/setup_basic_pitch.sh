#!/bin/sh
# setup_basic_pitch.sh  Make .venv-basicpitch (Spotify basic-pitch) next to this script.
# Used by mp3ToTrk.m; scoreToTrk.m also needs music21 installed in this environment.
# Requires uv (https://github.com/astral-sh/uv).
#
# - Python: macOS's own /usr/bin/python3 (3.9), since basic-pitch supports 3.8-3.11;
#   elsewhere, point --python at a 3.8-3.11 interpreter.
# - setuptools < 81: resampy (a basic-pitch dependency) still imports
#   pkg_resources, which setuptools 81 removed.
# - On macOS basic-pitch runs its CoreML model; no TensorFlow needed.
set -e
cd "$(dirname "$0")"
uv venv --python /usr/bin/python3 .venv-basicpitch
uv pip install --system-certs --python .venv-basicpitch/bin/python basic-pitch "setuptools<81"
