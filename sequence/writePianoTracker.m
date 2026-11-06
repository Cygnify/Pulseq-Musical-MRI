% writePianoTracker  Play a tracker score (.trk) on the gradient coils: Pulseq .seq -> GE .pge.
%   Each note is a sine gradient waveform; each score column drives one gradient axis
%   (readTracker.m). The layout is shaped by the pge2 interpreter's limits.
%
%   Layout
%   - One score line = one block, exactly the line's duration. Each axis plays a whole or
%     half number of sine cycles per block, so it starts and ends at zero and a held note
%     runs on into the next block without a seam. Pitch is rounded to the nearest half
%     cycle per block; the writer prints the pitch error in cents.
%   - After an odd number of half cycles, that axis's next block plays inverted
%     (mr.scaleGrad by -1): same shape, so no extra waveform.
%   - One segment (TRID) per score section; a section played again reuses its segment.
%     The interpreter reserves waveform memory for every block position of every segment,
%     so memory ~ total length of the distinct sections / raster.
%   - Gradient raster 32 us by default (1/8 of the samples at GE's 4 us) to save memory.
%   - Rests are delay blocks (no waveform memory).
%   - Lead-in: one 1 deg RF + ADC block (its own segment), so the scan has a readout for
%     prescan: 120 ms, with a zero-amplitude x trapezoid and the ADC 500 us after the RF.
%     A gradient-free lead-in with the ADC right after the RF failed to download.
%   - No waveform longer than MAXSAMP samples (longer ones failed to download); a longer
%     line becomes back-to-back blocks of the same notes, held, so it sounds the same.
%   - Articulation: a struck note rises linearly over ATTACK and decays as exp(-t/TAU); a
%     held note ('.') keeps decaying across blocks. The decay within a block is part of the
%     waveform shape and the level a held note has reached is the block's amplitude scale,
%     so articulation adds few distinct waveforms. TAU = Inf gives constant notes.
%   - Two notes per axis (a+b in the score): the axis plays their sum, each note with its
%     own decay. Notes held on into the next block must share half-cycle parity (the sign
%     flip is per axis), which coarsens their tuning to whole cycles. Peak and slew limits
%     apply to the sum.
%
%   Loudness: every note starts at one amplitude A, sized so that the worst 20 s window of
%   the PET/MR gradient-heating model (checkGELimits) lands just under HEAT_TARGET. Each
%   note is also capped at 95% of slewMax (from the PET/MR's slew limit, used for both
%   scanners), and A at gradMax / notes per axis.
%
%   Options: environment variables (the script starts with clear, so use setenv)
%     PIANO_SCORE       .trk to play: a path, or a path relative to this folder
%     PIANO_SCANNER     'premier': only the Premier .pge, checked against an interpreter built
%                       with limits [128 1024 1024] and 95% of the Premier's 50 mT/m; the
%                       PET/MR heating estimate then only warns, as the scanner's own heating
%                       check at download is the one that counts. Unset: Premier and PET/MR
%                       .pge, stock limits [32 256 128], 95% of the PET/MR's 33 mT/m
%     PIANO_RASTER      gradient raster in us, a multiple of 4 (default 32)
%     PIANO_AMP         note-onset amplitude in mT/m; skips the heating sizing
%     PIANO_MAXSAMPLES  most samples per waveform (default 30000)
%     PIANO_MAXBLOCK    longest block in ms (default: no limit); the score's step grid is
%                       refined so that a step fits
%     PIANO_LEADIN      'old': 10 ms gradient-free lead-in with the ADC right after the RF
%                       (failed to download on the Premier); unset or other: the 120 ms lead-in
%     PIANO_SEGMENTS    'one': the whole scan is one segment (no TRID per section)
%     PIANO_OUTDIR      output folder (default: this folder)
%   Limits are [segments, blocks per segment, parent blocks] (interpreter tp_defs.h).
%
%   Outputs, named after the score: <score>.seq; <score>.pge/.mat (Premier);
%   <score>_petmr.pge/.mat (PET/MR); <score>_preview.wav, the summed gradient waveforms
%   at the raster, to check the arrangement by ear.
%
%   Requires: Pulseq 1.5.1, pulseg, pge2 (matlab/startup_pulseq.m, found by walking up),
%   geScannerOpts.m and checkGELimits.m (repo root), readTracker.m.
%
%   Example: the included score, with the settings used on the Premier
%     setenv('PIANO_SCORE', 'scores/moonlight1_6note_b1_24.trk');
%     setenv('PIANO_SCANNER', 'premier'); setenv('PIANO_RASTER', '48');
%     run writePianoTracker

clear; clc; close all

d = fileparts(mfilename('fullpath'));
while ~isfile(fullfile(d,'matlab','startup_pulseq.m')) && ~strcmp(d, fileparts(d))
    d = fileparts(d);
end
addpath(fullfile(d,'matlab')); startup_pulseq('quiet', true);
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));           % geScannerOpts, checkGELimits

