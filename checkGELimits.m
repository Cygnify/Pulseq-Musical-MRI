function [ok, R] = checkGELimits(psq, varargin)
% checkGELimits  Check a PulSeg object against the pge2 interpreter's limits.
%   [ok, R] = checkGELimits(psq, ...)
%
%   Hard limits are fixed-size arrays in the interpreter (tp_defs.h). Exceeding one fails
%   on the scanner, not in pge2.check. Stock values:
%     NMAXSEGMENTS 32, NMAXBLOCKSPERSEGMENT 256, NMAXPARENTBLOCKS 128
%
%   Also estimated here:
%   - Waveform memory. The interpreter (pgen.e makeArbitrary/makeTrap/makeExtTrap)
%     reserves hardware waveform memory for EVERY block position of every segment, so a
%     block repeated inside a segment costs its samples again; only replaying a segment
%     from the scan loop is free. The real budget is unknown; the largest file known to
%     play used 2,640,036 samples per axis, so more than that is a warning, not a failure.
%   - Distinct ADC parent blocks. The PET/MR prescan fails with 8 (one setfilter per ADC
%     parent block, pulseq.e predownload) and passes with 6.
%   - Gradient heating, as the interpreter computes it (safety.e/safety.c): every
%     instance of segment i costs t_cost(i), the minseq time of the instance PulSeg marked
%     as its max-energy one (psq.segments(i).Emax.n), summed over a 20 s window (10 s
%     stride, block durations only), over the first NMAXBLOCKSFORGRADHEATCHECK blocks the
%     .pge header allows. t_cost is modelled with the PET/MR rule t_cost = heatK/100 * E,
%     E the instance's sum of loop columns 7, 9 and 11 in 1e-9 T^2 s/m^2; heatK is an
%     empirical PET/MR calibration, and the Premier rule is uncalibrated. The same windows
%     are also summed with each instance's own energy (physical), which differs when
%     instance amplitudes vary.
%
%   Inputs
%     psq     struct | char   PulSeg object, or a .seq file (pulseg.fromSeq),
%                             or a .mat holding psq
%
%   Options
%     'wavBudget'    [1]      per-axis waveform samples known to play (2640036)
%     'heatK'        [1]      % s per 1e-9 T^2 s/m^2 (6.53e-4); [] skips heating
%     'heatTarget'   [1]      % at which heating warns (95)
%     'nMaxHeat'     [1]      pge2.serialize's NMAXBLOCKSFORGRADHEATCHECK (40000)
%     'limits'       [3]      NMAXSEGMENTS, NMAXBLOCKSPERSEGMENT, NMAXPARENTBLOCKS
%                             ([32 256 128]; e.g. [128 1024 1024] for an interpreter
%                             rebuilt with larger limits)
%     'heatFail'     logical  heating over 100% FAILs (true); false makes it a WARN, for
%                             a scanner whose own heating check is the one that counts
%                             (e.g. the Premier, where the PET/MR rule is uncalibrated)
%     'name'         char     label for the printout
%     'verbose'      logical  print the report (true)
%     'throw'        logical  error if any check FAILs (false)
%
%   Outputs
%     ok      logical   no check FAILed (WARNs allowed)
%     R       struct    every number, plus R.checks (name, value, limit, status)

p = inputParser;
p.addParameter('wavBudget', 2640036);         % largest per-axis count known to play
p.addParameter('heatK', 6.53e-4);
p.addParameter('heatTarget', 95);
p.addParameter('nMaxHeat', 40000);
p.addParameter('name', '');
p.addParameter('verbose', true);
p.addParameter('throw', false);
p.addParameter('limits', [32 256 128]);
p.addParameter('heatFail', true);
p.parse(varargin{:});
opt = p.Results;

if ischar(psq) || isstring(psq)
    fn = char(psq);
    if isempty(opt.name), [~, opt.name] = fileparts(fn); end
    if endsWith(fn, '.mat')
        S = load(fn, 'psq'); psq = S.psq;
    else
        psq = pulseg.fromSeq(fn);
    end
end

NMAXSEGMENTS = opt.limits(1); NMAXBLOCKSPERSEGMENT = opt.limits(2); NMAXPARENTBLOCKS = opt.limits(3);   % tp_defs.h
ADC_OK = 6; ADC_FAIL = 8;              % ADC parent blocks: PET/MR prescan passes / fails
GAMMA = 42.576e6;                      % Hz/T, as pge2.serialize
GRT = 4e-6;                            % interpreter gradient update time
TMINWAIT = 4e-6;                       % tp_defs.h, shortest delay block

