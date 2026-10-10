#!/usr/bin/env python3
"""Build a playable sample library from raw recordings, in one command.

    python3 Tools/build_library.py Media/boxstomp/*.WAV --out BoxStomp --kit BoxStomp -k 2

This owns the audio: decoding, onset and loop detection, the FFT behind the timbre
features, and cutting the samples. Every *decision* -- how many articulations, which
hit belongs to which, how many velocity layers, what the notes are -- is made by
Tools/build_library.lua calling the mutation-tested libraries in Scripts/lib.

Three things here were each wrong once, and the comments say why they are as they are:
loop detection is by onset DENSITY not amplitude, every level measurement uses the
across-channel maximum not the mono sum, and gain is applied in two distinct stages.

Requires ffmpeg, ffprobe and numpy.
"""

import argparse
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ENVRATE = 400          # envelope buckets/s, matching Scripts/lib/envelope.lua
FFTSIZE, FFTBINS = 2048, 4096


def need(tool):
    if shutil.which(tool) is None:
        sys.exit("%s not found on PATH -- install it (brew install ffmpeg) and re-run" % tool)


def decode(path):
    """Decode once. Returns (mono, chanmax, samplerate).

    `mono` is the channel mean, used for onset detection and the timbre FFT.
    `chanmax` is the per-frame maximum across channels, and every LEVEL measurement
    must use it: the output samples are stereo, so a channel louder than the mean is
    what actually clips. Measuring gain off the mono sum let a loop reach -0.0 dBFS
    while the arithmetic claimed -1.0.
    """
    info = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                           "stream=sample_rate,channels", "-of", "csv=p=0", path],
                          capture_output=True, text=True).stdout.strip().split(",")
    rate, chans = int(info[0]), int(info[1])
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le",
                          "-acodec", "pcm_f32le", "-"], capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.float32)
    if chans > 1:
        x = x.reshape(-1, chans)
        return x.mean(axis=1).astype(np.float64), np.abs(x).max(axis=1).astype(np.float64), rate
    x = x.astype(np.float64)
    return x, np.abs(x), rate


