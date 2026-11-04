import Foundation
import Virtualization
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments; let dir = a[1], cmdExtra = a[2]; let memGB = UInt64(a[3])!
func sh(_ c: String) -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", c]; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: d, as: UTF8.self) }
func helpers() -> Set<Int32> { Set(sh("pgrep -f com.apple.Virtualization.VirtualMachine").split(separator: "\n").compactMap { Int32($0) }) }
let midURL = URL(fileURLWithPath: dir + "/sr/mid"); let restoring = a.count > 4
let mid: VZGenericMachineIdentifier = restoring ? VZGenericMachineIdentifier(dataRepresentation: try! Data(contentsOf: midURL))! : VZGenericMachineIdentifier()
if !restoring { try! mid.dataRepresentation.write(to: midURL) }
var toG = Pipe(), fromG = Pipe()
func makeCfg() -> VZVirtualMachineConfiguration {
  let cfg = VZVirtualMachineConfiguration(); let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: dir + "/Image")); boot.initialRamdiskURL = URL(fileURLWithPath: dir + "/initrd.gz"); boot.commandLine = "console=hvc0 rdinit=/init loglevel=3 " + cmdExtra
  cfg.bootLoader = boot; cfg.cpuCount = 4; cfg.memorySize = memGB << 30
  let pf = VZGenericPlatformConfiguration(); pf.machineIdentifier = mid; cfg.platform = pf
  let con = VZVirtioConsoleDeviceSerialPortConfiguration(); con.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: toG.fileHandleForReading, fileHandleForWriting: fromG.fileHandleForWriting)
  cfg.serialPorts = [con]; cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]; cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]; return cfg }
var lines: [String] = []; let lock = NSLock(); var buf = Data()
func listen() { fromG.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); buf.append(d); while let i = buf.firstIndex(of: 10) { let l = String(decoding: buf[buf.startIndex..<i], as: UTF8.self); buf = Data(buf[buf.index(after: i)...]); lines.append(l); print("  guest| \(l)") }; lock.unlock() } }
func wait(_ tok: String, _ t: Double = 120) { let e = Date().addingTimeInterval(t); while Date() < e { lock.lock(); let i = lines.firstIndex { $0.contains(tok) }; if let i { lines.removeSubrange(0...i); lock.unlock(); return }; lock.unlock(); usleep(100000) }; print("TIMEOUT \(tok)") }
func send(_ c: String) { toG.fileHandleForWriting.write(Data((c + "\n").utf8)); wait("DONE", 300) }
var helper: Int32 = 0
func rss(_ label: String) { let r = sh("ps -o rss= -p \(helper)").trimmingCharacters(in: .whitespacesAndNewlines); print(String(format: "HOST %-34@ rss=%6d MB", label as NSString, (Int(r) ?? 0)/1024)) }
let save = URL(fileURLWithPath: dir + "/sr/state.vzvmsave")
let before = helpers()
listen(); let c1 = makeCfg(); try! c1.validate(); try! c1.validateSaveRestoreSupport()
let vm = VZVirtualMachine(configuration: c1)
func onMain(_ f: @escaping (@escaping () -> Void) -> Void) { let s = DispatchSemaphore(value: 0); DispatchQueue.main.async { f { s.signal() } }; s.wait() }
DispatchQueue.global().async {
 if restoring {
  let t1 = Date()
  onMain { d in vm.restoreMachineStateFrom(url: save) { e in if let e { print("restore \(e)"); exit(1) }; vm.resume { _ in d() } } }
  print("HOST restored+resumed in \(Int(Date().timeIntervalSince(t1)))s"); usleep(800000); helper = helpers().subtracting(before).first ?? 0
  rss("after restore"); sleep(10); rss("restore +10s")
  send("mem"); rss("guest ran mem"); send("touch 1024"); rss("touched 1 GB"); send("free"); rss("freed")
  try? FileManager.default.removeItem(at: save)
 } else {
  onMain { d in vm.start { r in if case .failure(let e) = r { print("start \(e)"); exit(1) }; d() } }
  wait("READY", 60); usleep(500000); helper = helpers().subtracting(before).first ?? 0; rss("booted")
  send("touch 3072"); rss("touched 3072 MB"); send("free"); rss("freed")
  let t0 = Date()
  onMain { d in vm.pause { _ in d() } }
  onMain { d in vm.saveMachineStateTo(url: save) { e in if let e { print("save \(e)") }; d() } }
  let sz = (try? FileManager.default.attributesOfItem(atPath: save.path)[.size] as? Int) ?? 0
  print("HOST saved \(sz/1048576) MB in \(Int(Date().timeIntervalSince(t0)))s")
  onMain { d in vm.stop { _ in d() } }
 }
 print("HOST END"); DispatchQueue.main.async { exit(0) } }
RunLoop.main.run()
