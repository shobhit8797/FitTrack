// Demo-video post-processing helper (used by ios/record_demo.sh).
//
// A tiny, dependency-free (AVFoundation/AppKit) media tool so the demo pipeline
// needs no ffmpeg. Run with the Swift interpreter: `swift demo_media.swift <cmd>`.
//
// Commands:
//   detect <in.mp4>                       → prints "START END" (seconds of real
//                                            app content, home-screen dead time
//                                            at both ends stripped)
//   trim   <in> <out> <start> <end> [preset]
//                                          → export [start,end]; default preset
//                                            is lossless passthrough, or pass an
//                                            AVAssetExportPreset name to re-encode
//                                            (e.g. AVAssetExportPreset1280x720)
//   frames <in> <outdir> <t1,t2,...>       → full-res PNG at each timestamp
//   dwells <in> <outdir> [maxShots]        → auto full-res PNGs of the screens the
//                                            walkthrough pauses on (distinct stills)

import AVFoundation
import AppKit
import CoreGraphics

func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: demo_media <detect|trim|frames|dwells> ...") }

func asset(_ p: String) -> AVURLAsset { AVURLAsset(url: URL(fileURLWithPath: p)) }
func seconds(_ a: AVURLAsset) -> Double { CMTimeGetSeconds(a.duration) }

func generator(_ a: AVURLAsset, small: Bool) -> AVAssetImageGenerator {
    let g = AVAssetImageGenerator(asset: a)
    g.appliesPreferredTrackTransform = true
    g.requestedTimeToleranceBefore = .zero
    g.requestedTimeToleranceAfter = .zero
    if small { g.maximumSize = CGSize(width: 24, height: 52) }
    return g
}

func image(_ g: AVAssetImageGenerator, _ t: Double) -> CGImage? {
    try? g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
}

/// Downscaled grayscale vector for cheap frame comparison.
func gray(_ cg: CGImage) -> [Double] {
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf.map { Double($0) / 255.0 }
}

func diff(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    var s = 0.0
    for i in a.indices { s += abs(a[i] - b[i]) }
    return s / Double(a.count)
}

/// Spatial variance — near-zero for a blank launch/splash frame, higher for a
/// textured app screen. Lets bounds detection skip the white launch flash.
func variance(_ s: [Double]) -> Double {
    guard !s.isEmpty else { return 0 }
    let m = s.reduce(0, +) / Double(s.count)
    return s.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(s.count)
}

func sampleAll(_ a: AVURLAsset, step: Double) -> [(t: Double, s: [Double])] {
    let g = generator(a, small: true)
    let dur = seconds(a)
    var out: [(Double, [Double])] = []
    var t = 0.0
    while t < dur {
        if let cg = image(g, t) { out.append((t, gray(cg))) }
        t += step
    }
    return out
}

func savePNG(_ cg: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

func frames(_ inp: String, _ dir: String, _ times: [Double]) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let g = generator(asset(inp), small: false)
    for (i, t) in times.enumerated() where t >= 0 {
        if let cg = image(g, t) {
            savePNG(cg, "\(dir)/screen_\(String(format: "%02d", i + 1))_\(Int(t.rounded()))s.png")
        }
    }
}

func detectBounds(_ inp: String) -> (Double, Double) {
    let a = asset(inp)
    let samples = sampleAll(a, step: 0.5)
    guard samples.count > 4 else { return (0, seconds(a)) }
    let base0 = samples.first!.s, baseN = samples.last!.s
    let thresh = 0.045
    var start = 0.0, end = seconds(a)
    // First textured frame that differs from the home screen — the `variance`
    // gate skips the near-uniform white launch/splash so the trim opens on real UI.
    for x in samples where diff(x.s, base0) > thresh && variance(x.s) > 0.004 { start = x.t; break }
    for x in samples.reversed() where diff(x.s, baseN) > thresh && variance(x.s) > 0.004 { end = x.t; break }
    start = max(0, start - 0.3)
    end = min(seconds(a), end + 0.4)
    return end > start ? (start, end) : (0, seconds(a))
}

func trim(_ inp: String, _ out: String, _ start: Double, _ end: Double, _ preset: String) {
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: out))
    guard let ex = AVAssetExportSession(asset: asset(inp), presetName: preset) else {
        die("could not create export session (preset \(preset))")
    }
    ex.outputURL = URL(fileURLWithPath: out)
    ex.outputFileType = .mp4
    ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                              end: CMTime(seconds: end, preferredTimescale: 600))
    let sem = DispatchSemaphore(value: 0)
    ex.exportAsynchronously { sem.signal() }
    sem.wait()
    if ex.status != .completed { die("trim failed: \(String(describing: ex.error))") }
}

/// Full-res stills of the screens the tour pauses on: find runs of near-still
/// frames (a deliberate hold), then keep the distinct ones.
func dwells(_ inp: String, _ dir: String, _ maxShots: Int) {
    let samples = sampleAll(asset(inp), step: 0.5)
    guard samples.count > 3 else { return }
    let stillThresh = 0.012        // inter-frame motion below this = holding
    let minHold = 1.0              // seconds
    struct Hold { var mid: Double; var rep: [Double] }
    var holds: [Hold] = []
    var i = 1
    while i < samples.count {
        if diff(samples[i].s, samples[i - 1].s) < stillThresh {
            let startT = samples[i - 1].t
            var j = i
            while j < samples.count, diff(samples[j].s, samples[j - 1].s) < stillThresh { j += 1 }
            let endT = samples[j - 1].t
            if endT - startT >= minHold {
                let mid = (startT + endT) / 2
                let rep = samples.min { abs($0.t - mid) < abs($1.t - mid) }!.s
                holds.append(Hold(mid: mid, rep: rep))
            }
            i = j + 1
        } else { i += 1 }
    }
    var picked: [Hold] = []
    for h in holds {
        if let last = picked.last, diff(last.rep, h.rep) < 0.05 { continue } // same screen
        picked.append(h)
    }
    if picked.count > maxShots {
        let stride = Double(picked.count) / Double(maxShots)
        var kept: [Hold] = []
        var k = 0.0
        while Int(k) < picked.count, kept.count < maxShots { kept.append(picked[Int(k)]); k += stride }
        picked = kept
    }
    frames(inp, dir, picked.map(\.mid))
}

switch args[1] {
case "detect":
    guard args.count >= 3 else { die("detect <in.mp4>") }
    let (s, e) = detectBounds(args[2])
    print(String(format: "%.2f %.2f", s, e))
case "trim":
    guard args.count >= 6 else { die("trim <in> <out> <start> <end> [preset]") }
    let preset = args.count > 6 ? args[6] : AVAssetExportPresetPassthrough
    trim(args[2], args[3], Double(args[4]) ?? 0, Double(args[5]) ?? 0, preset)
    print("OK")
case "frames":
    guard args.count >= 5 else { die("frames <in> <outdir> <t1,t2,...>") }
    frames(args[2], args[3], args[4].split(separator: ",").compactMap { Double($0) })
    print("OK")
case "dwells":
    guard args.count >= 4 else { die("dwells <in> <outdir> [maxShots]") }
    dwells(args[2], args[3], args.count > 4 ? (Int(args[4]) ?? 8) : 8)
    print("OK")
default:
    die("unknown command '\(args[1])'")
}
