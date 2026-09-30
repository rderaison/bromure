// SDK/guest-binding feasibility probe only: never enables acceleration.
// Compile with SDK 27 while retaining the app's macOS 14 deployment target:
// bash tools/gpu/build-transport-probe.sh
import Foundation
import Virtualization

@available(macOS 27.0, *)
final class ProbeDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    var renderer: RendererControlBridge?
    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration,
                                  didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
        print("DEVICE CREATED")
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        print("DRIVER_OK: guest completed feature negotiation")
        for index: UInt16 in [0, 1] {
            if let queue = device.queue(at: index) {
                print("QUEUE READY \(index): size \(queue.queueSize)")
            }
        }
        // This address was checked against /proc/iomem on the probe VM.
        // It is a probe constant, never a production guest-memory assumption.
        if let mapping = device.guestMemoryMapping(atPhysicalAddress: 0x70000000, length: 4096),
           mapping.length == 4096 {
            // Read once into host-owned memory; do not print guest contents or
            // retain the mapping across reset, stop, or reboot.
            let snapshot = Data(bytes: mapping.mutableBytes, count: mapping.length)
            print("RAM MAPPING: copied \(snapshot.count) bytes from probe RAM base")
        } else { print("RAM MAPPING: unavailable at probe RAM base") }
        print("INVALID MAPPING REJECTED: \(device.guestMemoryMapping(atPhysicalAddress: UInt64.max - 4095, length: 4096) == nil)")
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice,
                           didReceiveNotificationFor queue: VZVirtioQueue) {
        while let element = queue.nextElement() {
            defer { element.returnToQueue() }
            // A bounded immutable copy, never repeated reads of guest metadata.
            let count = element.readBuffersAvailableByteCount
            guard count >= 24, count <= 65536 else {
                print("REJECT descriptor length \(count)")
                continue
            }
            var failureHeader: Data?
            do {
                let command = try element.readBytes(withExactLength: count)
                failureHeader = Data(command.prefix(24))
                let type = command.prefix(4).enumerated().reduce(UInt32(0)) {
                    $0 | (UInt32($1.element) << ($1.offset * 8))
                }
                print("QUEUE \(queue.queueIndex) command 0x\(String(type, radix: 16)) bytes \(count)")
                // This binding probe exposes no usable displays or 3D support.
                // GET_DISPLAY_INFO returns sixteen disabled scanouts. All other
                // control commands receive ERR_UNSPEC; cursor has no response.
                guard queue.queueIndex == 0 else { continue }
                if let renderer, [UInt32(0x100), 0x102, 0x106, 0x107, 0x108, 0x109, 0x200, 0x201, 0x202, 0x203, 0x204, 0x205, 0x206, 0x207].contains(type) {
                    let response = try renderer.forward(command, readGuest: { address, count in
                        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: count),
                              mapping.length == count else { throw NSError(domain: "GuestMapping", code: 1) }
                        return Data(bytes: mapping.mutableBytes, count: count)
                    }, writeGuest: { address, data in
                        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: data.count),
                              mapping.length == data.count else { throw NSError(domain: "GuestMapping", code: 1) }
                        data.withUnsafeBytes { bytes in mapping.mutableBytes.copyMemory(from: bytes.baseAddress!, byteCount: data.count) }
                    })
                    guard response.count <= element.writeBuffersAvailableByteCount else {
                        print("REJECT renderer response buffer too short"); continue
                    }
                    try element.write(response)
                    print("HELPER RESPONSE 0x\(String(get32(response, at: 0), radix: 16)) bytes \(response.count)")
                    continue
                }
                var response = Data(command.prefix(24))
                let responseType: UInt32 = type == 0x100 && count == 24 ? 0x1101 : 0x1200
                for index in 0..<4 { response[index] = UInt8((responseType >> (index * 8)) & 255) }
                response[4] &= 1 // Echo only the fence flag and its ID.
                response[5] = 0; response[6] = 0; response[7] = 0
                response[20] = 0; response[21] = 0; response[22] = 0; response[23] = 0
                if responseType == 0x1101 { response.append(Data(repeating: 0, count: 384)) }
                guard response.count <= element.writeBuffersAvailableByteCount else {
                    print("REJECT response buffer too short")
                    continue
                }
                try element.write(response)
            } catch {
                print("QUEUE ERROR: \(error)")
                if var response = failureHeader, element.writeBuffersAvailableByteCount >= 24 {
                    put32(0x1200, at: 0, into: &response)
                    put32(get32(response, at: 4) & 1, at: 4, into: &response)
                    put32(0, at: 20, into: &response)
                    try? element.write(response)
                }
            }
        }
    }

    func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) { print("DEVICE PAUSE") }
    func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) { print("DEVICE RESUME") }
    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        print("DEVICE RESET")
        do { try renderer?.reset() }
        catch { print("HELPER RESET FAILED: \(error)"); renderer?.stop() }
    }
    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        print("DEVICE STOP"); renderer?.stop()
    }
}

