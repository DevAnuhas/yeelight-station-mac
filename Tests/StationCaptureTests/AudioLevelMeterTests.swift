import AVFoundation
import CoreMedia
import XCTest
@testable import StationCapture

final class AudioLevelMeterTests: XCTestCase {
    func testPCMIncludesEveryChannelInEitherLayout() throws {
        for interleaved in [false, true] {
            let buffer = try makePCMBuffer(channels: [[1, -1, 0], [0.5, -0.5, 0]], interleaved: interleaved)
            XCTAssertEqual(try XCTUnwrap(AudioLevelMeter.rms(in: buffer)), (2.5 / 6).squareRoot(), accuracy: 1e-12)
        }
    }

    func testPCMReadsFrameLengthInsteadOfCapacity() throws {
        for interleaved in [false, true] {
            let buffer = try makePCMBuffer(channels: [[0, 0], [0, 0]], interleaved: interleaved, extraCapacity: 7)
            XCTAssertEqual(try AudioLevelMeter.rms(in: buffer), 0)
        }
    }

    func testPCMNonfiniteSamplesAreSilence() throws {
        let buffer = try makePCMBuffer(channels: [[.nan, .infinity, -.infinity, 1]], interleaved: false)
        XCTAssertEqual(try AudioLevelMeter.rms(in: buffer), 0.5)
    }

    func testPCMClampsTheResultAfterComputingRMS() throws {
        let sparsePeak = try makePCMBuffer(channels: [[2] + Array(repeating: 0, count: 15)], interleaved: true)
        XCTAssertEqual(try AudioLevelMeter.rms(in: sparsePeak), 0.5)
        let largePeak = try makePCMBuffer(channels: [[Float.greatestFiniteMagnitude]], interleaved: false)
        XCTAssertEqual(try AudioLevelMeter.rms(in: largePeak), 1)
    }

    func testPCMEmptyInputReturnsNil() throws {
        let buffer = try makePCMBuffer(channels: [[]], interleaved: false, extraCapacity: 1)
        XCTAssertNil(try AudioLevelMeter.rms(in: buffer))
    }

    func testPCMRejectsIntegerSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
            XCTAssertEqual($0 as? CaptureError, .unsupportedAudioFormat)
        }
    }

    func testPCMRejectsNullStorage() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(PCMBufferWithFixtureStorage(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: nil))
        try withUnsafePointer(to: &list) { pointer in
            buffer.fixtureStorage = pointer
            defer { buffer.fixtureStorage = nil }
            XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
                XCTAssertEqual($0 as? CaptureError, .invalidAudioBuffer)
            }
        }
    }

    func testPCMCanReadUnalignedExternalStorage() throws {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let byteCount = samples.count * MemoryLayout<Float>.size
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: byteCount + 1, alignment: 16)
        defer { allocation.deallocate() }
        let data = allocation.advanced(by: 1)
        samples.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(byteCount), mData: data))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list, deallocator: { _ in }))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try withExtendedLifetime(buffer) {
            XCTAssertEqual(try AudioLevelMeter.rms(in: buffer), 0.5)
        }
    }

    func testPCMRejectsInvalidBufferCountsChannelsAndByteCounts() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(PCMBufferWithFixtureStorage(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let data = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        defer { data.deallocate() }
        let invalidShapes: [(UInt32, UInt32, UInt32)] = [
            (0, 2, 24), (.max, 2, 24), (1, 0, 24), (1, 1, 24),
            (1, 2, 16), (1, 2, 23), (1, 2, 25)
        ]
        for (buffers, channels, bytes) in invalidShapes {
            var list = AudioBufferList(mNumberBuffers: buffers, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: bytes, mData: data))
            try withUnsafePointer(to: &list) { pointer in
                buffer.fixtureStorage = pointer
                defer { buffer.fixtureStorage = nil }
                XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
                    XCTAssertEqual($0 as? CaptureError, .invalidAudioBuffer)
                }
            }
        }
    }

    func testSampleBufferIncludesEveryChannelInEitherLayout() throws {
        for interleaved in [false, true] {
            // Three frames put planar channels at offsets that require realignment.
            let buffer = try makeSampleBuffer(channels: [[1, -1, 0], [0.5, -0.5, 0]], interleaved: interleaved)
            XCTAssertEqual(try XCTUnwrap(AudioLevelMeter.rms(in: buffer)), (2.5 / 6).squareRoot(), accuracy: 1e-12)
        }
    }

    func testSampleBufferAllocatesAListForEveryPlanarChannel() throws {
        let channels: [[Float]] = [[1, 0, 0], [0, 0, 0], [0.5, 0, 0], [0, 0, 0], [-0.5, 0, 0], [-1, 0, 0]]
        let buffer = try makeSampleBuffer(channels: channels, interleaved: false)
        XCTAssertEqual(try XCTUnwrap(AudioLevelMeter.rms(in: buffer)), (2.5 / 18).squareRoot(), accuracy: 1e-12)
    }

    func testSampleBufferNonfiniteSamplesAreSilence() throws {
        for interleaved in [false, true] {
            let mixed = try makeSampleBuffer(channels: [[.nan, 1], [.infinity, -.infinity]], interleaved: interleaved)
            XCTAssertEqual(try AudioLevelMeter.rms(in: mixed), 0.5)
            let silent = try makeSampleBuffer(channels: [[.nan, .infinity]], interleaved: interleaved)
            XCTAssertEqual(try AudioLevelMeter.rms(in: silent), 0)
        }
    }

    func testSampleBufferClampsAfterComputingRMSWithoutFloatOverflow() throws {
        let sparsePeak = try makeSampleBuffer(channels: [[2] + Array(repeating: 0, count: 15)], interleaved: true)
        XCTAssertEqual(try AudioLevelMeter.rms(in: sparsePeak), 0.5)
        let largePeak = try makeSampleBuffer(channels: [[Float.greatestFiniteMagnitude]], interleaved: false)
        XCTAssertEqual(try AudioLevelMeter.rms(in: largePeak), 1)
    }

    func testSampleBufferEmptyInputReturnsNil() throws {
        let buffer = try makeSampleBuffer(channels: [[]], interleaved: false)
        XCTAssertNil(try AudioLevelMeter.rms(in: buffer))
    }

    func testSampleBufferRejectsShortenedStorageInEitherLayout() throws {
        for interleaved in [false, true] {
            for missingBytes in [1, MemoryLayout<Float>.size] {
                let buffer = try makeSampleBuffer(channels: [[1, 1, 1], [1, 1, 1]], interleaved: interleaved, missingBytes: missingBytes)
                XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
                    XCTAssertEqual($0 as? CaptureError, .invalidAudioBuffer)
                }
            }
        }
    }

    func testSampleBufferRejectsInvalidatedInput() throws {
        let buffer = try makeSampleBuffer(channels: [[1]], interleaved: true)
        XCTAssertEqual(CMSampleBufferInvalidate(buffer), noErr)
        XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
            XCTAssertEqual($0 as? CaptureError, .invalidAudioBuffer)
        }
    }

    func testSampleBufferRejectsUnreadyInputWithoutMakingItReady() throws {
        let buffer = try makeSampleBuffer(channels: [[1]], interleaved: true, dataReady: false)
        XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
            XCTAssertEqual($0 as? CaptureError, .invalidAudioBuffer)
        }
        XCTAssertFalse(CMSampleBufferDataIsReady(buffer))
    }

    func testSampleBufferRejectsUnsupportedFormatsAndGeometry() throws {
        let changes: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mFormatFlags |= kAudioFormatFlagIsSignedInteger },
            { $0.mBitsPerChannel = 64; $0.mBytesPerFrame = 8; $0.mBytesPerPacket = 8 },
            { $0.mBytesPerFrame = 8; $0.mBytesPerPacket = 8 },
            { $0.mFramesPerPacket = 2; $0.mBytesPerPacket = 8 }
        ]
        for change in changes {
            let buffer = try makeSampleBuffer(channels: [[1, 1]], interleaved: true, modifyFormat: change)
            XCTAssertThrowsError(try AudioLevelMeter.rms(in: buffer)) {
                XCTAssertEqual($0 as? CaptureError, .unsupportedAudioFormat)
            }
        }
    }

    func testSampleBufferAcceptsPackingImpliedByByteGeometry() throws {
        let buffer = try makeSampleBuffer(channels: [[0.5, -0.5]], interleaved: true) {
            $0.mFormatFlags &= ~kAudioFormatFlagIsPacked
        }
        XCTAssertEqual(try AudioLevelMeter.rms(in: buffer), 0.5)
    }

    private func makePCMBuffer(channels: [[Float]], interleaved: Bool, extraCapacity: Int = 0) throws -> AVAudioPCMBuffer {
        let frames = channels[0].count
        let capacity = frames + extraCapacity
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)))
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in channels.indices {
            for frame in 0..<capacity {
                let pointer = interleaved ? data[0] : data[channel]
                let index = interleaved ? frame * channels.count + channel : frame
                pointer[index] = frame < frames ? channels[channel][frame] : 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private func makeSampleBuffer(
        channels: [[Float]],
        interleaved: Bool,
        missingBytes: Int = 0,
        dataReady: Bool = true,
        modifyFormat: (inout AudioStreamBasicDescription) -> Void = { _ in }
    ) throws -> CMSampleBuffer {
        let frames = channels[0].count
        let samples = interleaved
            ? (0..<frames).flatMap { frame in channels.map { $0[frame] } }
            : channels.flatMap { $0 }
        let frameBytes = UInt32(MemoryLayout<Float>.size * (interleaved ? channels.count : 1))
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
            mChannelsPerFrame: UInt32(channels.count), mBitsPerChannel: 32, mReserved: 0
        )
        modifyFormat(&format)
        var description: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        XCTAssertEqual(formatStatus, noErr)
        let audioDescription = try XCTUnwrap(description)
        let byteCount = samples.count * MemoryLayout<Float>.size - missingBytes
        var block: CMBlockBuffer?
        if byteCount > 0 {
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: 0, blockBufferOut: &block
            )
            XCTAssertEqual(blockStatus, noErr)
            let dataBlock = try XCTUnwrap(block)
            let copyStatus = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: dataBlock, offsetIntoDestination: 0, dataLength: byteCount)
            }
            XCTAssertEqual(copyStatus, noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = Int(format.mBytesPerFrame)
        var buffer: CMSampleBuffer?
        let status = withUnsafePointer(to: &sampleSize) { sizePointer in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: dataReady,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: audioDescription,
                sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: interleaved ? 1 : 0,
                sampleSizeArray: interleaved ? sizePointer : nil, sampleBufferOut: &buffer
            )
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(buffer)
    }
}

// AVAudioPCMBuffer reconstructs its normal lists on access. Override the read
// property to present malformed storage without corrupting the real allocation.
private final class PCMBufferWithFixtureStorage: AVAudioPCMBuffer {
    var fixtureStorage: UnsafePointer<AudioBufferList>?

    override var audioBufferList: UnsafePointer<AudioBufferList> {
        fixtureStorage ?? super.audioBufferList
    }
}
