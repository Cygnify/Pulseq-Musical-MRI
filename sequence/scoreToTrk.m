function [trkFile, rep] = scoreToTrk(scoreFile, varargin)
% scoreToTrk  Sheet music (MusicXML/.mxl/MIDI) -> tracker score (.trk) for writePianoTracker.
%   [trkFile, rep] = scoreToTrk(scoreFile, ...)
%   Up to 6 notes at a time (two per gradient axis), at the score's own tempo.
%
%   1. score_to_notes.py (music21, in .venv-basicpitch) reads the score at sounding
%      pitch (MusicXML stores sounding pitch under 8va/8vb lines), ties merged, repeats
%      expanded, grace notes skipped, arpeggiated chords as block chords; no dynamics.
%   2. notesToTrk with 'voices' 6 and 'keepAll': every note is kept while 6 or fewer
%      sound; the 'musical' picker decides only when more do. No overtone filter, pedal
%      model or sustain: a score's notes and lengths are exact.
%   Requires: setup_basic_pitch.sh, then music21 installed in .venv-basicpitch.
%
%   Inputs
%     scoreFile   char   .musicxml, .mxl, .xml, .mid, ... (anything music21 reads)
%
%   Options (others go to notesToTrk)
%     'out'           char  .trk to write (default <name>_score.trk next to this file)
%     'measures'      [2]   first and last measure (default: all)
%     'bpm'           [1]   tempo (default: the score's first tempo mark)
%     'voices'        [1]   6 (two per axis) or 3 (6)
%     'stepsPerBeat'  [1]   grid steps per quarter note (4 = 16th notes)
%     'sectionBeats'  [1]   beats per section = per segment (8: two 4/4 bars)

p = inputParser;
p.KeepUnmatched = true;
p.addParameter('out', '');
p.addParameter('measures', []);
p.addParameter('bpm', []);
p.addParameter('voices', 6);
p.addParameter('stepsPerBeat', 4);
p.addParameter('sectionBeats', 8);
p.parse(varargin{:});
o = p.Results;

here = fileparts(mfilename('fullpath'));
[~, name] = fileparts(scoreFile);
name = regexprep(name, '[^\w-]+', '_');
if isempty(o.out), o.out = fullfile(here, [name '_score.trk']); end
py = fullfile(here, '.venv-basicpitch', 'bin', 'python');
assert(isfile(py), 'scoreToTrk: no %s; run setup_basic_pitch.sh and install music21 there', py);
assert(isfile(scoreFile), 'scoreToTrk: no file %s', scoreFile);

%% 1. Read the score
prefix = fullfile(here, 'transcriptions', [name '_score']);
if ~isfolder(fileparts(prefix)), mkdir(fileparts(prefix)); end
cmd = sprintf('"%s" -I -W ignore "%s" "%s" "%s"', py, fullfile(here, 'score_to_notes.py'), scoreFile, prefix);
if ~isempty(o.bpm), cmd = sprintf('%s --bpm %g', cmd, o.bpm); end
[status, out] = system(cmd);
assert(status == 0, 'scoreToTrk: reading the score failed:\n%s', out);
lines = strsplit(strtrim(out), newline);
fprintf('scoreToTrk: %s\n', lines{end});
notes = readmatrix([prefix '_notes.csv']);
info = jsondecode(fileread([prefix '_score.json']));
if ~isempty(info.time_signature) && ~strcmp(info.time_signature, '4/4')
    warning('scoreToTrk:meter', 'time signature %s: sectionBeats %d may not match its bars', ...
        info.time_signature, o.sectionBeats);
end
if info.n_tempo_marks > 1
    warning('scoreToTrk:tempo', 'the score has %d tempo marks; all of it plays at %g bpm', info.n_tempo_marks, info.bpm);
end

%% 2. Measures -> time window
tStart = 0; tEnd = Inf;
if ~isempty(o.measures)
    num = info.measure_numbers(:); st = info.measure_starts_s(:);
    i1 = find(num == o.measures(1), 1); i2 = find(num == o.measures(2), 1);
    assert(~isempty(i1) && ~isempty(i2), 'scoreToTrk: measures %d-%d not in the score (%d-%d)', ...
        o.measures(1), o.measures(2), num(1), num(end));
    tStart = st(i1);
    if i2 < numel(st), tEnd = st(i2 + 1); else, tEnd = info.end_s; end
end

%% 3. Reduce
rx = ''; if info.repeats_expanded, rx = ', repeats expanded'; end
src = sprintf('%s (music21; %d grace notes skipped, %d 8va/8vb lines read at sounding pitch%s)', scoreFile, ...
    info.n_grace_skipped, info.n_ottava_lines, rx);
if ~isempty(o.measures), src = sprintf('%s, measures %d-%d', src, o.measures); end
args = [fieldnames(p.Unmatched) struct2cell(p.Unmatched)]';
[trkFile, rep] = notesToTrk(notes, o.out, 'bpm', info.bpm, 'gridOffset', 0, ...
    'tStart', tStart, 'tEnd', tEnd, 'voices', o.voices, 'picker', 'musical', 'keepAll', true, ...
    'dropHarmonics', false, 'pedal', false, 'holdSteps', 0, ...
    'stepsPerBeat', o.stepsPerBeat, 'sectionBeats', o.sectionBeats, 'source', src, args{:});
end