SCORE       = getenv('PIANO_SCORE');   % .trk to play (see header)
if isempty(SCORE), SCORE = 'sweden.trk'; end
SCANNERS    = ["premier" "petmr"];
WRITE_PGE   = true;
DOVALIDATE  = true;
WRITE_WAV   = true;
RASTER      = 32e-6;                % gradient raster (s); PIANO_RASTER (us) overrides it
if ~isempty(getenv('PIANO_RASTER')), RASTER = str2double(getenv('PIANO_RASTER'))*1e-6; end
assert(abs(RASTER/4e-6 - round(RASTER/4e-6)) < 1e-9, 'RASTER must be a multiple of 4 us (GE)');
HEAT_TARGET = 95;                   % % of the PET/MR heating limit, worst 20 s window
kHeat       = 6.53e-4;              % PET/MR rule (as checkGELimits)
gradMax     = 0.95*33;              % mT/m: 95% of the PET/MR console's 3.3 G/cm
slewMax     = 0.95*119.565;         % T/m/s: 95% of the PET/MR console's 11.9565 G/cm/ms
LEADIN      = 10e-3;                % lead-in RF + ADC block (s)
TAU         = 2.0;                  % note decay time constant (s); Inf = constant notes
ATTACK      = 5e-3;                 % linear rise of a struck note (s)
pislquant   = 1;
opt.demoLeadin = ~strcmp(getenv('PIANO_LEADIN'), 'old');
if opt.demoLeadin, LEADIN = 120e-3; end
opt.oneSegment = strcmp(getenv('PIANO_SEGMENTS'), 'one');
MAXBLOCK    = Inf;                  % s; PIANO_MAXBLOCK (ms) overrides it
if ~isempty(getenv('PIANO_MAXBLOCK')), MAXBLOCK = str2double(getenv('PIANO_MAXBLOCK'))*1e-3; end
outDir      = getenv('PIANO_OUTDIR');
limits      = [32 256 128];         % interpreter limits (checkGELimits)
heatFail    = true;
if strcmp(getenv('PIANO_SCANNER'), 'premier')
    SCANNERS = "premier";
    gradMax  = 0.95*50;             % mT/m: 95% of geScannerOpts' Premier g_max
    limits   = [128 1024 1024];     % interpreter rebuilt with larger tp_defs.h limits
    heatFail = false;
end

sys = mr.opts('maxGrad', gradMax, 'GradUnit', 'mT/m', ...
    'maxSlew', slewMax, 'SlewUnit', 'T/m/s', 'B0', 3.0, ...
    'rfRingdownTime', 60e-6, 'rfDeadTime', 100e-6, 'adcDeadTime', 0, ...
    'rfRasterTime', 2e-6, 'adcRasterTime', 2e-6, ...
    'gradRasterTime', RASTER, 'blockDurationRaster', 4e-6);

