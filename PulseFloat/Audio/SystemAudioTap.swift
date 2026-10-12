import AudioToolbox
import QuartzCore
import CoreAudio
import Foundation
import OSLog
import PulseFloatCore

/// 用 Core Audio Process Tap 擷取「全部系統音訊（排除自己）」，降成單聲道寫進 `SampleRingBuffer`。
/// 流程：CATapDescription → AudioHardwareCreateProcessTap → 只含這個 tap 的私有 aggregate device
/// → IOProc → AudioDeviceStart。預設輸出裝置改變時整條重建。只在主執行緒呼叫。
///
/// aggregate device 只放 tap、不放任何實體裝置：早期版本把預設輸出（例如 AirPods）當主子裝置，連它的麥克風輸入
/// 也一起被打開，macOS 會把 AirPods 當成「Mac 正在使用（含收音）」而鎖在 Mac 上，iPhone 按播放時搶不走。
/// 權限：系統在第一次 AudioDeviceStart 時詢問；被拒時 tap 只送全 0 的 buffer（由 LiveSpectrumSource 當成靜音處理）。
///
/// 閒置時釋放：沒有其他程序輸出聲音超過幾秒就把整條擷取拆掉（不留任何 tap 或 IO），有程序開始輸出時
/// （預設輸出裝置的 IsRunningSomewhere 通知，加上每 0.5 秒輪詢）再重建。閒置時畫面本來就是靜止的，所以看不出差別。
@MainActor
final class SystemAudioTap {
    enum State: Equatable {
        case stopped
        /// 沒有其他程序在輸出聲音：已釋放輸出裝置，等聲音出現再接上。
        case idle
        case running(sampleRate: Double)
        case failed(String)
    }

    /// 沒有聲音 3 秒後釋放輸出裝置；啟動失敗後 5 秒內不重試。
    private var gate = CaptureGate(releaseDelay: 3, retryDelay: 5)

    private(set) var state: State = .stopped
    /// 每次（重新）啟動成功後回報 tap 的取樣率（Hz）。
    var onFormatChange: ((Double) -> Void)?

    private let ring: SampleRingBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var runningListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var activityTimer: Timer?
    private var lastFailure: CFTimeInterval?
    private var writtenAtStart = 0
    private var loggedDelivery = false
    private let logger = Logger(subsystem: "com.victorhuang.PulseFloat", category: "audio")

    init(ring: SampleRingBuffer) {
        self.ring = ring
    }

    /// 開始監聽；有聲音時才建立擷取（見型別說明的「閒置時釋放」）。失敗時記錄在 `state`。
    func start() {
        installOutputListener()
        installRunningListener()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            // 計時器加在主執行緒的 run loop，可同步進入 MainActor。
            MainActor.assumeIsolated { self?.evaluateActivity() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
        evaluateActivity()
    }

    /// 停止擷取、移除監聽並釋放所有 Core Audio 物件。
    func stop() {
        activityTimer?.invalidate()
        activityTimer = nil
        removeRunningListener()
        removeOutputListener()
        teardown()
        state = .stopped
    }

    private func restart() {
        logger.info("Default output device changed; rebuilding tap")
        teardown()
        removeRunningListener()
        installRunningListener()
        gate.reset()
        lastFailure = nil
        evaluateActivity()
    }

    private var isCapturing: Bool { aggregateID != AudioObjectID(kAudioObjectUnknown) }

    /// 有其他程序在輸出聲音就接上；連續幾秒都沒有就釋放輸出裝置（決策在 `CaptureGate`）。
    private func evaluateActivity() {
        let ownPID = getpid()
        let others = AudioProcessList.outputtingProcesses().contains { $0.pid != ownPID }
        switch gate.evaluate(othersOutputting: others, isCapturing: isCapturing, now: CACurrentMediaTime(), lastFailure: lastFailure) {
        case .start:
            startChain()
        case .release:
            teardown()
            state = .idle
            logger.info("No audio output for \(self.gate.releaseDelay, privacy: .public) s; released the output device")
        case .none:
            if isCapturing, !loggedDelivery, ring.totalWritten > writtenAtStart {
                loggedDelivery = true
                logger.info("Tap is delivering audio (\(self.ring.totalWritten - self.writtenAtStart, privacy: .public) samples)")
            }
            if !isCapturing, case .running = state { state = .idle }
            if !isCapturing, state == .stopped { state = .idle }
        }
    }

    private func startChain() {
        do {
            let sampleRate = try buildChain()
            state = .running(sampleRate: sampleRate)
            lastFailure = nil
            writtenAtStart = ring.totalWritten
            loggedDelivery = false
            onFormatChange?(sampleRate)
            logger.info("System audio tap running at \(sampleRate, privacy: .public) Hz")
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
            lastFailure = CACurrentMediaTime()
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

        // 只放 tap，不放任何實體裝置（見型別說明）：時脈來自 tap 本身。
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PulseFloat Tap",
            kAudioAggregateDeviceUIDKey: "com.victorhuang.PulseFloat.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: false,
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

    // MARK: - 預設輸出裝置開始有人使用

    /// 閒置時，預設輸出裝置的 IsRunningSomewhere 變成 true 代表有 App 開始播放：立刻接上，不必等輪詢。
    private func installRunningListener() {
        guard runningListener == nil, let device = try? Self.defaultOutputDeviceID() else { return }
        let listener = Self.makeRunningListener(owner: self)
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, listener) == noErr {
            runningListener = listener
            runningListenerDevice = device
        }
    }

    private func removeRunningListener() {
        guard let runningListener else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(runningListenerDevice, &address, DispatchQueue.main, runningListener)
        self.runningListener = nil
        runningListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// listener 註冊在 main queue，所以可以同步進入 MainActor。
    private nonisolated static func makeRunningListener(owner: SystemAudioTap) -> AudioObjectPropertyListenerBlock {
        { [weak owner] _, _ in
            MainActor.assumeIsolated {
                owner?.evaluateActivity()
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

    private static func defaultOutputDeviceID() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.noOutputDevice }
        return device
    }
}
