// File info + streaming decode. Native ExtAudioFile first (C API: errors are status codes, never ObjC exceptions);
// ffmpeg fallback for streams macOS can't decode, e.g. the variable-blocksize FLACs ffmpeg writes when transcoding MP3s.
import Accelerate
import AudioToolbox
import Foundation

struct DecodeError: LocalizedError, CustomStringConvertible {
    var description: String
    var errorDescription: String? { description }
}

func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr { throw DecodeError(description: "\(what) failed (\(st))") }
}

struct Info {
    var codec: String, lossless: Bool, claimedKbps: Int, sampleRate: Int, bitDepth: Int, channels: Int, duration: Double
}

func probe(_ url: URL) throws -> Info {
    var ext: ExtAudioFileRef?
    try check(ExtAudioFileOpenURL(url as CFURL, &ext), "Open")
    defer { ExtAudioFileDispose(ext!) }
    var a = AudioStreamBasicDescription(), frames: Int64 = 0, size = UInt32(MemoryLayout.size(ofValue: a))
    try check(ExtAudioFileGetProperty(ext!, kExtAudioFileProperty_FileDataFormat, &size, &a), "Format")
    size = 8
    ExtAudioFileGetProperty(ext!, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
    let sr = Int(a.mSampleRate), ch = Int(a.mChannelsPerFrame)
    let duration = a.mSampleRate > 0 ? Double(frames) / a.mSampleRate : 0
    var bits = 0, codec: String
    switch a.mFormatID {
    case kAudioFormatLinearPCM:
        bits = Int(a.mBitsPerChannel)
        let fl = a.mFormatFlags
        codec = "pcm_" + (fl & kAudioFormatFlagIsFloat != 0 ? "f" : fl & kAudioFormatFlagIsSignedInteger != 0 ? "s" : "u")
            + "\(bits)" + (bits > 8 ? (fl & kAudioFormatFlagIsBigEndian != 0 ? "be" : "le") : "")
    case kAudioFormatMPEGLayer3: codec = "mp3"
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: codec = "aac"
    case kAudioFormatAppleLossless, kAudioFormatFLAC:
        codec = a.mFormatID == kAudioFormatFLAC ? "flac" : "alac"
        bits = [0, 16, 20, 24, 32][min(Int(a.mFormatFlags), 4)]  // source-depth flags: 1=16, 2=20, 3=24, 4=32 bit
    default:
        codec = String(bytes: withUnsafeBytes(of: a.mFormatID.bigEndian) { Array($0) }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "?"
    }
    var kbps = sr * bits * ch / 1000
    if !codec.hasPrefix("pcm_") {  // audio payload bytes (no tags/artwork) over duration: exact for CBR
        var af: AudioFileID?, bytes: UInt64 = 0
        size = UInt32(MemoryLayout<AudioFileID>.size)
        ExtAudioFileGetProperty(ext!, kExtAudioFileProperty_AudioFile, &size, &af)
        size = 8
        if let af, duration > 0, AudioFileGetProperty(af, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr {
            kbps = Int((Double(bytes) * 8 / duration / 1000).rounded())
        }
    }
    return Info(codec: codec, lossless: ["flac", "alac", "wavpack", "ape", "tta"].contains(codec) || codec.hasPrefix("pcm_"),
                claimedKbps: kbps, sampleRate: sr, bitDepth: bits, channels: ch, duration: duration)
}

/// Artist tag via Core Audio's info dictionary (ID3, MP4, FLAC/Vorbis comments); header read only, no decode.
public func readArtist(_ url: URL) -> String? {
    var af: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &af) == noErr, let af else { return nil }
    defer { AudioFileClose(af) }
    var dict: Unmanaged<CFDictionary>?, size = UInt32(MemoryLayout<CFDictionary?>.size)
    guard AudioFileGetProperty(af, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr, let dict else { return nil }
    return (dict.takeRetainedValue() as? [String: Any])?[kAFInfoDictionary_Artist] as? String
}

public let ffmpegPath: String? = (["/opt/homebrew/bin", "/usr/local/bin"]
    + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init))
    .map { $0 + "/ffmpeg" }.first(where: FileManager.default.isExecutableFile)

/// Streams the file as stereo chunks of up to `chunk` frames (mono duplicated, >2 channels mapped to 2), from `start` s.
/// int32: samples are left-justified Int32 values (as Double, exact) instead of -1...1 floats.
func decode(_ url: URL, chunk: Int, start: Double = 0, frames limit: Int? = nil, int32: Bool = false,
            _ body: ([Double], [Double]) throws -> Void) throws {
    var ext: ExtAudioFileRef?
    try check(ExtAudioFileOpenURL(url as CFURL, &ext), "Open")
    defer { ExtAudioFileDispose(ext!) }
    var file = AudioStreamBasicDescription(), size = UInt32(MemoryLayout.size(ofValue: file))
    try check(ExtAudioFileGetProperty(ext!, kExtAudioFileProperty_FileDataFormat, &size, &file), "Format")
    let bps: UInt32 = int32 ? 4 : 8  // floats decode straight to Float64: no conversion pass
    var client = AudioStreamBasicDescription(
        mSampleRate: file.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (int32 ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: bps, mFramesPerPacket: 1, mBytesPerFrame: bps, mChannelsPerFrame: 2, mBitsPerChannel: bps * 8, mReserved: 0)
    // ponytail: ffmpeg decodes FLAC faster wall-clock only by multithreading; per core it costs the same as native, so a
    // full scan (every core busy) gains nothing from it. Native stays first.
    let native = ExtAudioFileSetProperty(ext!, kExtAudioFileProperty_ClientDataFormat, size, &client) == noErr
        && (start <= 0 || ExtAudioFileSeek(ext!, Int64(start * file.mSampleRate)) == noErr)
    if !native { return try ffmpegDecode(url, chunk: chunk, start: start, frames: limit, int32: int32, body) }

    var l = [Double](repeating: 0, count: chunk), r = l
    var left = limit ?? .max, first = true
    while left > 0 {
        var n = UInt32(min(chunk, left))
        let st = l.withUnsafeMutableBytes { lp in
            r.withUnsafeMutableBytes { rp in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(abl.unsafeMutablePointer) }
                abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: n * bps, mData: lp.baseAddress)
                abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: n * bps, mData: rp.baseAddress)
                return ExtAudioFileRead(ext!, &n, abl.unsafeMutablePointer)
            }
        }
        if st != noErr && first { return try ffmpegDecode(url, chunk: chunk, start: start, frames: limit, int32: int32, body) }
        try check(st, "Decode")
        first = false
        if n == 0 { break }
        left -= Int(n)
        let cnt = Int(n)
        if int32 {
            let toD = { (x: [Double]) in x.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(cnt)).map(Double.init) } }
            try body(toD(l), toD(r))
        } else if cnt == chunk {
            try body(l, r)
        } else {
            try body(Array(l[..<cnt]), Array(r[..<cnt]))
        }
    }
}