// Retain both objects throughout an asynchronous boot probe.
@available(macOS 27.0, *)
enum BootLifetime {
    static var vm: VZVirtualMachine?
    static var delegate: ProbeDelegate?
}

@available(macOS 27.0, *)
func probe() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bromure-gpu-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let boot = VZEFIBootLoader()
    boot.variableStore = try VZEFIVariableStore(
        creatingVariableStoreAt: directory.appendingPathComponent("efi-vars"))
    let delegate = ProbeDelegate()
    let arguments = CommandLine.arguments
    if arguments.count == 5, arguments[3] == "--renderer-helper" {
        delegate.renderer = try RendererControlBridge(executable: arguments[4])
        print("HELPER READY: isolated control plane; no rendered scanout or Chromium")
    }
    let gpu = VZCustomVirtioDeviceConfiguration()
    gpu.deviceID = 16
    gpu.pciClassID = 3
    gpu.pciSubclassID = 0
    gpu.virtioQueueCount = 2
    if delegate.renderer != nil { gpu.optionalFeatures.subset0 |= 1 }
    // virtio_gpu_config: events_read, events_clear, num_scanouts, num_capsets.
    // One scanout, no 3D capsets; the probe does not advertise VIRGL support.
    gpu.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
        configurationData: Data([0,0,0,0, 0,0,0,0, 1,0,0,0, delegate.renderer == nil ? 0 : 2,0,0,0]))
    gpu.provider = VZCustomVirtioDeviceDelegateProvider(
        deviceQueue: DispatchQueue(label: "io.bromure.gpu-probe"), delegate: delegate)
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = boot
    config.platform = VZGenericPlatformConfiguration()
    config.cpuCount = 2
    config.memorySize = 512 * 1024 * 1024
    config.customVirtioDevices = [gpu]
    if [3, 5].contains(arguments.count), arguments[1] == "--boot-image" {
        let image = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let linux = VZLinuxBootLoader(kernelURL: image.appendingPathComponent("vmlinuz"))
        linux.initialRamdiskURL = image.appendingPathComponent("initrd")
        linux.commandLine = "console=hvc0 root=/dev/vda ro init=/bin/sh"
        config.bootLoader = linux
        config.memorySize = 2 * 1024 * 1024 * 1024
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment:
            try VZDiskImageStorageDeviceAttachment(url: image.appendingPathComponent("linux-base.img"), readOnly: true))]
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
        config.serialPorts = [console]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try config.validate()
        BootLifetime.delegate = delegate
        let vm = VZVirtualMachine(configuration: config)
        BootLifetime.vm = vm
        vm.start { result in
            switch result {
            case .success:
                print("VM STARTED: read-only disk, no networking, no graphics presentation")
                for delay in [15.0, 30.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        vm.pause { result in
                            switch result {
                            case .success:
                                print("VM PAUSED")
                                vm.resume { result in
                                    switch result {
                                    case .success: print("VM RESUMED")
                                    case .failure(let error):
                                        fputs("RESUME FAILED: \(error)\n", stderr); exit(1)
                                    }
                                }
                            case .failure(let error):
                                fputs("PAUSE FAILED: \(error)\n", stderr); exit(1)
                            }
                        }
                    }
                }
            case .failure(let error): fputs("BOOT FAILED: \(error)\n", stderr); exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            vm.stop { error in
                if let error { fputs("STOP FAILED: \(error)\n", stderr) }
                else { print("VM STOPPED") }
                exit(error == nil ? 0 : 1)
            }
        }
        RunLoop.main.run()
        return
    }
    try config.validate()
    print("PASS: custom Virtio GPU ID 16, PCI 03:00, two queues accepted by VZ configuration validation")
    print("NOT TESTED: guest binding, queues, capsets, mappings, rendering, scanout or lifecycle")
    withExtendedLifetime(delegate) {}
}

do {
    if #available(macOS 27.0, *) {
        try probe()
    } else {
        print("SKIP: custom Virtio requires macOS 27; legacy backend remains required")
    }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
