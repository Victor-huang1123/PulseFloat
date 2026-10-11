import CoreAudio
import Foundation

/// 用 Core Audio 的程序物件（macOS 14.2+，不需額外權限）列出目前正在輸出聲音的程序。
/// 只讀 HAL 屬性，呼叫很快、不會跳出權限詢問；不綁 actor。
enum AudioProcessList {
    /// 一個正在輸出聲音的程序。
    struct Process: Equatable, Sendable {
        let pid: pid_t
        /// Core Audio 回報的 bundle id；沒有 bundle 的命令列程式是空字串。
        let bundleID: String
    }

    /// 目前 kAudioProcessPropertyIsRunningOutput 為真的程序；查詢失敗時回傳空陣列。
    static func outputtingProcesses() -> [Process] {
        let objects = processObjects()
        var result: [Process] = []
        var index = 0
        while index < objects.count {
            let object = objects[index]
            index += 1
            var running: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningOutput, into: &running), running != 0 else { continue }
            var pid: pid_t = -1
            guard read(object, kAudioProcessPropertyPID, into: &pid), pid > 0 else { continue }
            result.append(Process(pid: pid, bundleID: bundleID(of: object) ?? ""))
        }
        return result
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        let capacity = Int(size) / stride
        guard capacity > 0 else { return [] }
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: capacity)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        // 兩次呼叫之間程序可能結束，實際筆數以第二次回傳的 size 為準。
        return Array(objects.prefix(min(capacity, Int(size) / stride)))
    }

    /// kAudioProcessPropertyBundleID 回傳 retained 的 CFString，由呼叫端釋放。
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
