function wavFile = previewTracker(trkFile, wavFile, varargin)
% previewTracker  Render a tracker score (.trk) as piano-like audio, to judge the notes by ear.
%   wavFile = previewTracker(trkFile, wavFile, ...)
%
%   Same notes, timing and struck/held ('.') as writePianoTracker, but each note gets a
%   few overtones so the bass is audible on small speakers, and there are no segment
%   gaps. This is NOT what the scanner plays; writePianoTracker's <score>_preview.wav is.
%
%   Options
%     'tau'    [1]  decay time constant (s), as writePianoTracker's TAU (2)
%     'harm'   [n]  overtone weights, fundamental first ([1 0.5 0.25 0.12])
%     'fs'     [1]  sample rate (44100)

p = inputParser;
p.addParameter('tau', 2);
p.addParameter('harm', [1 0.5 0.25 0.12]);
p.addParameter('fs', 44100);
p.parse(varargin{:});
o = p.Results;

trk = readTracker(trkFile);
nAx = numel(trk.axes);
out = {};
for s = trk.order
    S = trk.sections(s);
    slots = {S.midi, S.midi2}; holds = {S.held, S.held2};
    t0 = zeros(nAx, 2); ph = zeros(nAx, 2);
    for e = 1:numel(S.steps)
        N = round(S.steps(e)*trk.step*o.fs);
        t = (0:N-1)'/o.fs;
        blk = zeros(N, 1);
        for a = 1:nAx
            for c = 1:2                                      % up to two notes per axis
                m = slots{c}(e, a);
                if isnan(m), continue; end
                f = 440*2^((m - 69)/12);
                if ~holds{c}(e, a), t0(a, c) = 0; ph(a, c) = 0; end     % struck
                tt = t0(a, c) + t;
                env = min(1, tt/5e-3).*exp(-tt/o.tau);
                w = 0;
                for h = 1:numel(o.harm), w = w + o.harm(h)*sin(2*pi*h*f*t + h*ph(a, c)); end
                blk = blk + env.*w;
                t0(a, c) = t0(a, c) + N/o.fs; ph(a, c) = ph(a, c) + 2*pi*f*N/o.fs;
            end
        end
        out{end+1, 1} = blk; %#ok<AGROW>
    end
end
y = cell2mat(out);
audiowrite(wavFile, 0.9*y/max(abs(y)), o.fs);
end
