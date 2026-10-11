import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import PulseFloatCore

/// 用 Core Audio Process Tap 擷取「全部系統音訊（排除自己）」，降成單聲道寫進 `SampleRingBuffer`。
/// 流程：CATapDescription → AudioHardwareCreateProcessTap → 私有 aggregate device（預設輸出裝置為主子裝置）
/// → IOProc → AudioDeviceStart。預設輸出裝置改變時整條重建。只在主執行緒呼叫。
/// 權限：系統在第一次 AudioDeviceStart 時詢問；被拒時 tap 只送全 0 的 buffer（由 LiveSpectrumSource 當成靜音處理）。
@MainActor
final class SystemAudioTap {
    enum State: Equatable {
        case stopped
        case running(sampleRate: Double)
        case failed(String)
    }

    private(set) var state: State = .stopped
    /// 每次（重新）啟動成功後回報 tap 的取樣率（Hz）。
    var onFormatChange: ((Double) -> Void)?

    private let ring: SampleRingBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let logger = Logger(subsystem: "com.victorhuang.PulseFloat", category: "audio")

    init(ring: SampleRingBuffer) {
        self.ring = ring
    }

    /// 啟動擷取並開始監聽預設輸出裝置；失敗時記錄在 `state`，畫面會自動用模擬訊號。
    func start() {
        installOutputListener()
        startChain()
    }

    /// 停止擷取、移除監聽並釋放所有 Core Audio 物件。
    func stop() {
        removeOutputListener()
        teardown()
        state = .stopped
    }

    private func restart() {
        logger.info("Default output device changed; rebuilding tap")
        teardown()
        startChain()
    }

    private func startChain() {
        do {
            let sampleRate = try buildChain()
            state = .running(sampleRate: sampleRate)
            onFormatChange?(sampleRate)
            logger.info("System audio tap running at \(sampleRate, privacy: .public) Hz")
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
            logger.error("System audio tap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func buildChain() throws -> Double {
        let ownProcess = Self.processObject(for: getpid())
        let excluded = ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "PulseFloat"
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        try Self.getProperty(tap, kAudioTapPropertyFormat, into: &format)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0 else {
            throw TapError.unsupportedFormat
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PulseFloat Tap",
            kAudioAggregateDeviceUIDKey: "com.victorhuang.PulseFloat.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = device

        var procID: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, Self.makeIOBlock(ring: ring, interleaved: interleaved)),
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try Self.check(AudioDeviceStart(device, procID), "AudioDeviceStart")
        return format.mSampleRate
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - IO thread

    /// IOProc 在 HAL IO 執行緒執行（queue 傳 nil）。必須在 nonisolated 環境建立：
    /// 若在 @MainActor 方法裡直接寫 closure，Swift 6 會插入 main queue 斷言並在 IO 執行緒 SIGTRAP。
    /// 只捕捉 Sendable 的 ring buffer；不配置記憶體、不上鎖、不用 for…in（Debug 下會 malloc）。
    private nonisolated static func makeIOBlock(ring: SampleRingBuffer, interleaved: Bool) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count > 0 else { return }
            let first = buffers[0]
            guard let firstData = first.mData else { return }
            let left = UnsafePointer(firstData.assumingMemoryBound(to: Float.self))
            if interleaved {
                let channels = max(1, Int(first.mNumberChannels))
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                ring.writeInterleaved(left, frameCount: frames, channelCount: channels)
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                var right: UnsafePointer<Float>?
                if buffers.count > 1, let secondData = buffers[1].mData {
                    right = UnsafePointer(secondData.assumingMemoryBound(to: Float.self))
                }
                ring.writeDeinterleaved(left: left, right: right, frameCount: frames)
            }
        }
    }

    // MARK: - Default output device changes

    private func installOutputListener() {
        guard outputListener == nil else { return }
        let listener = Self.makeOutputListener(owner: self)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if status == noErr {
            outputListener = listener
        } else {
            logger.error("Cannot observe default output device: \(status, privacy: .public)")
        }
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, outputListener
        )
        self.outputListener = nil
    }

    /// listener 註冊在 main queue，所以可以同步進入 MainActor。
    private nonisolated static func makeOutputListener(owner: SystemAudioTap) -> AudioObjectPropertyListenerBlock {
        { [weak owner] _, _ in
            MainActor.assumeIsolated {
                owner?.restart()
            }
        }
    }

    // MARK: - HAL helpers

    private enum TapError: LocalizedError {
        case status(String, OSStatus)
        case unsupportedFormat
        case noOutputDevice

        var errorDescription: String? {
            switch self {
            case let .status(call, status): "\(call) failed (\(status))"
            case .unsupportedFormat: "Unsupported tap format"
            case .noOutputDevice: "No default output device"
            }
        }
    }

    private static func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw TapError.status(call, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func getProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "AudioObjectGetPropertyData")
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object
        )
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.noOutputDevice }
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "kAudioDevicePropertyDeviceUID")
        guard let value = uid?.takeRetainedValue() else { throw TapError.noOutputDevice }
        return value as String
    }
}