func ffmpegDecode(_ url: URL, chunk: Int, start: Double, frames limit: Int?, int32: Bool,
                  _ body: ([Double], [Double]) throws -> Void) throws {
    guard let ffmpegPath else {
        throw DecodeError(description: "macOS can't decode this file (e.g. variable-blocksize FLAC); install ffmpeg to analyze it")
    }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: ffmpegPath)
    p.arguments = ["-v", "error", "-nostdin", "-threads", "1", "-ss", "\(start)", "-i", url.path, "-map", "0:a:0", "-ac", "2"]
        + (limit.map { ["-af", "atrim=end_sample=\($0)"] } ?? [])
        + ["-f", int32 ? "s32le" : "f32le", "-"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    defer { if p.isRunning { p.terminate() }; p.waitUntilExit() }
    let fd = out.fileHandleForReading.fileDescriptor
    let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk * 8, alignment: 16)
    defer { buf.deallocate() }
    while true {
        var got = 0
        while got < chunk * 8 {
            let k = read(fd, buf + got, chunk * 8 - got)
            if k < 0 && errno == EINTR { continue }
            if k <= 0 { break }
            got += k
        }
        let n = got / 8
        if n == 0 { break }
        var l = [Double](repeating: 0, count: n), r = l
        if int32 {  // deinterleave + convert, stride 2
            let s = buf.assumingMemoryBound(to: Int32.self)
            vDSP_vflt32D(s, 2, &l, 1, vDSP_Length(n)); vDSP_vflt32D(s + 1, 2, &r, 1, vDSP_Length(n))
        } else {
            let s = buf.assumingMemoryBound(to: Float.self)
            vDSP_vspdp(s, 2, &l, 1, vDSP_Length(n)); vDSP_vspdp(s + 1, 2, &r, 1, vDSP_Length(n))
        }
        try body(l, r)
        if n < chunk { break }
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw DecodeError(description: "ffmpeg failed to decode (\(p.terminationStatus))") }
}
