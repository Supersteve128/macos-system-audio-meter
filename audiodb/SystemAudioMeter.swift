import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import QuartzCore

/// AUHAL input meter with smoothing + UI throttling + bar levels.
final class AudioMeter: ObservableObject {

    // UI-facing state
    @Published var rmsDBFS: Float = -120
    @Published var peakDBFS: Float = -120
    @Published var rmsLevel: Float = 0       // 0...1 (for bar)
    @Published var peakLevel: Float = 0      // 0...1 (for bar)
    @Published var isRunning: Bool = false
    @Published var lastError: String?

    // AUHAL
    private var audioUnit: AudioUnit?
    private var deviceID: AudioObjectID = 0

    // Peak hold (amplitude domain)
    private var peakHoldAmp: Float = 0
    private var lastPeakHoldTime: CFTimeInterval = CACurrentMediaTime()

    // Smoothing (dB domain)
    private var smoothedRMSDB: Float = -120
    private var smoothedPeakDB: Float = -120

    // UI throttling
    private var lastUIPushTime: CFTimeInterval = CACurrentMediaTime()
    private let uiUpdateHz: Double = 30.0 // <= change this (20–30 feels good)

    // Meter range for the bar mapping
    private let barFloorDB: Float = -100 // everything below is 0 on the bar

    // Render buffers (Float32 non-interleaved stereo)
    private var allocatedFrames: UInt32 = 0
    private var leftPtr: UnsafeMutablePointer<Float>?
    private var rightPtr: UnsafeMutablePointer<Float>?
    private var ablPtr: UnsafeMutablePointer<AudioBufferList>?
    private var rawABL: UnsafeMutableRawPointer?

    deinit {
        stop()
        freeBuffers()
    }

    // MARK: - Public API

    func start(deviceName: String = "BlackHole 2ch") {
        guard !isRunning else { return }
        lastError = nil

        guard let id = findDevice(named: deviceName) else {
            lastError = "Could not find device '\(deviceName)'. Check Audio MIDI Setup."
            return
        }
        deviceID = id

        do {
            try setupAUHAL(deviceID: id)
            try startAUHAL()

            peakHoldAmp = 0
            lastPeakHoldTime = CACurrentMediaTime()

            smoothedRMSDB = -120
            smoothedPeakDB = -120
            lastUIPushTime = CACurrentMediaTime()

            DispatchQueue.main.async { self.isRunning = true }
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
            stop()
        }
    }

    func stop() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        audioUnit = nil

        DispatchQueue.main.async {
            self.isRunning = false
            self.rmsDBFS = -120
            self.peakDBFS = -120
            self.rmsLevel = 0
            self.peakLevel = 0
        }