R.name = opt.name;
R.nSegments = psq.nSegments;
R.nBlocksInSegment = [psq.segments.nBlocksInSegment];
[R.maxBlocksInSegment, R.worstSegment] = max(R.nBlocksInSegment);
R.nParentBlocks = psq.nParentBlocks;

%% Parent blocks: ADC count and waveform samples each one reserves
nAdc = 0;
pbSamples = zeros(psq.nParentBlocks, 4);   % x, y, z, rf (rho; theta is the same again)
ax = {'gx', 'gy', 'gz'};
for ip = 1:psq.nParentBlocks
    b = psq.parentBlocks(ip).block;
    if ~isempty(b.adc), nAdc = nAdc + 1; end
    for a = 1:3
        pbSamples(ip, a) = sub_gradsamples(b.(ax{a}), GRT);
    end
    if ~isempty(b.rf), pbSamples(ip, 4) = numel(b.rf.signal); end
end
R.nAdcParentBlocks = nAdc;

% every block position of every segment reserves its parent's samples
R.wavSamples = zeros(1, 4);
for i = 1:psq.nSegments
    ids = psq.segments(i).blockIDs;
    ids = ids(ids > 0);
    R.wavSamples = R.wavSamples + sum(pbSamples(ids, :), 1);
end
R.uniqueWavSamples = sum(pbSamples, 1);

%% Segment instances: start row, segment, duration, energy
starts = []; n = 1;
while n <= psq.nMax
    i = psq.loop(n, 1);
    if i < 1, n = n + 1; continue; end               % blocks before the first TRID
    starts(end+1) = n; %#ok<AGROW>
    n = n + psq.segments(i).nBlocksInSegment;
end
nInst = numel(starts);
seg = psq.loop(starts, 1).';
dur = zeros(1, nInst); E9 = zeros(1, nInst);
for k = 1:nInst
    i = seg(k); rows = starts(k) + (0:psq.segments(i).nBlocksInSegment-1);
    ids = psq.segments(i).blockIDs;
    bd = psq.loop(rows, 13).';
    bd(ids < 1) = max(bd(ids < 1), TMINWAIT);       % sw_getblockdur
    dur(k) = sum(bd);
    E9(k) = sum(sum(psq.loop(rows, [7 9 11])))/GAMMA^2/1e-9;
end
R.nInstances = nInst;
R.shortestInstance = min(dur);
R.duration = sum(dur);

%% Gradient heating
R.heatInterp = NaN; R.heatPhys = NaN; R.heatWindow = [NaN NaN];
R.heatCoveredTime = NaN;
if ~isempty(opt.heatK)
    E9max = zeros(1, psq.nSegments);                 % energy of each segment's Emax instance
    for i = 1:psq.nSegments                          % (0 for segments without gradients)
        n0 = psq.segments(i).Emax.n; nb = psq.segments(i).nBlocksInSegment;
        E9max(i) = sum(sum(psq.loop(n0:n0+nb-1, [7 9 11])))/GAMMA^2/1e-9;
    end
    costInterp = opt.heatK/100*E9max(seg);
    costPhys = opt.heatK/100*E9;

    % rows the interpreter checks: whole instances within nMaxHeat (pge2.serialize)
    nCover = 1;
    while nCover < min(psq.nMax, opt.nMaxHeat)
        nb = psq.segments(psq.loop(nCover, 1)).nBlocksInSegment;
        nCover = nCover + nb;
        if nCover > opt.nMaxHeat, nCover = nCover - nb; break; end
    end
    nCover = nCover - 1;
    covered = starts - 1 < nCover - 1;               % sw_getduration: n < nLast (0-based)
    R.heatCoveredTime = sum(dur(covered));

    [R.heatInterp, R.heatWindow] = sub_slidingwindow(dur(covered), costInterp(covered), starts(covered), psq);
    R.heatPhys = sub_slidingwindow(dur, costPhys, starts, psq);
end

%% Report
C = struct('name', {}, 'value', {}, 'limit', {}, 'status', {});
C(end+1) = sub_check('segments', R.nSegments, NMAXSEGMENTS, R.nSegments > NMAXSEGMENTS, false);
C(end+1) = sub_check(sprintf('blocks per segment (segment %d)', R.worstSegment), ...
    R.maxBlocksInSegment, NMAXBLOCKSPERSEGMENT, R.maxBlocksInSegment > NMAXBLOCKSPERSEGMENT, false);