[~, name] = fileparts(SCORE);
if ~isfile(SCORE), SCORE = fullfile(here, SCORE); end
trk = readTracker(SCORE);
if isempty(outDir), outDir = here; end
% No waveform longer than MAXSAMP samples: a 60000-sample waveform failed to download,
% while files with <= 30000 per waveform loaded. A longer line becomes back-to-back
% blocks of the same notes, held (not re-struck), so it sounds the same.
MAXSAMP = 30000;                   % PIANO_MAXSAMPLES overrides it
if ~isempty(getenv('PIANO_MAXSAMPLES')), MAXSAMP = str2double(getenv('PIANO_MAXSAMPLES')); end
maxBlock = min(MAXSAMP*RASTER, MAXBLOCK);
k = ceil(trk.step/maxBlock - 1e-9);  % refine the grid so one step fits in a block
if k > 1
    trk.step = trk.step/k; trk.stepsPerBeat = k*trk.stepsPerBeat;
    for s = 1:numel(trk.sections), trk.sections(s).steps = k*trk.sections(s).steps; end
end
trk = sub_splitlong(trk, floor(maxBlock/trk.step + 1e-9));
seqFile = fullfile(outDir, [name '.seq']);

%% Size the amplitude to the heating budget
% Heating goes as amplitude^2 until notes reach their slew cap, so this
% converges in a few rounds.
nPerAxis = 1 + any(arrayfun(@(S) any(~isnan(S.midi2(:))), trk.sections));   % notes on one axis add
Acap = gradMax*1e-3*sys.gamma/nPerAxis;      % Hz/m
A = 10e-3*sys.gamma;                % first guess
fixedA = getenv('PIANO_AMP');       % mT/m: use this note-onset amplitude, no sizing
if ~isempty(fixedA)                 % e.g. to try an excerpt at the full piece's level
    A = str2double(fixedA)*1e-3*sys.gamma;
    assert(A <= Acap, 'PIANO_AMP %s mT/m is above the cap %.2f mT/m', fixedA, Acap/sys.gamma*1e3);
end
for it = 1:5
    [seq, info] = sub_build(trk, sys, A, LEADIN, TAU, ATTACK, opt);
    seq.setDefinition('FOV', [0.5 0.5 3e-3]);
    seq.setDefinition('Name', name);
    seq.write(seqFile);
    psq = pulseg.fromSeq(seqFile);
    [~, R] = checkGELimits(psq, 'heatK', kHeat, 'verbose', false, 'limits', limits, 'heatFail', heatFail);
    fprintf('note onset %.2f mT/m -> PET/MR heating %.1f%%\n', A/sys.gamma*1e3, R.heatInterp);
    if ~isempty(fixedA), break; end
    Anew = min(A*sqrt((HEAT_TARGET - 0.25)/R.heatInterp), Acap);     % land just under the target
    inBand = R.heatInterp <= HEAT_TARGET && R.heatInterp > HEAT_TARGET - 0.5;
    if inBand || abs(Anew - A) < 1e-6*A || it == 5, break; end
    A = Anew;
end

[okTiming, report] = seq.checkTiming;
assert(okTiming, 'timing check failed:\n%s', [report{:}]);
fprintf('\nWrote %s\n', seqFile);
fprintf('  %d sections played (%d distinct), %.1f s, %d blocks\n', numel(trk.order), ...
    numel(unique(trk.order)), sum(seq.blockDurations), numel(seq.blockDurations));
fprintf('  note onset %.2f mT/m, decay %.1f s (%d notes slew-capped); pitch error median %.1f, worst %.1f cents\n', ...
    A/sys.gamma*1e3, TAU, info.nCapped, median(abs(info.cents)), max(abs(info.cents)));
checkGELimits(psq, 'heatK', kHeat, 'heatTarget', HEAT_TARGET, 'name', name, 'throw', true, ...
    'limits', limits, 'heatFail', heatFail);

%% Preview: the three axes summed, at the gradient raster
if WRITE_WAV
    y = cell2mat(info.wav);
    wavFile = fullfile(outDir, [name '_preview.wav']);
    audiowrite(wavFile, 0.9*y/max(abs(y)), round(1/RASTER));
    fprintf('Wrote %s\n', wavFile);
end