def envelope(chanmax, rate):
    """Peak envelope from the across-channel maximum, as envelope.read_envelope does."""
    hop = max(1, rate // ENVRATE)
    n = len(chanmax) // hop
    return chanmax[:n * hop].reshape(n, hop).max(axis=1)


def onsets(env, thresh_db, min_interval):
    """Rising-edge onsets, threshold relative to this file's peak, with a refractory."""
    peak = env.max()
    if peak <= 0:
        return []
    th = peak * (10 ** (thresh_db / 20.0))
    out, last, above = [], -1e9, False
    for i, v in enumerate(env):
        if v > th:
            t = i / ENVRATE
            if not above and t - last > min_interval:
                out.append(t)
                last = t
            above = True
        else:
            above = False
    return out


def loop_spans(times, args, length):
    """Find continuous playing by ONSET DENSITY, not amplitude.

    A loop is a run of onsets that keep arriving; a one-hit is isolated. That is a
    property of timing, so it does not move when the recording level does -- which
    amplitude-based detection emphatically does. An absolute -40 dBFS floor found nine
    loops in a file containing none: on a +26 dBFS take the decay tails never drop
    below it, so "silence" never occurs and the file reads as one long span. Making the
    floor relative did not fix it either -- the number that isolates hits (-30 dB below
    peak) chops continuous playing into fragments, and one low enough to keep playing
    intact (-55 dB) swallows a quiet file whole. Density has no such knife edge: the
    measured median inter-onset interval is 0.12 s inside loops and 1.31 s between
    one-hits, an order of magnitude apart in the same session.

    Density decides, not duration. Duration alone called a 4.73 s run of 34 onsets a
    loop while a 3.79 s run of 27 onsets at the SAME 0.12 s spacing became 27
    "one-hits" -- an artifact of where the cutoff fell, not a real difference.
    """
    if not times:
        return []
    runs, cur = [], [times[0]]
    for prev, t in zip(times, times[1:]):
        if t - prev <= args.loop_gap:
            cur.append(t)
        else:
            runs.append(cur)
            cur = [t]
    runs.append(cur)
    spans = []
    for r in runs:
        if len(r) < args.loop_onsets or r[-1] - r[0] < args.min_loop:
            continue
        if float(np.median(np.diff(r))) <= args.loop_ioi:
            spans.append((max(0.0, r[0] - args.preroll), min(length, r[-1] + args.tail)))
    return spans


def spectrum(mono, chanmax, rate, t):
    """Timbre from the mono sum; level from the across-channel maximum."""
    a = int(t * rate)
    seg = mono[a:a + FFTSIZE]
    if len(seg) < FFTSIZE // 2:
        return None, None
    w = np.zeros(FFTSIZE)
    w[:len(seg)] = seg
    w *= np.hanning(FFTSIZE)
    mags = np.abs(np.fft.rfft(w, FFTBINS))
    return mags, 20 * np.log10(max(chanmax[a:a + FFTSIZE].max(), 1e-12))


def analyse(paths, args, work):
    """Detect loops and hits in every input, and write what the Lua half reads."""
    hits_f = open(os.path.join(work, "hits.tsv"), "w")
    loops_f = open(os.path.join(work, "loops.tsv"), "w")
    sources, nhits, nloops = {}, 0, 0
    for path in paths:
        mono, chanmax, rate = decode(path)
        env = envelope(chanmax, rate)
        name = os.path.basename(path)
        raw = onsets(env, args.threshold, args.min_interval)
        loops = loop_spans(raw, args, len(mono) / rate)
        hits = [t for t in raw if not any(a <= t <= b for a, b in loops)]

        peaks = {}
        for t in hits:
            mags, pk = spectrum(mono, chanmax, rate, t)
            if mags is not None:
                peaks[t] = (mags, pk)

        # Stage 1 of 2: per-source alignment. Each file's loudest contribution becomes
        # its reference, so a recorder gain change between takes cannot masquerade as
        # velocity. Boxstomp's two files sat 41.4 dB apart while each held an identical
        # 29.9 dB of real dynamics; cajon's sat 8.9 dB apart with ranges of 30.0 and
        # 29.6 dB. Both are gain changes, not performances. Loops count toward the
        # reference: a file that is nearly all grooves has too few hits to give a stable
        # one -- boxstomp file 1 has four, and aligning on those alone asked for +33 dB.
        loudest_raw = max((pk for _, pk in peaks.values()), default=-999.0)
        for a, b in loops:
            seg = chanmax[int(a * rate):int(b * rate)]
            if len(seg):
                loudest_raw = max(loudest_raw, 20 * np.log10(max(seg.max(), 1e-12)))
        align = -loudest_raw if loudest_raw > -999.0 else 0.0

        sources[name] = dict(path=path, align=align, hits=len(peaks), loops=len(loops),
                             peak=20 * np.log10(max(chanmax.max(), 1e-12)),
                             loudest=loudest_raw + align, rate=rate, dur=len(mono) / rate)
        for t, (mags, pk) in sorted(peaks.items()):
            hits_f.write("%s\t%.6f\t%.4f\t%.4f\t%s\n"
                         % (name, t, pk, pk + align, " ".join("%.6g" % v for v in mags)))
            nhits += 1
        for a, b in loops:
            inside = [t for t in raw if a <= t <= b]
            loops_f.write("%s\t%.6f\t%.6f\t%s\n"
                          % (name, a, b, " ".join("%.4f" % t for t in inside)))
            nloops += 1
        print("  %-26s %7.1f s  peak %+6.1f dBFS  %3d hits  %2d loops  align %+.1f dB"
              % (name, sources[name]["dur"], sources[name]["peak"],
                 sources[name]["hits"], len(loops), align))
    hits_f.close()
    loops_f.close()
    if nhits == 0:
        sys.exit("no hits detected -- try a lower --threshold")
    print("  total: %d hits, %d loop spans" % (nhits, nloops))
    return sources


def cut(work, out, sources, args):
    """Cut every sample the manifest asks for, at the final library gain."""
    rows = []
    for line in open(os.path.join(work, "manifest.tsv")):
        src, t, stop, name, kind = line.rstrip("\n").split("\t")
        rows.append((src, float(t), None if stop == "-" else float(stop), name, kind))

    starts = {}
    for line in open(os.path.join(work, "hits.tsv")):
        p = line.split("\t", 2)
        starts.setdefault(p[0], []).append(float(p[1]))
    for k in starts:
        starts[k].sort()

    # Stage 2 of 2: one library gain for the whole kit, on top of each source's
    # alignment, so the loudest sample -- hit or loop, from any source -- lands exactly
    # at --peak. Never per sample: that would erase the level relationships the velocity
    # layers exist to encode. Required, not cosmetic -- the sources are 32-bit float
    # peaking above 0 dBFS and a straight 24-bit conversion clips every loud hit.
    loudest = max(s["loudest"] for s in sources.values())
    library_gain = args.peak - loudest
    print("  library gain %+.2f dB (loudest aligned sample %+.2f dB -> %.1f dBFS)"
          % (library_gain, loudest, args.peak))

    samples = os.path.join(out, "Samples")
    if os.path.isdir(samples):
        shutil.rmtree(samples)
    os.makedirs(samples)

    cmds = []
    for src, t, stop, name, kind in rows:
        info = sources[src]
        if kind == "loop":
            a, b, fade_out = t, stop, 0.05
        else:
            later = [x for x in starts[src] if x > t + 1e-6]
            b = min(later[0] - 0.005 if later else 1e9, t + args.tail, info["dur"])
            a = max(0.0, t - args.preroll)
            fade_out = 0.02
        af = ("volume=%.4fdB,afade=t=in:st=0:d=0.005,afade=t=out:st=%.4f:d=%.3f"
              % (info["align"] + library_gain, max(0.0, (b - a) - fade_out), fade_out))
        cmds.append(["ffmpeg", "-v", "error", "-y", "-ss", "%.6f" % a, "-t", "%.6f" % (b - a),
                     "-i", info["path"], "-af", af, "-c:a", "pcm_s24le",
                     "-ar", str(args.rate), "-ac", "2",
                     os.path.join(samples, name + ".wav")])

    with ThreadPoolExecutor(args.jobs) as ex:
        codes = list(ex.map(lambda c: subprocess.run(c, capture_output=True).returncode, cmds))
    failed = sum(1 for c in codes if c)
    print("  cut %d samples, %d failed" % (len(codes), failed))
    if failed:
        sys.exit("ffmpeg failed on %d samples" % failed)
    return library_gain


def verify(out, kit):
    """The gate between 'the files exist' and 'this library is shareable'."""
    ok = True
    refs = set()
    for line in open(os.path.join(out, kit + ".sfz")):
        if "sample=" in line:
            refs.add(line.split("sample=")[1].split()[0])
    root = ET.parse(os.path.join(out, kit + ".dspreset")).getroot()
    for s in root.iter("sample"):
        refs.add(s.get("path"))

    missing = sorted(r for r in refs if not os.path.exists(os.path.join(out, r)))
    extra = sorted({"Samples/" + f for f in os.listdir(os.path.join(out, "Samples"))} - refs)
    print("  %d sample paths referenced, %d missing, %d unreferenced on disk"
          % (len(refs), len(missing), len(extra)))
    for m in missing[:10]:
        print("    MISSING %s" % m)
        ok = False
    for e in extra[:10]:
        print("    UNREFERENCED %s" % e)
        ok = False

    groups = list(root.iter("group"))
    holes = 0
    for g in groups:
        seen = set()
        for s in g.findall("sample"):
            seen.update(range(int(s.get("loVel")), int(s.get("hiVel")) + 1))
        if set(range(1, 128)) - seen:
            holes += 1
    print("  %d groups, %d with velocity holes" % (len(groups), holes))
    ok = ok and holes == 0

    hot = []
    for f in sorted(os.listdir(os.path.join(out, "Samples"))):
        err = subprocess.run(["ffmpeg", "-i", os.path.join(out, "Samples", f),
                              "-af", "volumedetect", "-f", "null", "-"],
                             capture_output=True, text=True).stderr
        for line in err.splitlines():
            if "max_volume" in line:
                v = float(line.split("max_volume:")[1].split()[0])
                if v >= 0.0:
                    hot.append((f, v))
    print("  %d samples at or above 0 dBFS" % len(hot))
    for f, v in hot[:10]:
        print("    CLIPPED %s at %+.1f dB" % (f, v))
    return ok and not hot


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="source WAV files")
    ap.add_argument("--out", required=True, help="library directory to write")
    ap.add_argument("--kit", help="kit name (default: basename of --out)")
    ap.add_argument("-k", type=int, default=4,
                    help="articulations; a musical convention, not a discovery (default 4)")
    ap.add_argument("--threshold", type=float, default=-30.0,
                    help="onset floor, dB below each file's peak (default -30)")
    ap.add_argument("--min-interval", type=float, default=0.08, help="refractory, s")
    ap.add_argument("--loop-gap", type=float, default=1.0,
                    help="onsets closer than this are the same continuous passage, s")
    ap.add_argument("--loop-onsets", type=int, default=8,
                    help="a loop needs at least this many onsets (default 8)")
    ap.add_argument("--loop-ioi", type=float, default=0.5,
                    help="median onset spacing at or below this is continuous playing, s")
    ap.add_argument("--min-loop", type=float, default=1.5,
                    help="shortest run worth keeping as a loop sample, s")
    ap.add_argument("--preroll", type=float, default=0.005)
    ap.add_argument("--tail", type=float, default=1.5)
    ap.add_argument("--peak", type=float, default=-1.0, help="loudest sample, dBFS")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    need("ffmpeg")
    need("ffprobe")
    kit = args.kit or os.path.basename(os.path.abspath(args.out))
    out = os.path.abspath(args.out)
    work = os.path.join(out, ".work")
    os.makedirs(work, exist_ok=True)

    print("analysing %d source file(s)" % len(args.inputs))
    sources = analyse(args.inputs, args, work)

    print("\ndeciding the matrix (Scripts/lib via Tools/build_library.lua)")
    if subprocess.run(["lua", os.path.join(HERE, "build_library.lua"),
                       work, out, kit, str(args.k)]).returncode:
        sys.exit("the decision step failed")

    print("\ncutting samples")
    gain = cut(work, out, sources, args)

    print("\nwriting the report")
    subprocess.run(["lua", os.path.join(HERE, "write_report.lua"), work, out, kit,
                    "%+.2f" % gain,
                    ", ".join("%s %+.1f dB" % (k, v["align"]) for k, v in sources.items())])

    print("\nverifying")
    if not verify(out, kit):
        sys.exit("verification FAILED -- this library is not shareable")
    print("\n%s is ready: %s" % (kit, out))


if __name__ == "__main__":
    main()
