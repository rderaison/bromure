// Isolated feasibility probe: read-only guest disk, no network, no renderer.
import Foundation
import Virtualization

@available(macOS 27.0, *)
final class GPUDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    let index: Int
    init(_ index: Int) { self.index = index }
    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self; print("GPU \(index) CREATED")
    }
    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) { print("GPU \(index) DRIVER_OK") }
    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        while let element = queue.nextElement() {
            defer { element.returnToQueue() }
            guard queue.queueIndex == 0, (24...65536).contains(element.readBuffersAvailableByteCount),
                  let request = try? element.readBytes(withExactLength: element.readBuffersAvailableByteCount) else { continue }
            let kind = request.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            var response = Data(request.prefix(24))
            let status: UInt32 = kind == 0x100 && request.count == 24 ? 0x1101 : 0x1200
            for i in 0..<4 { response[i] = UInt8((status >> (8*i)) & 255) }
            response[4] &= 1
            for i in [5,6,7,20,21,22,23] { response[i] = 0 }
            if status == 0x1101 { response.append(Data(repeating: 0, count: 384)) }
            if response.count <= element.writeBuffersAvailableByteCount { try? element.write(response) }
        }
    }
}
@available(macOS 27.0, *)
func validateCounts() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    for count in [2,4,8,16,24,32,48,64,128,256] {
        let config = VZVirtualMachineConfiguration()
        let loader = VZLinuxBootLoader(kernelURL: root.appendingPathComponent("vmlinuz"))
        loader.initialRamdiskURL = root.appendingPathComponent("initrd")
        config.bootLoader = loader; config.platform = VZGenericPlatformConfiguration()
        config.cpuCount = 2; config.memorySize = 2 * 1024 * 1024 * 1024
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: root.appendingPathComponent("linux-base.img"), readOnly: true))]
        let native = VZVirtioGraphicsDeviceConfiguration()
        native.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels:960,heightInPixels:540)]
        config.graphicsDevices = [native]
        let delegates = (0..<count).map { GPUDelegate($0) }
        config.customVirtioDevices = delegates.map { delegate in
            let gpu = VZCustomVirtioDeviceConfiguration()
            gpu.deviceID = 16; gpu.pciClassID = 3; gpu.pciSubclassID = 0; gpu.virtioQueueCount = 2
            gpu.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Data([0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0]))
            gpu.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: DispatchQueue(label:"io.bromure.count.\(delegate.index)"), delegate: delegate)
            return gpu
        }
        do { try config.validate(); print("GPU_COUNT \(count) VALID") }
        catch { print("GPU_COUNT \(count) REJECTED \(error)") }
        withExtendedLifetime(delegates) {}
    }
}
setbuf(stdout,nil)
if #available(macOS 27.0, *) { do { try validateCounts() } catch { print(error);exit(1) } } else { exit(1) }
