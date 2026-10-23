import AVFoundation
import CoreMedia

/// Reads borrowed PCM storage synchronously. Callers must not mutate it during a read.
internal enum AudioLevelMeter {
    static func rms(in sampleBuffer: CMSampleBuffer) throws -> Double? {
        guard CMSampleBufferIsValid(sampleBuffer) else { throw CaptureError.invalidAudioBuffer }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount >= 0 else { throw CaptureError.invalidAudioBuffer }
        guard frameCount > 0 else { return nil }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw CaptureError.unsupportedAudioFormat
        }
        let layout = try Layout(streamDescription.pointee)
        let byteCounts = try layout.byteCounts(frameCount: frameCount)
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferGetDataLength(dataBuffer) >= byteCounts.total else {
            throw CaptureError.invalidAudioBuffer
        }

        // A stack AudioBufferList only has room for one buffer. Ask Core Media
        // for the allocation size before it writes any of the variable-length list.
        var neededBytes = 0
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &neededBytes, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: nil
        )
        let minimumListBytes = try listByteCount(bufferCount: layout.bufferCount)
        guard queryStatus == noErr, neededBytes >= minimumListBytes else {
            throw CaptureError.invalidAudioBuffer
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: neededBytes, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.initialize(to: AudioBufferList())
        defer { list.deinitialize(count: 1) }
        var retainedBlockBuffer: CMBlockBuffer?
        var populatedBytes = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &populatedBytes, bufferListOut: list,
            bufferListSize: neededBytes, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              populatedBytes >= minimumListBytes, populatedBytes <= neededBytes,
              Int(list.pointee.mNumberBuffers) == layout.bufferCount,
              let retainedBlockBuffer else {
            throw CaptureError.invalidAudioBuffer
        }

        // Core Media may have copied the samples into a new block to align them.
        // That returned block, not just sampleBuffer, owns the pointers below.
        return try withExtendedLifetime(retainedBlockBuffer) {
            try rms(in: UnsafePointer(list), layout: layout, byteCounts: byteCounts)
        }
    }

    static func rms(in buffer: AVAudioPCMBuffer) throws -> Double? {
        guard buffer.frameLength > 0 else { return nil }
        guard buffer.frameLength <= buffer.frameCapacity else { throw CaptureError.invalidAudioBuffer }
        let layout = try Layout(buffer.format.streamDescription.pointee)
        let byteCounts = try layout.byteCounts(frameCount: Int(buffer.frameLength))
        return try withExtendedLifetime(buffer) {
            try rms(in: buffer.audioBufferList, layout: layout, byteCounts: byteCounts)
        }
    }

    private struct Layout {
        let channelCount: Int
        let bufferCount: Int
        let channelsPerBuffer: Int
        let bytesPerFrame: Int

        init(_ format: AudioStreamBasicDescription) throws {
            let flags = format.mFormatFlags
            let allowedFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsNonMixable
                | kAudioFormatFlagsNativeEndian
            let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
            let channels = Int(format.mChannelsPerFrame)
            let frameBytes = UInt64(nonInterleaved ? 1 : format.mChannelsPerFrame)
                * UInt64(MemoryLayout<Float>.size)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  flags & kAudioFormatFlagIsFloat != 0,
                  flags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
                  flags & ~allowedFlags == 0,
                  format.mBitsPerChannel == 32, channels > 0,
                  format.mSampleRate.isFinite, format.mSampleRate > 0,
                  UInt64(format.mBytesPerFrame) == frameBytes,
                  format.mFramesPerPacket == 1,
                  format.mBytesPerPacket == format.mBytesPerFrame else {
                throw CaptureError.unsupportedAudioFormat
            }
            // Exact byte geometry implies packing even if the packed flag is absent.
            channelCount = channels
            bufferCount = nonInterleaved ? channels : 1
            channelsPerBuffer = nonInterleaved ? 1 : channels
            bytesPerFrame = Int(format.mBytesPerFrame)
        }

        func byteCounts(frameCount: Int) throws -> (perBuffer: Int, total: Int, samples: Int) {
            let (perBuffer, frameOverflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
            let (total, bufferOverflow) = perBuffer.multipliedReportingOverflow(by: bufferCount)
            let (samples, sampleOverflow) = frameCount.multipliedReportingOverflow(by: channelCount)
            guard frameCount > 0, !frameOverflow, !bufferOverflow, !sampleOverflow,
                  perBuffer <= Int(UInt32.max) else {
                throw CaptureError.invalidAudioBuffer
            }
            return (perBuffer, total, samples)
        }
    }

    private static func listByteCount(bufferCount: Int) throws -> Int {
        let (bufferBytes, overflow) = bufferCount.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.stride)
        guard let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers), !overflow else {
            throw CaptureError.invalidAudioBuffer
        }
        let (byteCount, additionOverflow) = offset.addingReportingOverflow(bufferBytes)
        guard !additionOverflow else { throw CaptureError.invalidAudioBuffer }
        return max(byteCount, MemoryLayout<AudioBufferList>.size)
    }

    private static func rms(
        in list: UnsafePointer<AudioBufferList>,
        layout: Layout,
        byteCounts: (perBuffer: Int, total: Int, samples: Int)
    ) throws -> Double {
        guard Int(list.pointee.mNumberBuffers) == layout.bufferCount else {
            throw CaptureError.invalidAudioBuffer
        }
        var sumOfSquares = 0.0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard Int(buffer.mNumberChannels) == layout.channelsPerBuffer,
                  Int(buffer.mDataByteSize) >= byteCounts.perBuffer,
                  Int(buffer.mDataByteSize) % layout.bytesPerFrame == 0,
                  let data = buffer.mData else {
                throw CaptureError.invalidAudioBuffer
            }
            // Raw unaligned loads also handle externally supplied AVAudioPCMBuffer
            // storage without assuming Float alignment or Swift memory binding.
            for offset in stride(from: 0, to: byteCounts.perBuffer, by: MemoryLayout<Float>.size) {
                let sample = Double(data.loadUnaligned(fromByteOffset: offset, as: Float.self))
                if sample.isFinite { sumOfSquares += sample * sample }
            }
        }
        // Nonfinite samples contribute zero energy but still count as silence.
        return min(1, (sumOfSquares / Double(byteCounts.samples)).squareRoot())
    }
}
