function [trkFile, rep] = notesToTrk(notes, trkFile, varargin)
% notesToTrk  Reduce a note list to a 3- or 6-voice tracker score (.trk) that fits the GE limits.
%   [trkFile, rep] = notesToTrk(notes, trkFile, ...)
%   Called by mp3ToTrk and scoreToTrk; the .trk is played by writePianoTracker.
%
%   Voices: 'voices' 3 (one note per axis) or 6 (two per axis, written a+b). Which
%   notes, where more sound than fit:
%     'simple'   the lowest (bass), the highest (melody) and the strongest others,
%                preferring notes already sounding
%     'musical'  a melody line tracked through the piece, the bass, and inner notes
%                by their role in the current chord (see sub_pickMusical)
%   Axes: a note that keeps sounding stays on its axis and slot (held '.', not
%   re-struck); otherwise by pitch order and register, and for 'musical' bass on x,
%   inner notes on y and melody on z.
%
%   Overtone ghosts: audio transcription sometimes reports a note's 2nd-6th harmonic
%   (12, 19, 24, 28, 31 semitones up) as a note of its own, which the 'highest note =
%   melody' rule would then pick. With 'dropHarmonics' (default), a note is dropped if
%   it starts within 80 ms of a note at one of those intervals below, is under 0.8 x
%   its amplitude and lasts 0.7-1.3 x as long. (In tests, ghosts were ~0.6 x the
%   amplitude and ~0.94 x the length; real octaves ~0.9 x and ~0.5 x.)
%
%   Quiet notes ('quiet', from mp3ToTrk's sensitive pass): a note of that pass is
%   added if no same-pitch note of the default pass overlaps it, it lasts 2+ steps,
%   its amplitude is 0.18+, and it is a chord tone (root, third, fifth, seventh or
%   ninth) of the best triad of the default notes sounding with it. Not
%   ghost-filtered: a real chord tone can match a harmonic of the bass in pitch.
%
%   Fitting: one segment per section of sectionBeats; identical sections are played
%   again for free. If the unique blocks exceed maxParentBlocks, the converter climbs
%   a ladder until they fit:
%     level 0  as transcribed
%     level 1  drop notes shorter than 2 steps
%     level 2  + inner voice only for notes of 4 steps or more
%     level 3  + drop notes shorter than 3 steps
%     level 4  + no inner voice
%     level 5  + drop notes shorter than 4 steps
%   Waveform memory (~ length of the distinct sections / raster) is not helped by
%   simplifying; if it is over budget the report gives the longest excerpt that fits.
%
%   Inputs
%     notes     [N x 4]  onset (s), offset (s), MIDI pitch, amplitude
%     trkFile   char     .trk to write (an existing file not written by notesToTrk
%                        is never overwritten)
%
%   Options
%     'bpm'             [1]   tempo (required)
%     'stepsPerBeat'    [1]   grid steps per beat (4)
%     'gridOffset'      [1]   a grid line, s after tStart, e.g. the first beat (0)
%     'tStart','tEnd'   [1]   excerpt (s) of the audio (0, Inf)
%     'sectionBeats'    [1]   beats per section = per segment (16)
%     'pitchRange'      [2]   MIDI range; notes outside move by octaves into it ([36 96])
%     'maxParentBlocks' [1]   127 (the stock interpreter's 128 minus the lead-in block)
%     'wavBudget'       [1]   per-axis waveform samples (2640036, as checkGELimits)
%     'raster'          [1]   writePianoTracker's gradient raster (32e-6)
%     'simplify'        logical  climb the ladder above (true)
%     'dropHarmonics'   logical  drop overtone ghosts, see above (true)
%     'holdSteps'       [1]   let a note ring on through silence on its axis for up
%                             to this many steps, like a sustain pedal (0 = off)
%     'voices'          [1]   3 or 6 (3)
%     'picker'          char  'simple' or 'musical' ('simple')
%     'quiet'           [M x 4]  notes of a more sensitive transcription (see above)
%     'keepAll'         logical  'musical' only: while no more notes sound than there
%                             are voices, keep them all, roles by pitch (lowest in
%                             the bass register = bass, highest = melody); pick only
%                             when more sound (false; scoreToTrk sets it: a score's
%                             notes are exact)
%     'pedal'           logical  notes above the bass register ring until the next
%                             bass-register onset (default: on for 'musical')
%     'source'          char  provenance for the header comment
%
%   Outputs
%     trkFile   the .trk written
%     rep       struct: level, counts, parent blocks, memory, longest excerpt that fits

p = inputParser;
p.addParameter('bpm', []);
p.addParameter('stepsPerBeat', 4);
p.addParameter('gridOffset', 0);
p.addParameter('tStart', 0);
p.addParameter('tEnd', Inf);
p.addParameter('sectionBeats', 16);
p.addParameter('pitchRange', [36 96]);
p.addParameter('maxParentBlocks', 127);
p.addParameter('wavBudget', 2640036);
p.addParameter('raster', 32e-6);
p.addParameter('simplify', true);
p.addParameter('dropHarmonics', true);
p.addParameter('holdSteps', 0);
p.addParameter('voices', 3);
p.addParameter('picker', 'simple');
p.addParameter('quiet', []);
p.addParameter('pedal', []);
p.addParameter('keepAll', false);
p.addParameter('source', '');
p.parse(varargin{:});
o = p.Results;
assert(~isempty(o.bpm), 'notesToTrk: bpm is required');
assert(ismember(o.voices, [3 6]), 'notesToTrk: voices must be 3 or 6');
assert(ismember(o.picker, {'simple', 'musical'}), 'notesToTrk: picker must be simple or musical');
if isempty(o.pedal), o.pedal = strcmp(o.picker, 'musical'); end
if isfile(trkFile)                     % never overwrite a hand-written score
    fid = fopen(trkFile); first = fgetl(fid); fclose(fid);
    assert(contains(first, 'written by notesToTrk'), ...
        'notesToTrk: %s exists and was not written by notesToTrk; choose another ''out''', trkFile);
end

step = 60/o.bpm/o.stepsPerBeat;
secSteps = o.sectionBeats*o.stepsPerBeat;
assert(secSteps <= 256, 'notesToTrk: a section must be <= 256 steps (blocks per segment)');

% excerpt, times relative to tStart
n = notes(notes(:,2) > o.tStart & notes(:,1) < o.tEnd, :);
n(:,1) = max(n(:,1), o.tStart) - o.tStart;
n(:,2) = min(n(:,2), o.tEnd) - o.tStart;
pr = o.pitchRange;
nFolded = sum(n(:,3) < pr(1) | n(:,3) > pr(2));
while any(n(:,3) < pr(1)), n(n(:,3) < pr(1), 3) = n(n(:,3) < pr(1), 3) + 12; end
while any(n(:,3) > pr(2)), n(n(:,3) > pr(2), 3) = n(n(:,3) > pr(2), 3) - 12; end
assert(~isempty(n), 'notesToTrk: no notes in the excerpt');
ghost = false(size(n, 1), 1);
if o.dropHarmonics
    for i = 1:size(n, 1)
        j = find(ismember(n(i,3) - n(:,3), [12 19 24 28 31]) & abs(n(:,1) - n(i,1)) <= 0.08 ...
            & n(i,4) < 0.8*n(:,4));
        r = (n(i,2) - n(i,1))./(n(j,2) - n(j,1));
        ghost(i) = any(r >= 0.7 & r <= 1.3);
    end
end
nGhost = sum(ghost);
n = n(~ghost, :);
nQuiet = 0;
if ~isempty(o.quiet)
    stp = 60/o.bpm/o.stepsPerBeat;
    q = o.quiet(o.quiet(:,2) > o.tStart & o.quiet(:,1) < o.tEnd, :);
    q(:,1) = max(q(:,1), o.tStart) - o.tStart;
    q(:,2) = min(q(:,2), o.tEnd) - o.tStart;
    while any(q(:,3) < pr(1)), q(q(:,3) < pr(1), 3) = q(q(:,3) < pr(1), 3) + 12; end
    while any(q(:,3) > pr(2)), q(q(:,3) > pr(2), 3) = q(q(:,3) > pr(2), 3) - 12; end
    keepQ = false(size(q, 1), 1);
    for i = 1:size(q, 1)
        if q(i,4) < 0.18 || q(i,2) - q(i,1) < 2*stp, continue; end
        if any(n(:,3) == q(i,3) & n(:,1) < q(i,2) & n(:,2) > q(i,1)), continue; end
        w = max(0, min(n(:,2), q(i,2)) - max(n(:,1), q(i,1))).*n(:,4);
        prof = accumarray(mod(n(:,3), 12) + 1, w, [12 1])';
        if sum(prof) == 0, continue; end
        [root, third] = sub_triad(prof, []);
        keepQ(i) = ismember(mod(q(i,3) - root, 12), [0 2 third 7 10 11]);
    end
    n = [n; q(keepQ, :)];
    nQuiet = sum(keepQ);
end

ladder = [1 1; 2 1; 2 4; 3 4; 3 Inf; 4 Inf];   % [shortest note, shortest inner note] in steps
if ~o.simplify, ladder = ladder(1, :); end
for lev = 1:size(ladder, 1)
    S = sub_reduce(n, step, o.gridOffset, ladder(lev, 1), ladder(lev, 2), secSteps, o.holdSteps, ...
        o.voices, o.picker, o.stepsPerBeat, o.pedal, o.keepAll);
    if S.nParent <= o.maxParentBlocks, break; end
end
rep.level = lev - 1;
rep.minNoteSteps = ladder(lev, 1);
rep.minInnerSteps = ladder(lev, 2);
rep.notesInExcerpt = size(n, 1);
rep.notesFolded = nFolded;
rep.notesGhost = nGhost;
rep.notesQuiet = nQuiet;
rep.notesPlayed = S.nPlayed;
rep.nSectionsPlayed = numel(S.play);
rep.nSectionsUnique = numel(S.sections);
rep.parentBlocks = S.nParent + 1;                       % + lead-in
rep.uniqueSeconds = S.uniqueSteps*step;
rep.samplesPerAxis = round(rep.uniqueSeconds/o.raster);
rep.duration = S.totalSteps*step;
rep.fits = rep.parentBlocks <= o.maxParentBlocks + 1 && rep.samplesPerAxis <= o.wavBudget ...
    && rep.nSectionsUnique + 1 <= 32;
% longest excerpt (from tStart) whose distinct sections fit the memory budget
budgetSteps = o.wavBudget*o.raster/step;
cum = cumsum(S.uniqueStepsBySection);
rep.maxExcerptSeconds = S.sectionEndStep(find(cum <= budgetSteps, 1, 'last'))*step;
if isempty(rep.maxExcerptSeconds), rep.maxExcerptSeconds = 0; end

sub_write(trkFile, S, o, rep, step);

fprintf('notesToTrk: %s\n', trkFile);
fprintf('  %d notes in the excerpt (%d overtone ghosts dropped, %d quiet chord tones added, %d moved by octaves into %s), %d on the gradients\n', ...
    rep.notesInExcerpt + rep.notesGhost - rep.notesQuiet, rep.notesGhost, rep.notesQuiet, rep.notesFolded, mat2str(pr), rep.notesPlayed);
fprintf('  simplification level %d; %.1f s, %d sections played (%d distinct)\n', ...
    rep.level, rep.duration, rep.nSectionsPlayed, rep.nSectionsUnique);
fprintf('  parent blocks %d / %d, waveform samples per axis %.2fM / %.2fM, segments %d / 32\n', ...
    rep.parentBlocks, o.maxParentBlocks + 1, rep.samplesPerAxis/1e6, o.wavBudget/1e6, rep.nSectionsUnique + 1);
if ~rep.fits
    warning('notesToTrk:limits', ['%s does not fit one scan. Longest excerpt from tStart whose ' ...
        'distinct sections fit the memory budget: %.0f s.'], trkFile, rep.maxExcerptSeconds);
end
end


function S = sub_reduce(n, step, gridOffset, minSteps, minInnerSteps, secSteps, holdSteps, nVoices, picker, beatSteps, pedal, keepAll)
% Quantize, pick voices, assign axes (nVoices/3 notes each), cut into sections.
cap = nVoices/3;
k0 = floor((min(n(:,1)) - gridOffset)/step + 0.5);
sOn  = round((n(:,1) - gridOffset)/step) - k0;
sOff = max(round((n(:,2) - gridOffset)/step) - k0, sOn + 1);
pit = n(:,3); amp = n(:,4);

% same pitch overlapping (also after octave folding): the later onset cuts the earlier
[~, ord] = sortrows([pit sOn]);
for k = 2:numel(ord)
    a = ord(k-1); b = ord(k);
    if pit(a) == pit(b) && sOn(b) < sOff(a)
        if sOn(b) > sOn(a), sOff(a) = sOn(b); else, sOff(b) = max(sOff(a), sOff(b)); sOff(a) = sOn(a); end
    end
end
keep = (sOff - sOn) >= minSteps;
sOn = sOn(keep); sOff = sOff(keep); pit = pit(keep); amp = amp(keep);
% pedal: the transcriber ends a note as it fades, but with the pedal down it rings
% on; notes above the bass register are held until the next bass-register onset
% (the bass itself is left as transcribed: extending it made the old bass note ring
% against the new one)
if pedal
    u = unique(pit(pit < median(pit)));
    if numel(u) >= 2, [~, g] = max(diff(u)); bc = u(g); else, bc = median(pit); end
    bOn = unique(sOn(pit <= bc));
    for j = find(pit > bc)'
        nx = bOn(find(bOn > sOn(j), 1));
        if ~isempty(nx), sOff(j) = max(sOff(j), nx); end
    end
    [~, ord] = sortrows([pit sOn]);                % a re-strike still ends the earlier note
    for k = 2:numel(ord)
        a = ord(k-1); bb = ord(k);
        if pit(a) == pit(bb) && sOn(bb) < sOff(a) && sOn(bb) > sOn(a), sOff(a) = sOn(bb); end
    end
end
len = sOff - sOn;
home = prctile(pit, [15 50 85]);                   % register of x, y, z

% segments between change points, and the notes sounding in each
b = unique([sOn; sOff]);
nSeg = numel(b) - 1;
act = arrayfun(@(i) find(sOn <= b(i) & sOff > b(i)), (1:nSeg)', 'UniformOutput', false);

% pick voices: chosen{i} note indices, role{i} 1 bass / 2 inner / 3 melody
if strcmp(picker, 'musical')
    [chosen, role] = sub_pickMusical(act, b, sOn, sOff, pit, amp, len, minInnerSteps, nVoices, beatSteps, keepAll);
    roleCost = 20; innerCost = 20*(cap == 1) + 2*(cap == 2);   % each role on its own axis
else
    [chosen, role] = sub_pickSimple(act, pit, amp, len, minInnerSteps, nVoices);
    roleCost = 0; innerCost = 0;
end

% axes and slots: asg(i, axis, slot) = note index (0 = empty)
asg = zeros(nSeg, 3, cap);
prevAx = zeros(numel(pit), 1); prevSlot = zeros(numel(pit), 1);
for i = 1:nSeg
    c = chosen{i};
    curAx = zeros(numel(pit), 1); curSlot = zeros(numel(pit), 1);
    if ~isempty(c)
        ax = sub_assign(c, role{i}, pit, prevAx, sOn(c) == b(i), home, cap, roleCost, innerCost);
        for a = 1:3
            on = c(ax == a);
            slots = zeros(1, cap);
            for j = on(:)'                           % a held note keeps its slot
                if prevAx(j) == a && slots(prevSlot(j)) == 0, slots(prevSlot(j)) = j; end
            end
            rest = on(~ismember(on, slots));
            [~, o2] = sort(pit(rest)); rest = rest(o2);
            free = find(slots == 0);
            slots(free(1:numel(rest))) = rest;
            asg(i, a, :) = slots;
            for q = find(slots), curAx(slots(q)) = a; curSlot(slots(q)) = q; end
        end
    end
    prevAx = curAx; prevSlot = curSlot;
end

% sustain: a note rings on through following silence in its slot, up to holdSteps
if holdSteps > 0
    for a = 1:3
        for q = 1:cap
            last = 0;
            for i = 1:nSeg
                if asg(i, a, q) ~= 0, last = asg(i, a, q); continue; end
                here = asg(i, :, :);
                if last ~= 0 && b(i+1) - sOff(last) <= holdSteps && ~any(here(:) == last)
                    asg(i, a, q) = last;
                else
                    last = 0;
                end
            end
        end
    end
end

% lines: merge consecutive segments with the same notes in every slot
dur = diff(b);
L = struct('start', {}, 'dur', {}, 'ids', {});
for i = 1:nSeg
    ids = reshape(asg(i, :, :), 3, cap);
    if ~isempty(L) && isequal(L(end).ids, ids) && L(end).start + L(end).dur == b(i)
        L(end).dur = L(end).dur + dur(i);
    else
        L(end+1) = struct('start', b(i), 'dur', dur(i), 'ids', ids); %#ok<AGROW>
    end
end
sounding = @(l) any(l.ids(:));
first = find(arrayfun(sounding, L), 1);
L = L(first:end);                                           % trim leading silence
origin = L(1).start;

% cut into sections of secSteps, splitting lines at the boundaries
secs = {}; cur = L([]);
for i = 1:numel(L)
    l = L(i);
    while true
        s0 = origin + secSteps*floor((l.start - origin)/secSteps);
        room = s0 + secSteps - l.start;
        if l.dur <= room, cur(end+1) = l; break; end %#ok<AGROW>
        h = l; h.dur = room; cur(end+1) = h; %#ok<AGROW>
        secs{end+1} = cur; cur = L([]); %#ok<AGROW>
        l.start = l.start + room; l.dur = l.dur - room;
    end
    if l.start + l.dur - origin == secSteps*ceil((l.start + l.dur - origin)/secSteps)
        secs{end+1} = cur; cur = L([]); %#ok<AGROW>
    end
end
if ~isempty(cur), secs{end+1} = cur; end
% a section may not start with a rest: move leading rests to the end of the previous one
for k = numel(secs):-1:2
    sk = secs{k};
    j = find(arrayfun(sounding, sk), 1);
    if isempty(j), secs{k-1} = [secs{k-1} sk]; secs(k) = []; continue; end
    if j > 1, secs{k-1} = [secs{k-1} sk(1:j-1)]; secs{k} = sk(j:end); end
end
% trailing rests of the last section are dropped
sk = secs{end}; j = find(arrayfun(sounding, sk), 1, 'last'); secs{end} = sk(1:j);
assert(all(cellfun(@numel, secs) <= 256), 'notesToTrk: a section has more than 256 lines');

% tokens per line; identical sections are played again
S.sections = {}; S.play = []; keys = {}; blockKeys = {};
S.uniqueStepsBySection = []; S.sectionEndStep = [];
played = false(size(pit));
for k = 1:numel(secs)
    sk = secs{k}; tok = cell(numel(sk), 4); bks = cell(numel(sk), 1);
    struckAt = zeros(3, cap);                      % step each slot's note was struck
    for j = 1:numel(sk)
        tok{j, 1} = sk(j).dur;
        bk = sprintf('%d', sk(j).dur);
        for a = 1:3
            ids = sk(j).ids(a, :);
            prevIds = zeros(1, cap); if j > 1, prevIds = sk(j-1).ids(a, :); end
            for q = 1:cap
                if ids(q) ~= 0 && ids(q) ~= prevIds(q), struckAt(a, q) = sk(j).start; played(ids(q)) = true; end
            end
            if ~any(ids)
                tok{j, a+1} = '-';
            elseif j > 1 && isequal(ids, prevIds)
                tok{j, a+1} = '.';
            else
                sub = cell(1, cap);
                for q = 1:cap
                    if ids(q) == 0, sub{q} = '-';
                    elseif ids(q) == prevIds(q), sub{q} = '.';
                    else, sub{q} = sub_name(pit(ids(q)));
                    end
                end
                if cap == 2 && strcmp(sub{2}, '-'), sub = sub(1); end
                tok{j, a+1} = strjoin(sub, '+');
            end
            % unique blocks: duration, pitch and struck/held per slot, and for two
            % notes on an axis their strike-time difference (it sets their level ratio)
            for q = 1:cap
                if ids(q) == 0, bk = [bk ' -']; %#ok<AGROW>
                else, bk = sprintf('%s %d%s', bk, pit(ids(q)), char('s' + (ids(q) == prevIds(q))*('h' - 's'))); %#ok<AGROW>
                end
            end
            if cap == 2 && all(ids), bk = sprintf('%s d%d', bk, struckAt(a, 1) - struckAt(a, 2)); end
        end
        bks{j} = bk;
    end
    key = strjoin(cellfun(@sub_str, tok(:)', 'UniformOutput', false), ' ');
    u = find(strcmp(keys, key), 1);
    if isempty(u)
        keys{end+1} = key; S.sections{end+1} = tok; u = numel(keys); %#ok<AGROW>
        S.uniqueStepsBySection(end+1) = sum([sk.dur]);
        blockKeys = [blockKeys; bks]; %#ok<AGROW>
    else
        S.uniqueStepsBySection(end+1) = 0;
    end
    S.play(end+1) = u;
    S.sectionEndStep(end+1) = sk(end).start + sk(end).dur - origin;
end
S.nParent = numel(unique(blockKeys));
S.uniqueSteps = sum(S.uniqueStepsBySection);
S.totalSteps = S.sectionEndStep(end);
S.nPlayed = sum(played);
end


function [chosen, role] = sub_pickSimple(act, pit, amp, len, minInnerSteps, nVoices)
% Lowest (bass) and highest (melody), then the strongest other notes, preferring
% ones already playing.
nSeg = numel(act);
chosen = cell(nSeg, 1); role = cell(nSeg, 1);
prev = [];
for i = 1:nSeg
    a = act{i};
    if isempty(a), prev = []; continue; end
    [~, lo] = min(pit(a)); [~, hi] = max(pit(a));
    ch = unique([a(lo) a(hi)], 'stable'); rl = [1 3]; rl = rl(1:numel(ch));
    rest = setdiff(a, ch);
    rest = rest(len(rest) >= minInnerSteps);
    while numel(ch) < nVoices && ~isempty(rest)
        pool = rest(ismember(rest, prev));
        if isempty(pool), pool = rest; end
        [~, j] = max(amp(pool));
        ch(end+1) = pool(j); rl(end+1) = 2; %#ok<AGROW>
        rest(rest == pool(j)) = [];
    end
    chosen{i} = ch; role{i} = rl; prev = ch;
end
end


function [chosen, role] = sub_pickMusical(act, b, sOn, sOff, pit, amp, len, minInnerSteps, nVoices, beatSteps, keepAll)
% Voices by musical role:
%  melody  one line through the piece (Viterbi) among notes at least an octave
%          above the lowest one sounding: loud, high in the chord, newly struck
%          notes score; staying on a note scores, jumps cost per semitone plus
%          extra for leaps of 10+ and for exact octaves; resting costs nothing,
%          so the melody does not jump to a chord tone an octave away to avoid a rest
%  bass    the most recently struck note within a fifth of the lowest sounding
%          one (with the pedal down the old bass note still rings when the new
%          one is struck; the new one is the bass), and only in the piece's bass
%          register: up to the pitch below the widest gap between the piece's
%          pitches under their median; if none, no bass
%  inner   at most nVoices - 2 (a slot each is kept for bass and melody, even when
%          they rest); above the bass register and below the melody; not an older
%          bass-register note still ringing (pedal blur, which as pure sines just
%          beats against the new bass); then by role in the chord heard over the
%          last beat (best major/minor triad of the amplitude-weighted pitch
%          classes): third > seventh > fifth > ninth > root; no doubling of a pitch
%          class already picked; a note already playing as inner is preferred, and
%          one near the previous inner note (0.12 per semitone, +2 for a leap of
%          10+, +1 for an octave)
%  axes    each role keeps its own axis: bass x, inner y, melody z (cost 20 off
%          it, more than the 10 for moving a held note); a role with nothing to
%          play leaves its axis silent (or sustained, with holdSteps)
nSeg = numel(act);
ampRef = median(amp);
cand = cell(nSeg, 1); em = cell(nSeg, 1);
for i = 1:nSeg
    a = act{i};
    if ~isempty(a), a = a(pit(a) >= min(pit(a)) + 12); end    % above the bass register
    cand{i} = [0; a(:)];                                       % 0 = no melody here
    e = zeros(numel(cand{i}), 1);
    if ~isempty(act{i})
        lo = min(pit(act{i})); hi = max(pit(act{i}));
        e(1) = 0;                                          % the melody may rest
        for k = 2:numel(cand{i})
            j = cand{i}(k);
            e(k) = amp(j)/ampRef + 0.8*(pit(j) - lo)/max(hi - lo, 1) + 0.3*(sOn(j) == b(i));
        end
    end
    em{i} = e;
end
score = em{1}; back = cell(nSeg, 1);
for i = 2:nSeg
    cp = cand{i-1}; cc = cand{i};
    T = zeros(numel(cp), numel(cc));
    for u = 1:numel(cp)
        for v = 1:numel(cc)
            if cp(u) == 0 && cc(v) == 0, T(u, v) = 0;
            elseif cp(u) == 0 || cc(v) == 0, T(u, v) = -0.2;
            elseif cp(u) == cc(v), T(u, v) = 1;
            else
                d = abs(pit(cp(u)) - pit(cc(v)));
                T(u, v) = -0.08*d - 0.6*(d >= 10) - 0.6*(d > 0 && mod(d, 12) == 0);
            end
        end
    end
    [best, arg] = max(score(:) + T, [], 1);
    score = best(:) + em{i}; back{i} = arg(:);
end
mel = zeros(nSeg, 1);
[~, k] = max(score);
for i = nSeg:-1:1
    mel(i) = cand{i}(k);
    if i > 1, k = back{i}(k); end
end

% the piece's bass register: below the widest gap in the pitches under the median
u = unique(pit(pit < median(pit)));
if numel(u) >= 2, [~, g] = max(diff(u)); bassCeil = u(g); else, bassCeil = median(pit); end

% interval above the chord root -> inner-voice priority
rolePri = containers.Map({3, 4, 10, 11, 7, 2, 0}, {3, 3, 2.5, 2.5, 1.5, 1.2, 0.5});
chosen = cell(nSeg, 1); role = cell(nSeg, 1);
prevInner = []; lastInnerPit = NaN; lastMelPit = NaN;
for i = 1:nSeg
    a = act{i};
    if isempty(a), prevInner = []; lastMelPit = NaN; continue; end
    if keepAll && numel(a) <= nVoices                % everything fits: keep it all
        [~, o2] = sort(pit(a)); ch = a(o2)'; rl = 2*ones(1, numel(ch));
        if pit(ch(1)) <= bassCeil, rl(1) = 1; end
        if numel(ch) >= 2 || rl(1) ~= 1, rl(end) = 3; end
        chosen{i} = ch; role{i} = rl; prevInner = ch(rl == 2);
        if ~isempty(prevInner), lastInnerPit = pit(prevInner(1)); end
        lastMelPit = NaN; if any(rl == 3), lastMelPit = pit(ch(rl == 3)); end
        continue;
    end
    ch = []; rl = [];
    if mel(i) > 0
        % next chord tone up: of the notes struck with the melody note (within a
        % step), higher, 2+ steps long and not its octave, the closest is the
        % melody instead: the Viterbi line can settle on a lower tone of the chord
        q = cand{i}(2:end);
        q = q(abs(sOn(q) - sOn(mel(i))) <= 1 & pit(q) > pit(mel(i)) & len(q) >= 2 ...
            & mod(pit(q) - pit(mel(i)), 12) ~= 0);
        if ~isempty(q), [~, t] = min(pit(q)); mel(i) = q(t); end
        % the melody note struck again (while a lower line continues) stays the
        % melody: the override above is not part of the Viterbi line
        if pit(mel(i)) < lastMelPit
            q = cand{i}(2:end); q = q(pit(q) == lastMelPit & sOn(q) == b(i));
            if ~isempty(q), mel(i) = q(1); end
        end
        ch = mel(i); rl = 3; lastMelPit = pit(mel(i));
    end
    rest = setdiff(a, ch);
    if ~isempty(rest)
        low = rest(pit(rest) <= min(pit(a)) + 7 & pit(rest) <= bassCeil);   % the bass register
        if ~isempty(low)
            [~, k] = sortrows([-sOn(low) pit(low)]);             % latest onset, then lowest
            k = find(rest == low(k(1)));
            ch(end+1) = rest(k); rl(end+1) = 1; rest(k) = []; %#ok<AGROW>
        end
    end
    rest = rest(len(rest) >= minInnerSteps);
    jb = ch(rl == 1); jm = ch(rl == 3);
    if ~isempty(jb)
        rest = rest(pit(rest) > pit(jb) & ~(pit(rest) <= pit(jb) + 7 & sOn(rest) < sOn(jb)));
    end
    rest = rest(pit(rest) > bassCeil);                       % above the bass register
    if ~isempty(jm), rest = rest(pit(rest) < pit(jm)); end   % below the melody
    if ~isempty(rest) && nVoices > 2
        w0 = b(i) - beatSteps; w1 = b(i+1);
        inWin = find(sOn < w1 & sOff > w0);
        prof = zeros(1, 12);
        for j = inWin(:)'
            pc = mod(pit(j), 12) + 1;
            prof(pc) = prof(pc) + amp(j)*(min(sOff(j), w1) - max(sOn(j), w0));
        end
        root = sub_triad(prof, mod(pit(ch(rl == 1)), 12));
        while sum(rl == 2) < nVoices - 2 && ~isempty(rest)
            sc = zeros(size(rest));
            for q = 1:numel(rest)
                iv = mod(pit(rest(q)) - root, 12);
                pri = 0; if isKey(rolePri, iv), pri = rolePri(iv); end
                sc(q) = pri + 1.5*ismember(rest(q), prevInner) + 0.5*amp(rest(q))/ampRef ...
                    - 1.0*any(mod(pit(ch), 12) == mod(pit(rest(q)), 12));
                if ~isnan(lastInnerPit)
                    d = abs(pit(rest(q)) - lastInnerPit);
                    sc(q) = sc(q) - 0.12*d - 2*(d >= 10) - 1*(d > 0 && mod(d, 12) == 0);
                end
            end
            [~, k] = max(sc);
            ch(end+1) = rest(k); rl(end+1) = 2; rest(k) = []; %#ok<AGROW>
        end
    end
    chosen{i} = ch; role{i} = rl; prevInner = ch(rl == 2);
    if ~isempty(prevInner), lastInnerPit = pit(prevInner(1)); end
end
end


function ax = sub_assign(c, r, pit, prevAx, onNow, home, cap, roleCost, innerCost)
% Axis for each chosen note, at most cap per axis, by least cost: a note that
% was playing on another axis +10 (it would be re-struck); +1 per pair out of
% pitch order across axes; register |pitch - home|/24; bass off x or melody off z
% +roleCost, inner off y +innerCost; two notes on one axis where one is held and
% one new +2.
kc = numel(c);
idx = (0:3^kc-1)';
C = zeros(3^kc, kc);
for q = 1:kc, C(:, q) = mod(floor(idx/3^(kc-q)), 3) + 1; end
C = C(all([sum(C == 1, 2) sum(C == 2, 2) sum(C == 3, 2)] <= cap, 2), :);
best = Inf; ax = C(1, :);
for row = 1:size(C, 1)
    x = C(row, :); cost = 0;
    for q = 1:kc
        if prevAx(c(q)) > 0 && prevAx(c(q)) ~= x(q), cost = cost + 10; end
        cost = cost + abs(pit(c(q)) - home(x(q)))/24;
        if (r(q) == 1 && x(q) ~= 1) || (r(q) == 3 && x(q) ~= 3), cost = cost + roleCost; end
        if r(q) == 2 && x(q) ~= 2, cost = cost + innerCost; end
        for q2 = 1:kc
            if x(q) < x(q2) && pit(c(q)) > pit(c(q2)), cost = cost + 1; end
            if q2 > q && x(q) == x(q2) && onNow(q) ~= onNow(q2), cost = cost + 2; end
        end
    end
    if cost < best, best = cost; ax = x; end
end
end


function sub_write(fn, S, o, rep, step)
% Write the .trk: provenance header (# lines), bpm, steps, axes, sections, play order.
f = fopen(fn, 'w');
cleanup = onCleanup(@() fclose(f));
[~, name] = fileparts(fn);
fprintf(f, '# %s.trk - written by notesToTrk.m, %s\n', name, char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm')));
if ~isempty(o.source), fprintf(f, '# source: %s\n', o.source); end
fprintf(f, '# excerpt from %.2f s, %.1f s long; grid %.2f bpm x %d steps/beat (step %.1f ms), grid offset %.3f s\n', ...
    o.tStart, rep.duration, o.bpm, o.stepsPerBeat, step*1e3, o.gridOffset);
fprintf(f, '# voices: %d, %s picker; hold through silence %d steps; simplification level %d (shortest note %d, shortest inner note %g steps)\n', ...
    o.voices, o.picker, o.holdSteps, rep.level, rep.minNoteSteps, rep.minInnerSteps);
fprintf(f, '# %d notes in the excerpt (%d overtone ghosts dropped, %d quiet chord tones added), %d on the gradients; %d parent blocks, %.2fM samples/axis\n', ...
    rep.notesInExcerpt + rep.notesGhost - rep.notesQuiet, rep.notesGhost, rep.notesQuiet, rep.notesPlayed, rep.parentBlocks, rep.samplesPerAxis/1e6);
fprintf(f, '# Line: <steps> <x> <y> <z>; . = held, - = silent, a+b = two notes (see readTracker.m)\n\n');
fprintf(f, 'bpm %.4g\nsteps_per_beat %d\naxes x y z\n\n', o.bpm, o.stepsPerBeat);
wcol = 4 + 4*(o.voices == 6);
for k = 1:numel(S.sections)
    tok = S.sections{k};
    fprintf(f, '[%d]\n', k);
    for j = 1:size(tok, 1)
        fprintf(f, sprintf('%%-3d %%-%ds %%-%ds %%s\n', wcol, wcol), tok{j, 1}, tok{j, 2}, tok{j, 3}, tok{j, 4});
    end
    fprintf(f, '\n');
end
fprintf(f, 'play %s\n', strjoin(arrayfun(@num2str, S.play, 'UniformOutput', false), ' '));
end


function s = sub_name(m)
% MIDI number -> note name (60 = C4)
names = {'C','C#','D','D#','E','F','F#','G','G#','A','A#','B'};
s = sprintf('%s%d', names{mod(m, 12) + 1}, floor(m/12) - 1);
end

function s = sub_str(x)
if ischar(x), s = x; else, s = sprintf('%d', x); end
end


function [root, third] = sub_triad(prof, bassPc)
% Best major/minor triad for a 12-bin pitch-class profile: in-chord weight minus
% 0.6 x out-of-chord weight, plus 0.3 x the peak if the root is the bass.
bestSc = -Inf; root = 0; third = 4;
for r = 0:11
    for th = [4 3]
        in = mod(r + [0 th 7], 12) + 1;
        sc = sum(prof(in)) - 0.6*(sum(prof) - sum(prof(in))) + 0.3*max(prof)*any(bassPc == r);
        if sc > bestSc, bestSc = sc; root = r; third = th; end
    end
end
end