        peakHoldAmp = 0
    }

    func resetPeak() {
        peakHoldAmp = 0
        lastPeakHoldTime = CACurrentMediaTime()
    }

    // MARK: - Device lookup

    private func findDevice(named target: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return nil }

        for id in devices {
            if deviceName(id) == target { return id }
        }

        print("Available devices:", devices.compactMap { deviceName($0) })
        return nil
    }

    private func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr else { return nil }
        return cfName as String
    }

    private func nominalSampleRate(for deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 48_000
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status != noErr { return 48_000 }
        return rate
    }

    // MARK: - AUHAL

    private func setupAUHAL(deviceID: AudioObjectID) throws {
        // Clean up any old AU
        stop()
        freeBuffers()

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw err("Could not find AUHAL component")
        }

        var auOpt: AudioUnit?
        guard AudioComponentInstanceNew(comp, &auOpt) == noErr, let au = auOpt else {
            throw err("Could not create AudioUnit instance")
        }
        audioUnit = au

        // Enable input on bus 1, disable output on bus 0
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0

        var status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1,
            &enableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw osStatus(status, "Enable input IO failed") }

        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0,
            &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw osStatus(status, "Disable output IO failed") }

        // Attach device
        var dev = deviceID
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else { throw osStatus(status, "Set device failed") }

        // Force Float32 non-interleaved stereo at device nominal sample rate
        let sr = nominalSampleRate(for: deviceID)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sr,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, // OUTPUT scope, bus 1
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw osStatus(status, "Set stream format failed") }

        // Install input callback
        var cb = AURenderCallbackStruct(
            inputProc: AudioMeter.renderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw osStatus(status, "Set input callback failed") }

        status = AudioUnitInitialize(au)
        guard status == noErr else { throw osStatus(status, "AudioUnitInitialize failed") }

        print("✅ AUHAL initialized for:", deviceName(deviceID) ?? "\(deviceID)")
        print("🎛️ Using format: sr=\(sr) ch=2 Float32 non-interleaved")
    }

    private func startAUHAL() throws {
        guard let au = audioUnit else { throw err("AudioUnit missing") }
        let status = AudioOutputUnitStart(au)
        guard status == noErr else { throw osStatus(status, "AudioOutputUnitStart failed") }
        print("✅ AUHAL started")
    }

    // MARK: - Render callback

    private static let renderCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let meter = Unmanaged<AudioMeter>.fromOpaque(refCon).takeUnretainedValue()
        return meter.handleRender(ioActionFlags: ioActionFlags,
                                  timeStamp: inTimeStamp,
                                  frames: inNumberFrames)
    }

    /// realtime thread — no heavy allocations, no SwiftUI work directly
    private func handleRender(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
                              timeStamp: UnsafePointer<AudioTimeStamp>?,
                              frames: UInt32) -> OSStatus {
        guard let au = audioUnit else { return noErr }

        ensureBuffers(frames: frames)
        guard let ablPtr, let leftPtr, let rightPtr else { return noErr }

        let abl = UnsafeMutableBufferPointer<AudioBuffer>(start: &ablPtr.pointee.mBuffers, count: 2)
        let bytes = UInt32(frames * 4)

        abl[0].mNumberChannels = 1
        abl[0].mDataByteSize = bytes
        abl[0].mData = UnsafeMutableRawPointer(leftPtr)

        abl[1].mNumberChannels = 1
        abl[1].mDataByteSize = bytes
        abl[1].mData = UnsafeMutableRawPointer(rightPtr)

        var localFlags: AudioUnitRenderActionFlags = []
        var localTimeStamp = AudioTimeStamp()
        let flagsPtr = ioActionFlags ?? withUnsafeMutablePointer(to: &localFlags) { $0 }
        let tsPtr = timeStamp ?? withUnsafePointer(to: &localTimeStamp) { $0 }

        let r = AudioUnitRender(au, flagsPtr, tsPtr, 1, frames, ablPtr)
        if r != noErr { return r }

        // Raw meter (amp domain)
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(leftPtr,  1, &peakL, vDSP_Length(frames))
        vDSP_maxmgv(rightPtr, 1, &peakR, vDSP_Length(frames))
        let peakAmp = max(peakL, peakR)

        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(leftPtr,  1, &rmsL, vDSP_Length(frames))
        vDSP_rmsqv(rightPtr, 1, &rmsR, vDSP_Length(frames))
        let rmsAmp = max(rmsL, rmsR)

        let targetRMSDB = ampToDBFS(rmsAmp)
        let targetPeakDB = ampToDBFS(peakAmp)

        // Peak hold (amp decay)
        let now = CACurrentMediaTime()
        let dtHold = Float(now - lastPeakHoldTime)
        lastPeakHoldTime = now
        let decayDBPerSec: Float = 12
        let decayAmp = powf(10.0, -(dtHold * decayDBPerSec) / 20.0)
        peakHoldAmp = max(peakAmp, peakHoldAmp * decayAmp)
        let holdPeakDB = ampToDBFS(peakHoldAmp)

        // Smoothing (dB-domain attack/release)
        // These times are what make it feel “not too fast”
        let attackTau: Float = 0.06   // seconds (fast rise)
        let releaseTau: Float = 0.25  // seconds (slow fall)

        let dt = max(Float(1.0 / 48000.0), Float(dtHold)) // dt ~ callback interval
        smoothedRMSDB = smoothDB(current: smoothedRMSDB, target: targetRMSDB, dt: dt, attackTau: attackTau, releaseTau: releaseTau)

        // Peak should be snappier up, slower down
        smoothedPeakDB = smoothDB(current: smoothedPeakDB, target: max(targetPeakDB, holdPeakDB), dt: dt, attackTau: 0.02, releaseTau: 0.35)

        // UI throttle
        if now - lastUIPushTime >= (1.0 / uiUpdateHz) {
            lastUIPushTime = now

            let rmsNorm = dbToBar(smoothedRMSDB)
            let peakNorm = dbToBar(smoothedPeakDB)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rmsDBFS = smoothedRMSDB
                self.peakDBFS = smoothedPeakDB
                self.rmsLevel = rmsNorm
                self.peakLevel = peakNorm
            }
        }

        return noErr
    }

    // MARK: - Buffers

    private func ensureBuffers(frames: UInt32) {
        if frames <= allocatedFrames, ablPtr != nil, leftPtr != nil, rightPtr != nil { return }

        freeBuffers()
        allocatedFrames = max(frames, 1024)

        leftPtr  = .allocate(capacity: Int(allocatedFrames))
        rightPtr = .allocate(capacity: Int(allocatedFrames))

        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        rawABL = raw

        ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        ablPtr!.pointee.mNumberBuffers = 2

        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &ablPtr!.pointee.mBuffers, count: 2)
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    }

    private func freeBuffers() {
        leftPtr?.deallocate()
        rightPtr?.deallocate()
        leftPtr = nil
        rightPtr = nil

        rawABL?.deallocate()
        rawABL = nil
        ablPtr = nil
        allocatedFrames = 0
    }

    // MARK: - Helpers

    @inline(__always)
    private func ampToDBFS(_ amp: Float) -> Float {
        let clamped = max(amp, 1e-6)
        return 20.0 * log10f(clamped)
    }

    // dB smoothing with attack/release time constants
    @inline(__always)
    private func smoothDB(current: Float, target: Float, dt: Float, attackTau: Float, releaseTau: Float) -> Float {
        let tau = (target > current) ? attackTau : releaseTau
        // alpha = 1 - e^(-dt/tau)
        let alpha = 1.0 - expf(-dt / max(1e-4, tau))
        return current + alpha * (target - current)
    }

    // Map dBFS -> 0...1 bar
    @inline(__always)
    private func dbToBar(_ db: Float) -> Float {
        if db <= barFloorDB { return 0 }
        if db >= 0 { return 1 }
        return (db - barFloorDB) / (0 - barFloorDB)
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "AudioMeter", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func osStatus(_ status: OSStatus, _ message: String) -> NSError {
        NSError(domain: "AudioMeter", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(message) (OSStatus \(status))"])
    }
}
