// SDK feasibility probe only: does not boot a guest or enable acceleration.
// Compile with SDK 27 while retaining the app's macOS 14 deployment target:
// xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path /tmp/bromure-gpu-modules tools/gpu/validate-custom-virtio.swift -o /tmp/bromure-gpu-probe
// codesign --force --sign - --entitlements tools/gpu/probe.entitlements /tmp/bromure-gpu-probe
import Foundation
import Virtualization

@available(macOS 27.0, *)
final class ProbeDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate {}

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
    let gpu = VZCustomVirtioDeviceConfiguration()
    gpu.deviceID = 16
    gpu.pciClassID = 3
    gpu.pciSubclassID = 0
    gpu.virtioQueueCount = 2
    // virtio_gpu_config: events_read, events_clear, num_scanouts, num_capsets.
    // One scanout, no 3D capsets; the probe does not advertise VIRGL support.
    gpu.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
        configurationData: Data([0,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,0,0]))
    gpu.provider = VZCustomVirtioDeviceDelegateProvider(
        deviceQueue: DispatchQueue(label: "io.bromure.gpu-probe"), delegate: delegate)
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = boot
    config.platform = VZGenericPlatformConfiguration()
    config.cpuCount = 2
    config.memorySize = 512 * 1024 * 1024
    config.customVirtioDevices = [gpu]
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
