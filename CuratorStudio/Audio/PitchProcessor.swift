import Foundation
import AVFoundation
import AudioToolbox
import MediaToolbox

// MARK: - C callbacks
//
// MTAudioProcessingTap takes plain C function pointers, so these are declared
// as non-capturing top-level closures. They bounce straight back into the
// PitchProcessor instance stored in the tap's client info.

private let pitchTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let pitchTapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in
    // The processor outlives the tap; nothing to tear down here.
}

private let pitchTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<PitchProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.prepare(maxFrames: maxFrames, format: processingFormat.pointee)
}

private let pitchTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<PitchProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.unprepare()
}

private let pitchTapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<PitchProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.process(
        tap: tap,
        numberFrames: numberFrames,
        flags: flags,
        bufferList: bufferListInOut,
        numberFramesOut: numberFramesOut,
        flagsOut: flagsOut
    )
}

private let pitchRenderCallback: AURenderCallback = {
    inRefCon, _, _, _, inNumberFrames, ioData in
    let processor = Unmanaged<PitchProcessor>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    return processor.pullSource(frames: inNumberFrames, into: ioData)
}

// MARK: - Pitch processor

/// Real-time transposition of an AVPlayer's audio, in semitones, without
/// changing playback speed.
///
/// Implementation: an `MTAudioProcessingTap` is attached to the item's audio
/// track through an `AVAudioMix`. Inside the tap we run Apple's
/// `AUNewTimePitch` audio unit with its rate fixed at 1.0 and only its pitch
/// parameter driven, so speed stays under `AVPlayer.rate`'s control while
/// pitch is ours.
///
/// One processor is owned by the player for its whole lifetime; a fresh tap is
/// created per player item.
final class PitchProcessor {

    /// Transposition in semitones. Positive is up.
    var semitones: Int = 0 {
        didSet { applyPitchParameter() }
    }

    /// Fine tuning in cents on top of `semitones`, for detuned recordings.
    var fineCents: Float = 0 {
        didSet { applyPitchParameter() }
    }

    private(set) var isEngineActive = false

    private var audioUnit: AudioUnit?
    private var currentTap: Unmanaged<MTAudioProcessingTap>?
    private var activeTapForRender: MTAudioProcessingTap?
    private var sampleTime: Float64 = 0
    private let lock = NSLock()

    // MARK: Mix construction

    /// Builds an audio mix that routes `track` through the pitch unit.
    /// Returns nil if the tap could not be created — playback then continues
    /// untransposed rather than failing.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        releaseTap()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: pitchTapInit,
            finalize: pitchTapFinalize,
            prepare: pitchTapPrepare,
            unprepare: pitchTapUnprepare,
            process: pitchTapProcess
        )

        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapRef
        )

        guard status == noErr, let tapRef else { return nil }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tapRef.takeUnretainedValue()

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]

        currentTap = tapRef
        return mix
    }

    func releaseTap() {
        lock.lock()
        activeTapForRender = nil
        lock.unlock()
        currentTap?.release()
        currentTap = nil
    }

    // MARK: Audio unit lifecycle (called on the audio queue)

    fileprivate func prepare(maxFrames: CMItemCount, format: AudioStreamBasicDescription) {
        teardownUnit()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else { return }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }

        var streamFormat = format
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        var ok = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &streamFormat, asbdSize
        ) == noErr

        ok = ok && AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &streamFormat, asbdSize
        ) == noErr

        var maximumFrames = UInt32(maxFrames)
        ok = ok && AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maximumFrames, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr

        var renderCallback = AURenderCallbackStruct(
            inputProc: pitchRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        ok = ok && AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &renderCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr

        guard ok, AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            return
        }

        // Rate stays at 1.0: AVPlayer.rate handles speed.
        AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, 1.0, 0)

        audioUnit = unit
        sampleTime = 0
        isEngineActive = true
        applyPitchParameter()
    }

    fileprivate func unprepare() {
        teardownUnit()
    }

    private func teardownUnit() {
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        isEngineActive = false
    }

    private func applyPitchParameter() {
        guard let unit = audioUnit else { return }
        let cents = max(-2400, min(2400, Float(semitones) * 100 + fineCents))
        AudioUnitSetParameter(unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, cents, 0)
    }

    // MARK: Render (audio thread)

    fileprivate func process(
        tap: MTAudioProcessingTap,
        numberFrames: CMItemCount,
        flags: MTAudioProcessingTapFlags,
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
    ) {
        lock.lock()
        activeTapForRender = tap
        lock.unlock()

        guard let unit = audioUnit, semitones != 0 || fineCents != 0 else {
            passthrough(tap: tap, numberFrames: numberFrames, bufferList: bufferList,
                        numberFramesOut: numberFramesOut, flagsOut: flagsOut)
            return
        }

        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid

        var actionFlags = AudioUnitRenderActionFlags(rawValue: 0)
        let status = AudioUnitRender(
            unit, &actionFlags, &timeStamp, 0, UInt32(numberFrames), bufferList
        )

        if status == noErr {
            sampleTime += Float64(numberFrames)
            numberFramesOut.pointee = numberFrames
        } else {
            passthrough(tap: tap, numberFrames: numberFrames, bufferList: bufferList,
                        numberFramesOut: numberFramesOut, flagsOut: flagsOut)
        }
    }

    private func passthrough(
        tap: MTAudioProcessingTap,
        numberFrames: CMItemCount,
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
    ) {
        var timeRange = CMTimeRange()
        var provided: CMItemCount = 0
        let status = MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferList, flagsOut, &timeRange, &provided
        )
        numberFramesOut.pointee = status == noErr ? provided : 0
    }

    fileprivate func pullSource(frames: UInt32, into ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        lock.lock()
        let tap = activeTapForRender
        lock.unlock()
        guard let tap else { return noErr }

        var timeRange = CMTimeRange()
        var provided: CMItemCount = 0
        return MTAudioProcessingTapGetSourceAudio(
            tap, CMItemCount(frames), ioData, nil, &timeRange, &provided
        )
    }

    deinit {
        teardownUnit()
        currentTap?.release()
    }
}
