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
func run() throws {
    guard (2...3).contains(CommandLine.arguments.count) else { throw NSError(domain: "Pass image directory", code: 1) }
    let root=URL(fileURLWithPath: CommandLine.arguments[1])
    let loader=VZLinuxBootLoader(kernelURL: root.appendingPathComponent("vmlinuz"))
    loader.initialRamdiskURL=root.appendingPathComponent("initrd")
    loader.commandLine="console=hvc0 root=/dev/vda ro init=/bin/sh"
    let config=VZVirtualMachineConfiguration();config.bootLoader=loader;config.platform=VZGenericPlatformConfiguration()
    config.cpuCount=2;config.memorySize=2*1024*1024*1024
    config.storageDevices=[VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url:root.appendingPathComponent("linux-base.img"),readOnly:true))]
    let count = CommandLine.arguments.count == 3 ? Int(CommandLine.arguments[2]) ?? 0 : 2
    guard (2...256).contains(count) else { throw NSError(domain: "GPU count must be 2 through 256", code: 1) }
    let delegates=(0..<count).map { GPUDelegate($0) }
    config.customVirtioDevices=delegates.map { delegate in
        let gpu=VZCustomVirtioDeviceConfiguration();gpu.deviceID=16;gpu.pciClassID=3;gpu.pciSubclassID=0;gpu.virtioQueueCount=2
        gpu.deviceSpecificConfiguration=VZVirtioDeviceSpecificConfiguration(configurationData:Data([0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0]))
        gpu.provider=VZCustomVirtioDeviceDelegateProvider(deviceQueue:DispatchQueue(label:"io.bromure.multigpu.\(delegate.index)"),delegate:delegate)
        return gpu
    }
    let native=VZVirtioGraphicsDeviceConfiguration()
    native.scanouts=[VZVirtioGraphicsScanoutConfiguration(widthInPixels:960,heightInPixels:540),VZVirtioGraphicsScanoutConfiguration(widthInPixels:800,heightInPixels:600)]
    config.graphicsDevices=[native]
    do { try config.validate();print("TWO_CUSTOM_PLUS_NATIVE_TWO_SCANOUTS VALID") }
    catch { print("NATIVE_TWO_SCANOUTS REJECTED: \(error)");config.graphicsDevices=[];try config.validate();print("CUSTOM_GPU_COUNT \(count) VALID") }
    let input=Pipe(),output=Pipe()
    output.fileHandleForReading.readabilityHandler={ handle in
        let data=handle.availableData;if !data.isEmpty { FileHandle.standardOutput.write(data) }
    }
    let console=VZVirtioConsoleDeviceSerialPortConfiguration()
    console.attachment=VZFileHandleSerialPortAttachment(fileHandleForReading:input.fileHandleForReading,fileHandleForWriting:output.fileHandleForWriting)
    config.serialPorts=[console];config.entropyDevices=[VZVirtioEntropyDeviceConfiguration()];try config.validate()
    let vm=VZVirtualMachine(configuration:config)
    vm.start { result in
        print("BOOT \(result)")
        if case .failure = result { exit(2) }
        DispatchQueue.main.asyncAfter(deadline:.now()+20) {
            let command="mount -t proc proc /proc; mount -t sysfs sysfs /sys; echo MULTIGPU_GUEST_BEGIN; modprobe virtio_gpu; ls -l /sys/class/drm; for d in /sys/bus/virtio/devices/*; do echo $d; cat $d/device; done; dmesg | grep -E 'virtio_gpu|drm'; echo MULTIGPU_GUEST_END\n"
            input.fileHandleForWriting.write(Data(command.utf8))
        }
    }
    let deadline=Date().addingTimeInterval(45)
    while Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
    withExtendedLifetime((vm,delegates,input,output)) {}
}
setbuf(stdout,nil)
if #available(macOS 27.0, *) { do { try run() } catch { print(error);exit(1) } } else { print("Requires macOS 27");exit(1) }