%% Convert to .pge, one per scanner (same design)
if WRITE_PGE
    for scanner = SCANNERS
        [sys_ge, PNSwt, sfx, zeroSlew] = geScannerOpts(scanner);
        params = pge2.check(psq, sys_ge, 'PNSwt', PNSwt);
        smaxActual = params.smax;
        if zeroSlew, params.smax = 0; end
        out = fullfile(outDir, [name sfx]);
        save(out, 'psq', 'params', 'pislquant', 'smaxActual');
        if DOVALIDATE
            % reading back re-extrapolates each shape's end point; with the decay it
            % lands ~0.01% off the stored 0, which Pulseq warns about once per block
            warning('off', 'mr:restoreShape');
            seqCheck = mr.Sequence(); seqCheck.read(seqFile);
            okv = pge2.validate(psq, sys_ge, seqCheck, [], 'row', [], 'plot', false);
            assert(okv, 'pge2.validate found waveform mismatches (%s)', scanner);
        end
        pge2.serialize(psq, [out '.pge'], 'pislquant', pislquant, 'params', params, 'checkHash', true);
        fprintf('Wrote %s.pge  (%s, PNSwt %s)\n', out, scanner, mat2str(PNSwt));
        fprintf('  nMax %d, %d segments, gmax %.3f G/cm, smax %.3f G/cm/ms (.pge header %.3f)\n', ...
            psq.nMax, psq.nSegments, params.gmax, smaxActual, params.smax);
    end
end


function [seq, info] = sub_build(trk, sys, A, leadin, tau, attack, opt)
% Lay the score out as blocks; A (Hz/m) is a struck note's amplitude, decaying
% with time constant tau (s) after a linear attack (s). opt.demoLeadin and
% opt.oneSegment: see PIANO_LEADIN and PIANO_SEGMENTS in the header.
% info.cents: pitch error of every note; info.nCapped: notes held to the slew
% cap; info.wav: summed axes per block (and the segment gaps), for the preview.
seq = mr.Sequence(sys);
R = sys.gradRasterTime;
nAx = numel(trk.axes);
gap = zeros(round(116e-6/R), 1);    % interpreter's gap between segments (12 + 4 + 100 us, pulseq.e)
if opt.oneSegment, gap = zeros(0, 1); end

% lead-in: 1 deg RF + ADC (see header); its own segment, TRID 1
rf = mr.makeSincPulse(pi/180, 'Duration', 1e-3, 'SliceThickness', 3e-3, 'apodization', 0.5, ...
    'timeBwProduct', 4, 'system', sys, 'use', 'other');
adc = mr.makeAdc(1000, 'Dwell', 2e-6, 'system', sys);
if opt.demoLeadin
    leadin = ceil(leadin/R - 1e-9)*R;   % the trapezoid needs whole raster steps
    adc.delay = rf.delay + rf.shape_dur + 500e-6;
    lead = {mr.makeTrapezoid('x', 'Duration', leadin, 'Amplitude', 0, 'system', sys)};
else
    adc.delay = mr.calcDuration(rf);
    lead = {mr.makeDelay(leadin)};
end
seq.addBlock(rf, adc, lead{:}, mr.makeLabel('SET', 'TRID', 1));
info.wav = {zeros(round(leadin/R), 1); gap};