C(end+1) = sub_check('parent blocks', R.nParentBlocks, NMAXPARENTBLOCKS, R.nParentBlocks > NMAXPARENTBLOCKS, false);
C(end+1) = sub_check('ADC parent blocks', R.nAdcParentBlocks, ADC_OK, nAdc >= ADC_FAIL, nAdc > ADC_OK);
axName = {'x', 'y', 'z'};
for a = 1:3
    C(end+1) = sub_check(sprintf('waveform samples %s (all positions)', axName{a}), ...
        R.wavSamples(a), opt.wavBudget, false, R.wavSamples(a) > opt.wavBudget); %#ok<AGROW>
end
if ~isempty(opt.heatK)
    C(end+1) = sub_check(sprintf('heating %%, interpreter (%.1f-%.1f s)', R.heatWindow), ...
        R.heatInterp, 100, opt.heatFail && R.heatInterp > 100, R.heatInterp > opt.heatTarget);
    C(end+1) = sub_check('heating %, physical energies', R.heatPhys, 100, opt.heatFail && R.heatPhys > 100, R.heatPhys > opt.heatTarget);
    C(end+1) = sub_check('heating check covers (s)', R.heatCoveredTime, R.duration, false, psq.nMax > opt.nMaxHeat);
end
R.checks = C;
ok = ~any(strcmp({C.status}, 'FAIL'));
R.ok = ok;

if opt.verbose
    fprintf('checkGELimits %s\n', R.name);
    for c = C
        if contains(c.name, 'samples')
            v = sprintf('%.3fM', c.value/1e6); l = sprintf('%.3fM', c.limit/1e6);
        elseif contains(c.name, 'heating')
            v = sprintf('%.1f', c.value); l = sprintf('%.1f', c.limit);
        else
            v = sprintf('%d', round(c.value)); l = sprintf('%d', round(c.limit));
        end
        fprintf('  %-42s %10s / %-10s %s\n', c.name, v, l, c.status);
    end
    fprintf('  rf samples (all positions) %.2fM; %d segment instances, shortest %.3f ms, %.1f s total\n', ...
        R.wavSamples(4)/1e6, R.nInstances, R.shortestInstance*1e3, R.duration);
    if ~isempty(opt.heatK)
        fprintf('  heating: PET/MR rule (heatK %.3g); the Premier rule is uncalibrated\n', opt.heatK);
    end
end
if opt.throw && ~ok
    error('checkGELimits: %s fails: %s', R.name, strjoin({C(strcmp({C.status}, 'FAIL')).name}, ', '));
end
end


function s = sub_gradsamples(g, grt)
% Waveform samples the interpreter reserves for one gradient event.
s = 0;
if isempty(g), return; end
if strcmp(g.type, 'trap')
    s = round(g.riseTime/grt) + round(g.fallTime/grt);       % makeTrap: two ramps
elseif g.tt(1) > 0
    s = numel(g.waveform);                                   % makeArbitrary: raster waveform
else
    w = g.waveform; d = diff(g.tt);                          % makeExtTrap: non-flat ramps
    s = sum(round(d(w(1:end-1) ~= w(2:end))/grt));
end
end

function c = sub_check(name, value, limit, fail, warn)
c.name = name; c.value = value; c.limit = limit;
if fail, c.status = 'FAIL'; elseif warn, c.status = 'WARN'; else, c.status = 'PASS'; end
end

function [pct, win] = sub_slidingwindow(dur, cost, starts, psq)
% safety.c sw_initialize / sw_advance / sw_gettimecost, on whole segment
% instances. Window 20 s (or the run, if shorter), stride 10 s. An instance
% counts toward the window's cost only if it starts before the window's last
% row (sw_gettimecost: n < nLast), as in the interpreter.
SW = 20; STRIDE = SW/2;
nInst = numel(dur);
pct = 0; win = [0 0];
if nInst == 0, return; end
lastRow = starts + arrayfun(@(k) psq.segments(psq.loop(starts(k), 1)).nBlocksInSegment, 1:nInst) - 1;
run = sum(dur);
first = 1; last = 0; d = 0; tFront = 0;
while last < nInst && d < min(SW, run)
    last = last + 1; d = d + dur(last); tFront = tFront + dur(last);
end
[pct, win] = sub_cost(first, last);
while tFront < run - d/2 && last < nInst
    while last < nInst && d < min(SW + STRIDE, run)
        last = last + 1; d = d + dur(last); tFront = tFront + dur(last);
    end
    while d > SW
        d = d - dur(first); first = first + 1;
    end
    [p2, w2] = sub_cost(first, last);
    if p2 > pct, pct = p2; win = w2; end
end

    function [p, w] = sub_cost(f, l)
        inWin = f:l;
        inWin = inWin(starts(inWin) - 1 < lastRow(l) - 1);
        p = sum(cost(inWin))/d*100;
        w = [tFront - d, tFront];
    end
end
