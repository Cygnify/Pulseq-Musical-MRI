function trk = readTracker(fn)
% readTracker  Read a tracker score (.trk) for writePianoTracker.
%   trk = readTracker(fn)
%
%   Format (example: scores/moonlight1_6note_b1_24.trk)
%     # comment                    at line start or after a space, to the end of the line
%     bpm <number>                 beats per minute
%     steps_per_beat <number>      a step is the duration unit of event lines
%     axes <x|y|z ...>             one note column per gradient axis, in this order
%     [label]                      starts a section (one segment on GE)
%     <steps> <tok> <tok> ...      one event: duration in steps, one token per axis
%                                    note  letter, optional # or b, octave (F#2, Bb3, C4)
%                                    .     everything on this axis on the line above,
%                                          held (not re-struck); writing a note again
%                                          re-strikes it
%                                    -     silent
%                                    a+b   two notes on the axis, slot 1 and slot 2;
%                                          each is a note, '.' (the note in that slot on
%                                          the line above, held) or '-' (empty):
%                                          E2+B2, .+D3, -+.
%     play <label> <label> ...     section order (default: file order)
%
%   Output
%     trk.bpm, trk.stepsPerBeat
%     trk.step       s per step
%     trk.axes       {'x','y','z'} (as listed)
%     trk.sections   (k).label, .steps [nEv x 1],
%                    .midi, .midi2 [nEv x nAx]  slot 1 and slot 2 notes (NaN = none)
%                    .held, .held2 [nEv x nAx]  true where that note is held
%     trk.order      [1 x nPlay] indices into trk.sections

txt = splitlines(fileread(fn));
trk = struct('bpm', [], 'stepsPerBeat', [], 'step', [], 'axes', {{}}, ...
    'sections', struct('label', {}, 'steps', {}, 'midi', {}, 'held', {}, 'midi2', {}, 'held2', {}), ...
    'order', []);
playLabels = {};
cur = 0;
for ln = 1:numel(txt)
    line = strtrim(regexprep(txt{ln}, '(^|\s)#.*$', ''));     % not the # of F#2
    if isempty(line), continue; end
    tok = strsplit(line);
    where = sprintf('%s:%d', fn, ln);
    switch lower(tok{1})
        case 'bpm'
            trk.bpm = str2double(tok{2});
        case 'steps_per_beat'
            trk.stepsPerBeat = str2double(tok{2});
        case 'axes'
            trk.axes = tok(2:end);
            assert(all(ismember(trk.axes, {'x','y','z'})) && numel(unique(trk.axes)) == numel(trk.axes), ...
                '%s: axes must be distinct x, y or z', where);
        case 'play'
            playLabels = tok(2:end);
        otherwise
            lab = regexp(line, '^\[(.+)\]$', 'tokens', 'once');
            if ~isempty(lab)
                assert(~any(strcmp({trk.sections.label}, lab{1})), '%s: section [%s] defined twice', where, lab{1});
                cur = numel(trk.sections) + 1;
                nAx = numel(trk.axes);
                trk.sections(cur).label = lab{1};
                trk.sections(cur).steps = zeros(0, 1);
                trk.sections(cur).midi = zeros(0, nAx);
                trk.sections(cur).held = false(0, nAx);
                trk.sections(cur).midi2 = zeros(0, nAx);
                trk.sections(cur).held2 = false(0, nAx);
                continue;
            end
            assert(cur > 0, '%s: event line before the first [section]', where);
            nAx = numel(trk.axes);
            assert(nAx > 0, '%s: "axes" must come before the first event', where);
            assert(numel(tok) == nAx + 1, '%s: expected a duration and %d notes, got "%s"', where, nAx, line);
            steps = str2double(tok{1});
            assert(isfinite(steps) && steps > 0, '%s: bad duration "%s"', where, tok{1});
            Sc = trk.sections(cur);
            first = isempty(Sc.midi);
            m = nan(2, nAx); held = false(2, nAx);                % rows: slot 1, slot 2
            for a = 1:nAx
                t = tok{a+1};
                if strcmp(t, '-'), continue; end
                if strcmp(t, '.')                                   % the whole axis, held
                    assert(~first, '%s: "." on the first line of a section', where);
                    m(:, a) = [Sc.midi(end, a); Sc.midi2(end, a)];
                    assert(any(~isnan(m(:, a))), '%s: "." under a silent axis', where);
                    held(:, a) = ~isnan(m(:, a));
                    continue;
                end
                sub = strsplit(t, '+');
                assert(numel(sub) <= 2, '%s: at most two notes per axis, got "%s"', where, t);
                for s = 1:numel(sub)
                    switch sub{s}
                        case '-'
                        case '.'
                            assert(~first, '%s: "." on the first line of a section', where);
                            prev = [Sc.midi(end, a) Sc.midi2(end, a)];
                            assert(~isnan(prev(s)), '%s: "." in slot %d of "%s" holds nothing', where, s, t);
                            m(s, a) = prev(s); held(s, a) = true;
                        otherwise
                            m(s, a) = sub_note2midi(sub{s}, where);
                    end
                end
            end
            trk.sections(cur).steps(end+1, 1) = steps;
            trk.sections(cur).midi(end+1, :) = m(1, :);
            trk.sections(cur).held(end+1, :) = held(1, :);
            trk.sections(cur).midi2(end+1, :) = m(2, :);
            trk.sections(cur).held2(end+1, :) = held(2, :);
    end
end

assert(~isempty(trk.bpm) && ~isempty(trk.stepsPerBeat), '%s: needs bpm and steps_per_beat', fn);
assert(~isempty(trk.sections), '%s: no sections', fn);
trk.step = 60/trk.bpm/trk.stepsPerBeat;
if isempty(playLabels)
    trk.order = 1:numel(trk.sections);
else
    [found, trk.order] = ismember(playLabels, {trk.sections.label});
    assert(all(found), '%s: play lists undefined section(s): %s', fn, strjoin(playLabels(~found), ' '));
end
end


function m = sub_note2midi(t, where)
% C4 = 60, A4 = 69
tk = regexp(t, '^([A-Ga-g])([#b]?)(-?\d+)$', 'tokens', 'once');
assert(~isempty(tk), '%s: bad note "%s"', where, t);
pc = containers.Map({'C','D','E','F','G','A','B'}, {0, 2, 4, 5, 7, 9, 11});
m = 12*(str2double(tk{3}) + 1) + pc(upper(tk{1})) + strcmp(tk{2}, '#') - strcmp(tk{2}, 'b');
end