cache = containers.Map();           % one unit-scale event per distinct axis waveform
info.cents = []; info.nCapped = 0;
trid = zeros(1, numel(trk.sections));
for s = trk.order
    if trid(s) == 0, trid(s) = max([1 trid]) + 1; end   % 2, 3, ... in order of first play
    S = trk.sections(s);
    assert(any(~isnan([S.midi(1, :) S.midi2(1, :)])), 'section [%s] starts with a rest', S.label);
    pol = ones(1, nAx);             % +1/-1: the axis plays inverted after a half cycle
    age = zeros(nAx, 2);            % time since each slot's note was struck (s)
    nEv = numel(S.steps);
    for e = 1:nEv
        N = round(S.steps(e)*trk.step/R);
        D = N*R;
        ev = {};
        y = zeros(N, 1);
        for a = 1:nAx
            notes = [S.midi(e, a) S.midi2(e, a)];
            held = [S.held(e, a) S.held2(e, a)];
            comps = find(~isnan(notes));
            if isempty(comps), pol(a) = 1; continue; end
            cont = false(1, 2);                 % slot held on into the next line
            if e < nEv, cont = [S.held(e+1, a) S.held2(e+1, a)]; end
            age(a, ~held & ~isnan(notes)) = 0;
            f = 440*2.^((notes - 69)/12);
            h = sub_halfcycles(f, D, comps, cont);
            fEff = h/(2*D);
            w = zeros(1, 2);
            for c = comps
                info.cents(end+1) = 1200*log2(fEff(c)/f(c));
                capc = 0.95*sys.maxSlew/(2*pi*fEff(c));
                info.nCapped = info.nCapped + (A > capc);
                w(c) = min(A, capc)*exp(-age(a, c)/tau);
            end
            sl = sum(2*pi*fEff(comps).*w(comps));          % the notes on an axis add
            if sl > 0.95*sys.maxSlew, w = w*0.95*sys.maxSlew/sl; end
            wmax = max(w(comps));
            key = sprintf('%s_%d', trk.axes{a}, N);
            for c = comps, key = [key sprintf('_%d:%d:%d:%.3f', c, h(c), ~held(c), w(c)/wmax)]; end %#ok<AGROW>
            if ~isKey(cache, key)
                t = ((1:N)' - 0.5)*R;
                wave = zeros(N, 1);
                for c = comps
                    env = exp(-t/tau);
                    if ~held(c), env = env.*min(1, t/attack); end
                    wave = wave + (w(c)/wmax)*env.*sin(2*pi*fEff(c)*t);
                end
                cache(key) = mr.makeArbitraryGrad(trk.axes{a}, wave, 'first', 0, 'last', 0, 'system', sys);
            end
            g = cache(key);
            ev{end+1} = mr.scaleGrad(g, pol(a)*wmax); %#ok<AGROW>
            y = y + pol(a)*wmax*g.waveform(:);
            cc = comps(cont(comps));                       % they share the parity of h
            if isempty(cc), cc = comps(1); end
            if mod(h(cc(1)), 2) == 1, pol(a) = -pol(a); end
            age(a, comps) = age(a, comps) + D;
        end
        if isempty(ev), ev = {mr.makeDelay(D)}; end
        if e == 1 && ~opt.oneSegment, ev{end+1} = mr.makeLabel('SET', 'TRID', trid(s)); end %#ok<AGROW>
        seq.addBlock(ev{:});
        info.wav{end+1, 1} = y;
    end
    info.wav{end+1, 1} = gap;
end
end


function h = sub_halfcycles(f, D, comps, cont)
% Half cycles per note in a block of D s: the nearest whole number each, except
% that notes held on into the next block must share parity, since the next
% block's sign (inverted after an odd count) applies to the whole axis.
h = zeros(1, 2);
for c = comps, h(c) = max(1, round(2*f(c)*D)); end
cc = comps(cont(comps));
if numel(cc) < 2, return; end
best = Inf;
for par = 0:1
    hh = h; err = 0;
    for c = cc
        x = 2*f(c)*D;
        k = 2*round((x - par)/2) + par;
        if k < 1, k = k + 2; end
        hh(c) = k; err = max(err, abs(log2(k/x)));
    end
    if err < best, best = err; hBest = hh; end
end
h = hBest;
end


function trk = sub_splitlong(trk, maxSteps)
% Cut every line longer than maxSteps into lines of at most maxSteps; the
% pieces after the first hold all their notes.
assert(maxSteps >= 1, 'MAXSAMP is shorter than one step');
for k = 1:numel(trk.sections)
    S = trk.sections(k); T = S;
    T.steps = zeros(0, 1); T.midi = zeros(0, size(S.midi, 2)); T.held = false(0, size(S.midi, 2));
    T.midi2 = T.midi; T.held2 = T.held;
    for e = 1:numel(S.steps)
        left = S.steps(e); first = true;
        while left > 0
            n = min(left, maxSteps); left = left - n;
            T.steps(end+1, 1) = n;
            T.midi(end+1, :) = S.midi(e, :); T.midi2(end+1, :) = S.midi2(e, :);
            if first
                T.held(end+1, :) = S.held(e, :); T.held2(end+1, :) = S.held2(e, :);
            else
                T.held(end+1, :) = ~isnan(S.midi(e, :)); T.held2(end+1, :) = ~isnan(S.midi2(e, :));
            end
            first = false;
        end
    end
    trk.sections(k) = T;
end
end
