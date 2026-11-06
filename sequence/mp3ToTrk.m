function [trkFile, rep] = mp3ToTrk(audioFile, varargin)
% mp3ToTrk  Audio (mp3, wav, ...) -> notes -> tracker score (.trk) for writePianoTracker.
%   [trkFile, rep] = mp3ToTrk(audioFile, ...)
%
%   1. Notes: Spotify's basic-pitch (transcribe_basic_pitch.py, in the .venv-basicpitch
%      environment made by setup_basic_pitch.sh). The note list, a MIDI file and
%      librosa's tempo/beat estimate are cached in transcriptions/<name>_* (per
%      threshold set); pass 'retranscribe' to redo.
%   2. Grid: the detected tempo and its first beat after tStart, unless 'bpm' and/or
%      'gridOffset' are given.
%   3. notesToTrk: 3 voices by default, sections, fitted to the GE limits.
%   Then play the .trk with writePianoTracker (PIANO_SCORE).
%   Automatic transcription is approximate: check the result with previewTracker.
%
%   Inputs
%     audioFile   char   mp3, wav, ... (anything libsndfile reads)
%
%   Options (others go to notesToTrk: voices, picker, stepsPerBeat, sectionBeats, ...)
%     'out'           char     .trk to write (default: <name>_mp3.trk next to this file;
%                              the suffix keeps it apart from a hand-written <name>.trk,
%                              also on case-insensitive file systems)
%     'tStart','tEnd' [1]      excerpt (s)
%     'bpm'           [1]      tempo override
%     'minBpm'        [1]      a detected tempo below this is doubled until it isn't (60):
%                              beat trackers often lock onto half the tempo of slow
%                              pieces. Too fine a grid costs little; too coarse merges notes.
%     'gridOffset'    [1]      a grid line, s after tStart (default: first detected beat)
%     'retranscribe'  logical  run basic-pitch even if cached (false)
%     'onset','frame' [1]      basic-pitch thresholds (0.5, 0.3)
%     'minNoteMs'     [1]      basic-pitch's shortest note (127.7)
%     'quietNotes'    logical  also run a sensitive pass and let notesToTrk add its
%                              quiet chord tones, which the default pass can miss
%                              (default: on with 'picker' 'musical')
%     'quietOnset','quietFrame' [1]  thresholds of that pass (0.25, 0.15)

p = inputParser;
p.KeepUnmatched = true;
p.addParameter('out', '');
p.addParameter('tStart', 0);
p.addParameter('tEnd', Inf);
p.addParameter('bpm', []);
p.addParameter('minBpm', 60);
p.addParameter('gridOffset', []);
p.addParameter('retranscribe', false);
p.addParameter('onset', 0.5);
p.addParameter('frame', 0.3);
p.addParameter('minNoteMs', 127.7);
p.addParameter('quietNotes', []);
p.addParameter('quietOnset', 0.25);
p.addParameter('quietFrame', 0.15);
p.parse(varargin{:});
o = p.Results;

here = fileparts(mfilename('fullpath'));
[~, name] = fileparts(audioFile);
name = regexprep(name, '[^\w-]+', '_');      % 'My Song' -> 'My_Song'
if isempty(o.out), o.out = fullfile(here, [name '_mp3.trk']); end
py = fullfile(here, '.venv-basicpitch', 'bin', 'python');
assert(isfile(py), 'mp3ToTrk: no %s; run setup_basic_pitch.sh first', py);
assert(isfile(audioFile), 'mp3ToTrk: no file %s', audioFile);

%% 1. Transcribe (cached)
prefix = sub_transcribe(py, here, audioFile, name, o.onset, o.frame, o.minNoteMs, o.retranscribe);
notes = readmatrix([prefix '_notes.csv']);
tempo = jsondecode(fileread([prefix '_tempo.json']));
quiet = [];
if isempty(o.quietNotes)
    o.quietNotes = isfield(p.Unmatched, 'picker') && strcmp(p.Unmatched.picker, 'musical');
end
if o.quietNotes
    qp = sub_transcribe(py, here, audioFile, name, o.quietOnset, o.quietFrame, o.minNoteMs, o.retranscribe);
    quiet = readmatrix([qp '_notes.csv']);
end

%% 2. Grid
bpm = o.bpm;
if isempty(bpm)
    bpm = tempo.bpm;
    while bpm < o.minBpm, bpm = 2*bpm; end
end
off = o.gridOffset;
if isempty(off)
    beats = tempo.beats_s(tempo.beats_s >= o.tStart);
    off = 0; if ~isempty(beats), off = beats(1) - o.tStart; end
end
fprintf('mp3ToTrk: %d notes; tempo %.2f bpm (detected %.2f), grid offset %.3f s\n', ...
    size(notes, 1), bpm, tempo.bpm, off);

%% 3. Reduce
src = sprintf('%s (basic-pitch onset %g frame %g; librosa tempo %.1f bpm)', ...
    audioFile, o.onset, o.frame, tempo.bpm);
args = [fieldnames(p.Unmatched) struct2cell(p.Unmatched)]';
if o.quietNotes
    src = sprintf('%s; quiet chord tones from onset %g frame %g', src, o.quietOnset, o.quietFrame);
end
[trkFile, rep] = notesToTrk(notes, o.out, 'bpm', bpm, 'gridOffset', off, ...
    'tStart', o.tStart, 'tEnd', o.tEnd, 'source', src, 'quiet', quiet, args{:});
end


function prefix = sub_transcribe(py, here, audioFile, name, onset, frame, minNoteMs, redo)
% Run basic-pitch once per threshold set; the outputs are cached in transcriptions/.
prefix = fullfile(here, 'transcriptions', name);
if onset ~= 0.5 || frame ~= 0.3 || minNoteMs ~= 127.7
    prefix = sprintf('%s_on%g_fr%g_min%g', prefix, onset, frame, minNoteMs);
end
if redo || ~isfile([prefix '_notes.csv']) || ~isfile([prefix '_tempo.json'])
    if ~isfolder(fileparts(prefix)), mkdir(fileparts(prefix)); end
    cmd = sprintf('"%s" -I -W ignore "%s" "%s" "%s" --onset %g --frame %g --min-note-ms %g', ...
        py, fullfile(here, 'transcribe_basic_pitch.py'), audioFile, prefix, onset, frame, minNoteMs);
    fprintf('mp3ToTrk: transcribing %s (onset %g, frame %g) ...\n', audioFile, onset, frame);
    [status, out] = system(cmd);
    assert(status == 0, 'mp3ToTrk: basic-pitch failed:\n%s', out);
    lines = strsplit(strtrim(out), newline);
    fprintf('  %s\n', lines{end});
end
end
