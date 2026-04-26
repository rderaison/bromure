import AVFoundation
import CoreAudio
import Foundation
import SandboxEngine

/// Represents a selectable media device (camera or microphone).
public struct MediaDevice: Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Helpers for enumerating and selecting audio/video devices.
public enum MediaDevices {
    /// Returns all available cameras.
    public static func cameras() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Returns all available audio input devices (microphones).
    public static func microphones() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Returns all available audio output devices (speakers).
    public static func speakers() -> [MediaDevice] {
        var devices = [MediaDevice]()
        let audioDevices = allAudioDeviceIDs()

        for devID in audioDevices {
            // Check if device has output channels
            var outputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var propSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(devID, &outputAddr, 0, nil, &propSize) == noErr,
                  propSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propSize))
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(devID, &outputAddr, 0, nil, &propSize, bufferListPtr) == noErr else { continue }

            let channelCount = UnsafeMutableAudioBufferListPointer(bufferListPtr).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channelCount > 0 else { continue }

            if let uid = deviceUID(devID), let name = deviceName(devID) {
                devices.append(MediaDevice(id: uid, name: name))
            }
        }
        return devices
    }

    /// Set the system default audio input device.
    public static func setDefaultAudioInput(deviceID: String) {
        setDefaultAudioDevice(deviceID: deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Set the system default audio output device.
    public static func setDefaultAudioOutput(deviceID: String) {
        setDefaultAudioDevice(deviceID: deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Private

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceList = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceList)
        return deviceList
    }

    private static func deviceUID(_ devID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeUnretainedValue() else { return nil }
        return value as String
    }

    private static func deviceName(_ devID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeUnretainedValue() else { return nil }
        return value as String
    }

    private static func setDefaultAudioDevice(deviceID: String, selector: AudioObjectPropertySelector) {
        let deviceList = allAudioDeviceIDs()
        for devID in deviceList {
            guard let uid = deviceUID(devID), uid == deviceID else { continue }
            var mutableDevID = devID
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &mutableDevID
            )
            return
        }
    }
}
