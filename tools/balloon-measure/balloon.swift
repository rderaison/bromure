import Foundation
import Virtualization
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments; let dir = a[1], cmdExtra = a[2]; let memGB = UInt64(a[3])!; let scenario = a[4]
func sh(_ c: String) -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", c]; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: d, as: UTF8.self) }
func helpers() -> Set<Int32> { Set(sh("pgrep -f com.apple.Virtualization.VirtualMachine").split(separator: "\n").compactMap { Int32($0) }) }
let before = helpers()
let cfg = VZVirtualMachineConfiguration()
let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: dir + "/Image")); boot.initialRamdiskURL = URL(fileURLWithPath: dir + "/initrd.gz"); boot.commandLine = "console=hvc0 rdinit=/init loglevel=3 " + cmdExtra
cfg.bootLoader = boot; cfg.cpuCount = 4; cfg.memorySize = memGB << 30
let toG = Pipe(), fromG = Pipe()
let con = VZVirtioConsoleDeviceSerialPortConfiguration(); con.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: toG.fileHandleForReading, fileHandleForWriting: fromG.fileHandleForWriting)
cfg.serialPorts = [con]; cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]; cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
try! cfg.validate()
let vm = VZVirtualMachine(configuration: cfg)
var lines: [String] = []; let lock = NSLock(); var buf = Data()
fromG.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); buf.append(d); while let i = buf.firstIndex(of: 10) { let l = String(decoding: buf[buf.startIndex..<i], as: UTF8.self); buf = Data(buf[buf.index(after: i)...]); lines.append(l); print("  guest| \(l)") }; lock.unlock() }
func wait(_ tok: String, _ t: Double = 120) { let e = Date().addingTimeInterval(t); while Date() < e { lock.lock(); let i = lines.firstIndex { $0.contains(tok) }; if let i { lines.removeSubrange(0...i); lock.unlock(); return }; lock.unlock(); usleep(100000) }; print("TIMEOUT \(tok)") }
func send(_ c: String) { toG.fileHandleForWriting.write(Data((c + "\n").utf8)); wait("DONE", 300) }
var helper: Int32 = 0
func rss(_ label: String) { let r = sh("ps -o rss= -p \(helper)").trimmingCharacters(in: .whitespacesAndNewlines); let f = sh("footprint \(helper) 2>/dev/null | grep -iE 'phys_footprint:' | head -1").trimmingCharacters(in: .whitespacesAndNewlines); print(String(format: "HOST %-34@ rss=%6d MB  %@", label as NSString, (Int(r) ?? 0)/1024, f)) }
func target(_ gb: Double) { DispatchQueue.main.sync { (vm.memoryBalloonDevices.first as! VZVirtioTraditionalMemoryBalloonDevice).targetVirtualMachineMemorySize = UInt64(gb * 1073741824) & ~UInt64(0xFFFFF) } ; print("HOST balloon target -> \(gb) GB") }
DispatchQueue.main.async { vm.start { r in if case .failure(let e) = r { print("start failed \(e)"); exit(1) } } }
DispatchQueue.global().async {
  wait("READY", 60); usleep(500000); helper = helpers().subtracting(before).first ?? 0; print("HOST helper pid \(helper)")
  let settle: UInt32 = 20
  rss("booted")
  if scenario == "cold" {
    target(1); sleep(settle); send("mem"); rss("cold inflate to 1G +20s")
    target(Double(memGB)); sleep(settle); send("mem"); rss("deflate +20s")
  }
  let t = Int(memGB) * 1024 * 3 / 4
  send("touch \(t)"); rss("guest touched \(t) MB")
  send("free"); sleep(5); rss("guest freed +5s")
  target(1); sleep(settle); send("mem"); rss("inflate to 1G +20s"); sleep(40); rss("inflate +60s")
  target(Double(memGB)); sleep(settle); send("mem"); rss("deflate +20s")
  send("touch 1024"); rss("guest touched 1G after deflate"); send("free")
  target(1); sleep(settle); rss("inflate again +20s")
  target(Double(memGB)); sleep(5)
  print("HOST END"); DispatchQueue.main.async { exit(0) }
}
RunLoop.main.run()
