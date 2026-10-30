# ACCore census

Generated from `linux/census/census.py` at 38a0ef14, on 2026-10-30T18:19:24Z (`Swift version 6.4 (swift-6.4-RELEASE)`). The JSON is `linux/accore-census.json`.

It covers every file under `Sources/{SandboxEngine,BrowserBridges,AgentCoding}` that portmap doesn't skip outright. **Tiers come from actually typechecking on Linux** (`swiftc -typecheck`, Swift 5 mode), iterated to a fixed point. A file is in a tier only if it typechecks together with the other files of that tier and its dependencies' modules:

- **A**: typechecks as-is.
- **B**: typechecks with the census shims: `os`/`OSLog` to a stub `Logger`, `CryptoKit` to swift-crypto, `Darwin` to Glibc, `SQLite3` to a system module map, and an implicit `FoundationNetworking` for URLSession types. In the real carve-out these are `#if canImport` lines or a tiny shared logging/crypto shim.
- **C**: doesn't. The cause is one of:
  - `apple-import`: VZ, AppKit/SwiftUI, Security, Network, Combine, Compression and so on;
  - `depends-on-C`: it would compile, but uses a type that lives in a C file (`blockedBy`);
  - `linux-portability`: its own Linux error, such as Glibc socket constants being enums.

## Summary

| module | files | A | B | C: apple-import | C: depends-on-C | C: linux-portability | lines A+B |
|---|---|---|---|---|---|---|---|
| SandboxEngine | 67 | 12 | 2 | 29 | 18 | 6 | 1719 |
| BrowserBridges | 17 | 0 | 0 | 17 | 0 | 0 | 0 |
| AgentCoding (bromure_ac) | 279 | 54 | 19 | 84 | 90 | 32 | 18589 |

**Most of C is the cascade, not the platform:** `depends-on-C` files would compile once their blocker moves or is split. The roots with the largest unlock potential (direct plus transitive dependents) are:

| root (C) | cause | unlocks | example dependents |
|---|---|---|---|
| `SandboxEngine/VMConfig.swift` | apple-import: imports AppKit, Virtualization | **25** | `AgentConfigScan.swift`, `AutomationRunArchive.swift`, `BootsInFlight.swift`, `CodingTasks.swift` |
| `SandboxEngine/OpenShellPolicy+MCP.swift` | linux-portability: Sources/SandboxEngine/OpenShellPolicy+MCP.swift:252: cannot find 'CFGetTypeID' in scope | **14** | `EgressConnectionRegistry.swift`, `MitmPassthrough.swift`, `UpstreamPinning.swift`, `OpenShellAdvisor.swift` |
| `AgentCoding/CloudUploader.swift` | apple-import: imports Security | **9** | `AgentWatchdog.swift`, `CloudEvents.swift`, `AWSResigner.swift`, `CommandLineRedactor.swift` |
| `SandboxEngine/CloudTraceUploader.swift` | apple-import: imports Security | **6** | `EngineModelMeta.swift`, `ExternalEngine.swift`, `InferenceRepairProxy.swift`, `LocalStreamEmitter.swift` |
| `SandboxEngine/LinuxImageManager.swift` | apple-import: imports CommonCrypto, Virtualization | **4** | `ImageCatalogAC.swift`, `SentryModuleStore.swift`, `ImageCatalog.swift`, `Provisioner.swift` |
| `AgentCoding/Mitm/ConsentBroker.swift` | apple-import: imports AppKit | **4** | `AWSCredentialServer.swift`, `CredentialMint.swift`, `SSHAgent.swift`, `TokenSwap.swift` |
| `AgentCoding/FatClientTypes.swift` | linux-portability: Sources/AgentCoding/FatClientTypes.swift:146: cannot find type 'OSStatus' in scope | **4** | `DeviceChannel.swift`, `PortMap.swift`, `TurnRelayTransport.swift`, `RequestLedger.swift` |
| `AgentCoding/AgentSessions.swift` | apple-import: imports SwiftUI | **3** | `AutomationServer.swift`, `DelegationEngine.swift`, `MachineLinks.swift` |
| `AgentCoding/Enrollment.swift` | apple-import: imports Security | **3** | `EnrollmentCLI.swift`, `ControlPlaneClient.swift`, `P2PIdentity.swift` |
| `AgentCoding/P2P/P2PCandidate.swift` | linux-portability: Sources/AgentCoding/P2P/P2PCandidate.swift:107: binary operator '&' cannot be applied to o | **3** | `P2PSignaling.swift`, `TurnTCP.swift`, `TurnUDP.swift` |
| `AgentCoding/TaskBoardMCPServer.swift` | apple-import: imports Virtualization | **2** | `AutomationMCPServer.swift`, `DelegationMCPServer.swift` |
| `AgentCoding/CLIModelCommands.swift` | apple-import: imports MLXLLM, MLXLMCommon, MLXHuggingFace, Tokenizers | **2** | `CLICommands.swift`, `ModelDownloadManager.swift` |
| `AgentCoding/ConfigScan.swift` | apple-import: imports Security | **2** | `ConfigFileSanitize.swift`, `GitConfigParse.swift` |
| `AgentCoding/Inference/ModelCatalog.swift` | linux-portability: Sources/AgentCoding/Inference/ModelCatalog.swift:196: cannot find 'acResourceBundle' in sc | **2** | `CatalogStore.swift`, `ModelDownloader.swift` |
| `AgentCoding/Profile.swift` | apple-import: imports AppKit | **2** | `KubeconfigImport.swift`, `GuardrailsPolicy.swift` |

## Apple-only usage by family (non-skipped files)

| family | files | sites |
|---|---|---|
| URLSession (needs FoundationNetworking) | 44 | 305 |
| Virtualization (VZ) | 43 | 586 |
| AppKit/UI | 39 | 543 |
| SwiftUI | 17 | 216 |
| Security keys/certs/trust | 14 | 82 |
| Keychain (SecItem) | 14 | 283 |
| Combine | 6 | 14 |
| FSEvents/kqueue/XPC/IOKit | 5 | 27 |
| ProcessInfo/Foundation gaps | 5 | 14 |
| Network.framework | 3 | 13 |
| vmnet | 3 | 42 |
| os logging | 2 | 2 |
| AppleScript | 1 | 8 |
| SecureTransport | 1 | 26 |
| ServiceManagement/notifications | 1 | 5 |

## The three areas phases 3, 4 and image management wait on

### Switch (VMNetSwitch and friends)

VMNetSwitch's frame logic (MAC learning, DHCP, DNS snoop, the interceptor hook) is what the Linux StreamPort/uplink plug into. Its blockers are the vmnet uplink (`CVmnet`, `vmnet_*`) and the VZ socketpair ports. The carve is: switch core in ACCore behind a `NetworkUplink`/`SwitchPort` protocol pair, with vmnet and VZ attachments staying in the macOS target.

| file | tier | cause / shims | Apple-only sites (family: count) | functions with them |
|---|---|---|---|---|
| `SandboxEngine/VMNetSwitch.swift` | **C** | apple-import: imports CVmnet, Virtualization | FSEvents/kqueue/XPC/IOKit: 6; vmnet: 13 | `VMNetSwitch.drainVmnetToVMs()`, `VMNetSwitch.startVmnetLocked()`, `VMNetSwitch.startVmnetReadCallback()`, `VMNetSwitch.writeToVmnet(_: UnsafeMutablePointer<UInt8>, _: Int)` |
| `SandboxEngine/DNSSnoop.swift` | **A** | as-is | – | – |
| `SandboxEngine/DHCPLeaseStore.swift` | **B** | shims: sqlite3 | – | – |
| `SandboxEngine/EgressPolicy.swift` | **C** | depends-on-C: Sources/SandboxEngine/EgressPolicy.swift:196: cannot find type 'OpenSh | – | – |
| `SandboxEngine/NetworkFilter.swift` | **C** | apple-import: imports CVmnet, Virtualization | FSEvents/kqueue/XPC/IOKit: 8; vmnet: 16 | `NetworkFilter.drainVmnetToVM()`, `NetworkFilter.readVMLoop()`, `NetworkFilter.startProxy()`, `NetworkFilter.startVmnet()`, `NetworkFilter.stop()` |
| `SandboxEngine/LANTap.swift` | **C** | apple-import: imports CVmnet | FSEvents/kqueue/XPC/IOKit: 5; vmnet: 13 | `LANTap.drain()`, `LANTap.init(interfaceName: String, onFrame: @escaping([UInt8])->Void)`, `LANTap.stop()`, `LANTap.write(_: [UInt8])` |
| `SandboxEngine/VmnetSubnet.swift` | **C** | depends-on-C: Sources/SandboxEngine/VmnetSubnet.swift:88: cannot find type 'HostNetw | – | – |
| `SandboxEngine/HostNetworkInfo.swift` | **C** | apple-import: imports SystemConfiguration | – | – |
| `SandboxEngine/HostNetworkWatcher.swift` | **C** | apple-import: imports Network | Network.framework: 2 | `HostNetworkWatcher.static identity(of: NWPath)` |
| `SandboxEngine/NetworkHealer.swift` | **A** | as-is | – | – |
| `SandboxEngine/OpenShellPolicy+Destination.swift` | **C** | depends-on-C: Sources/SandboxEngine/OpenShellPolicy+Destination.swift:14: cannot fin | – | – |
| `AgentCoding/SwitchMitmForwarder.swift` | **C** | depends-on-C: Sources/AgentCoding/SwitchMitmForwarder.swift:16: cannot find type 'VM | – | – |

### MITM engine (HTTPProxy and the swaps)

The TLS legs (`TLSServerStream` on SecureTransport, `CertCache` on SecIdentity, `BromureCA` on Security keys) are the Security-framework core; they map to the spike's NIOSSL + swift-certificates pieces behind a `TLSStreamFactory`. The policy and rewrite files around them are mostly pure logic. Their C status is largely `depends-on-C` (on `Profile`, `HTTPProxy` types, `ConsentBroker`'s AppKit) rather than platform calls of their own.

| file | tier | cause / shims | Apple-only sites (family: count) | functions with them |
|---|---|---|---|---|
| `AgentCoding/Mitm/HTTPProxy.swift` | **C** | apple-import: imports Compression, Virtualization | URLSession (needs FoundationNetworking): 28 | `ClientCertChallengeDelegate.urlSession(_: URLSession, didBecomeInvalidWithError: Error?)`, `ClientCertChallengeDelegate.urlSession(_: URLSession, didReceive: URLAuthenticationChallenge, completionHandler: @escaping(URLSession.AuthChallengeDisposition,
URLCredential?)->Void)`, `HTTPMitmConnection.driveTLS(host: String, port: Int, t0: Date, cleartext: Bool, prefix: Data)`, `HTTPMitmConnection.noteUpstreamSession(_: URLSession)`, `HTTPMitmConnection.upstreamSession(for: String, port: Int, insecure: Bool)`, `StreamingRelayDelegate.init(onHead: @escaping@Sendable(HTTPURLResponse)->Void, onChunk: @escaping@Sendable(Data)->Void, onComplete: @escaping@Sendable(Error?)->Void)` … +7 |
| `AgentCoding/Mitm/MitmEngine.swift` | **C** | apple-import: imports Virtualization | Virtualization (VZ): 21 | `AWSCredsListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice)`, `HTTPListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice)`, `MitmEngine.register(socketDevice: VZVirtioSocketDevice, profileID: UUID)`, `SSHListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice)` |
| `AgentCoding/Mitm/TokenSwap.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/TokenSwap.swift:168: cannot find type 'Consen | – | – |
| `AgentCoding/Mitm/SessionTokenPlan.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/SessionTokenPlan.swift:363: cannot find type  | – | – |
| `AgentCoding/Mitm/TLSServerStream.swift` | **C** | apple-import: imports Security | SecureTransport: 26; Security keys/certs/trust: 5 | `TLSClientStream.deinit`, `TLSClientStream.evaluatePinnedServerTrust()`, `TLSClientStream.handshake()`, `TLSClientStream.init(fd: Int32, peerName: String, clientIdentity: SecIdentity?, pinnedCA: SecCertificate?)`, `TLSClientStream.read(maxBytes: Int)`, `TLSClientStream.readNB(maxBytes: Int)` … +9 |
| `AgentCoding/Mitm/TLSClientHello.swift` | **B** | shims: darwin | – | – |
| `AgentCoding/Mitm/CertCache.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/CertCache.swift:10: cannot find type 'Bromure | Keychain (SecItem): 5; Security keys/certs/trust: 9 | `CertCache.identity(for: String)`, `CertCache.mint(for: String)` |
| `AgentCoding/Mitm/BromureCA.swift` | **C** | linux-portability: Sources/AgentCoding/Mitm/BromureCA.swift:28: cannot find type 'SecCert | Keychain (SecItem): 5; Security keys/certs/trust: 9 | `BromureCA.init(certificate: Certificate, privateKey: P256.Signing.PrivateKey, certificatePEM: String, secCertificate: SecCertificate, secPrivateKey: SecKey)`, `BromureCA.static makeSecPair(cert: Certificate, key: P256.Signing.PrivateKey)`, `MitmError.var description` |
| `AgentCoding/Mitm/MitmPassthrough.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/MitmPassthrough.swift:71: cannot find type 'O | – | – |
| `AgentCoding/Mitm/UpstreamPinning.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/UpstreamPinning.swift:12: cannot find type 'O | – | – |
| `AgentCoding/Mitm/SigV4Signer.swift` | **A** | as-is | – | – |
| `AgentCoding/Mitm/AWSResigner.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/AWSResigner.swift:223: cannot find 'BACEventE | – | – |
| `AgentCoding/Mitm/CredentialMint.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/CredentialMint.swift:512: cannot find type 'A | – | – |
| `AgentCoding/Mitm/GuardrailsPolicy.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/GuardrailsPolicy.swift:201: cannot find type  | – | – |
| `AgentCoding/Mitm/SquelchRewriter.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/SquelchRewriter.swift:206: cannot find 'JSONS | – | – |
| `AgentCoding/Mitm/SquelchFilter.swift` | **A** | as-is | – | – |
| `AgentCoding/Mitm/PIIRewriter.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/PIIRewriter.swift:23: cannot find type 'Exter | – | – |
| `AgentCoding/Mitm/PIIDetector.swift` | **C** | apple-import: imports OnnxRuntimeBindings | – | – |
| `AgentCoding/Mitm/SupplyChainEnforcer.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/SupplyChainEnforcer.swift:131: cannot find 'D | – | – |
| `AgentCoding/Mitm/SupplyChainPolicy.swift` | **A** | as-is | – | – |
| `AgentCoding/Mitm/TraceStore.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/TraceStore.swift:265: cannot find 'SecretsVau | – | – |
| `AgentCoding/Mitm/TraceRecord.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/TraceRecord.swift:50: cannot find 'InferenceS | – | – |
| `AgentCoding/Mitm/SecretsVault.swift` | **C** | apple-import: imports Security | Keychain (SecItem): 18 | `SecretsVault.static fetchFromKeychain()`, `SecretsVault.static storeInKeychain(_: SymmetricKey)` |
| `AgentCoding/Mitm/EcosystemTransforms.swift` | **A** | as-is | – | – |
| `AgentCoding/Mitm/NPMRegistryTransforms.swift` | **C** | apple-import: imports Compression | – | – |
| `AgentCoding/Mitm/WebSocketTrace.swift` | **C** | apple-import: imports Compression | – | – |
| `AgentCoding/Mitm/EgressConnectionRegistry.swift` | **C** | depends-on-C: Sources/AgentCoding/Mitm/EgressConnectionRegistry.swift:31: cannot fin | – | – |

### Image management

UbuntuImageManager mixes the bake *logic* (catalog, downloads, the serial dialogue, version stamps) with VZ (`VZVirtualMachine` provisioner) and CommonCrypto (SHA-256). The carve is: bake logic in ACCore against a `ProvisionerVM` protocol (linux/bake's QEMU dialogue is the Linux side), with hashing on swift-crypto.

| file | tier | cause / shims | Apple-only sites (family: count) | functions with them |
|---|---|---|---|---|
| `AgentCoding/UbuntuImageManager.swift` | **C** | apple-import: imports AppKit, CommonCrypto, Virtualization | AppKit/UI: 1; URLSession (needs FoundationNetworking): 2; Virtualization (VZ): 32 | `UbuntuImageManager.createBaseImage(progress: @escaping(String)->Void, output: @escaping(String)->Void, force: Bool, postinstallSteps: [PostinstallStep])`, `UbuntuImageManager.runProvisioner(environment: InstallerEnvironment, stage: String, runLabel: String, setupShare: URL?, targetDisk: URL?, script: String, scriptArgs: String, extraShares: [(tag:String,url:URL,readOnly:Bool)], successMarker: String, failureMarker: String, markerTimeout: TimeInterval, hardTimeout: TimeInterval, progress: @escaping(String)->Void, output: @escaping(String)->Void)`, `UbuntuImageManager.static detectDisplayScale()`, `UbuntuImageManager.static downloadFile(from: URL, to: URL)`, `UbuntuImageManager.static forceStop(_: VZVirtualMachine)`, `UbuntuImageManager.verifyImageBoots(diskURL: URL, timeout: TimeInterval, progress: @escaping(String)->Void, output: @escaping(String)->Void)` |
| `SandboxEngine/ImageFetch.swift` | **C** | apple-import: imports CommonCrypto | URLSession (needs FoundationNetworking): 6 | `LargeFileDownloader.run(from: URL)`, `LargeFileDownloader.urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo: URL)`, `LargeFileDownloader.urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64)`, `LargeFileDownloader.urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError: Error?)` |
| `SandboxEngine/ImageCatalog.swift` | **C** | depends-on-C: Sources/SandboxEngine/ImageCatalog.swift:328: cannot find 'LinuxImageM | URLSession (needs FoundationNetworking): 3 | `ImageCatalogStore.refresh(from: URL?, session: URLSession)` |
| `SandboxEngine/Provisioner.swift` | **C** | depends-on-C: Sources/SandboxEngine/Provisioner.swift:37: cannot find 'LinuxImageMan | – | – |
| `SandboxEngine/InitrdShim.swift` | **A** | as-is | – | – |
| `SandboxEngine/LinuxImageManager.swift` | **C** | apple-import: imports CommonCrypto, Virtualization | URLSession (needs FoundationNetworking): 6; Virtualization (VZ): 57 | `DownloadDelegate.finish(_: URLSession, result: Result<Void,Error>)`, `DownloadDelegate.urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo: URL)`, `DownloadDelegate.urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64)`, `DownloadDelegate.urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError: Error?)`, `LinuxImageManager.buildLinuxVMConfig(diskURL: URL, config: VMConfig, readOnlyDisk: Bool, networkAttachment: VZNetworkDeviceAttachment?, macAddress: String?)`, `LinuxImageManager.downloadFile(from: URL, to: URL, progress: @escaping(ProgressEvent)->Void)` … +2 |
| `SandboxEngine/Ext4.swift` | (skipped by portmap) | | | |

## Proposed move order (leaf-first; each step keeps macOS green)

A and B files, ordered by the type-reference graph (SCCs together; SandboxEngine before AgentCoding). Each step moves a set whose dependencies already moved. **Moving files out of `bromure_ac`, an executable target, means making the API they expose to the app `public`**; that is the main mechanical cost per step. B files need their shim lines in the same step.

1. `SandboxEngine/DHCPLeaseStore.swift`ᴮ, `SandboxEngine/DNSSnoop.swift`, `SandboxEngine/InitrdShim.swift`, `SandboxEngine/MACAddressPool.swift`, `SandboxEngine/ManagedProfile.swift`, `SandboxEngine/NetworkHealer.swift`, `SandboxEngine/OpenShellHTTP.swift`, `SandboxEngine/OpenShellPolicy+RegoGlob.swift`, `SandboxEngine/ProfilePrefs.swift`, `SandboxEngine/ProgressEvent.swift`, `SandboxEngine/SandboxEngine.swift`, `SandboxEngine/SandboxError.swift`, `SandboxEngine/VPNConnectionState.swift`
2. `SandboxEngine/ManagedProfileClient.swift`ᴮ
3. `AgentCoding/AWSConfigParser.swift`, `AgentCoding/AgentDetection.swift`, `AgentCoding/AgentScreen.swift`, `AgentCoding/BACDebug.swift`, `AgentCoding/BootLaunchAgent.swift`, `AgentCoding/DefaultSSHKey.swift`, `AgentCoding/DelegationFallbacks.swift`, `AgentCoding/DelegationMCPCatalog.swift`, `AgentCoding/DelegationShimCalls.swift`, `AgentCoding/DiskSpace.swift`, `AgentCoding/DockerConfigImport.swift`, `AgentCoding/Ext4/Crc32c.swift`, `AgentCoding/FDGuard.swift`ᴮ, `AgentCoding/FatClient.swift`, `AgentCoding/GuestCommandEncoding.swift`, `AgentCoding/GuestURLGate.swift`ᴮ, `AgentCoding/Inference/AskArgsNormalizer.swift`, `AgentCoding/Inference/EngineKey.swift`ᴮ, `AgentCoding/Inference/ToolCallRepair.swift`, `AgentCoding/KubeLANAnnouncer.swift`ᴮ, `AgentCoding/Mitm/AWSHosts.swift`, `AgentCoding/Mitm/ConsentCredentialID.swift`, `AgentCoding/Mitm/MitmBlockingExecutor.swift`, `AgentCoding/Mitm/OnePasswordCLI.swift`, `AgentCoding/Mitm/PrivateSSHAgent.swift`, `AgentCoding/Mitm/SecretFingerprint.swift`ᴮ, `AgentCoding/Mitm/SquelchFilter.swift`, `AgentCoding/Mitm/TLSClientHello.swift`ᴮ, `AgentCoding/Mitm/UnmanagedCredentialGuard.swift`ᴮ, `AgentCoding/Mitm/Zstd.swift`, `AgentCoding/P2P/STUN.swift`ᴮ, `AgentCoding/PolicyHistory.swift`ᴮ, `AgentCoding/PushCrypto.swift`, `AgentCoding/QuitDeadline.swift`, `AgentCoding/RepoGitPrograms.swift`, `AgentCoding/SubscriptionTokenSwapState.swift`, `AgentCoding/SwitchboardBrief.swift`, `AgentCoding/TUI.swift`ᴮ, `AgentCoding/TaskTranscriptArchive.swift`, `AgentCoding/WorkspaceLease.swift`ᴮ
4. `AgentCoding/BranchMergeCommands.swift`, `AgentCoding/ClaudeAutoMode.swift`, `AgentCoding/Ext4/Ext4Volume.swift`ᴮ, `AgentCoding/Inference/LogBuffer.swift`, `AgentCoding/KubeCluster.swift`, `AgentCoding/Mitm/PIIText.swift`, `AgentCoding/Mitm/PublishTimeCache.swift`, `AgentCoding/Mitm/SignInCapture.swift`, `AgentCoding/Mitm/SquelchCLI.swift`, `AgentCoding/Mitm/SupplyChainLog.swift`, `AgentCoding/QuitFlow.swift`, `AgentCoding/SessionStartCoalescer.swift`, `AgentCoding/TaskDispatch.swift`, `AgentCoding/TranscriptSearchIndex.swift`
5. `AgentCoding/Ext4/Ext4Journal.swift`ᴮ, `AgentCoding/Ext4/Ext4Writer.swift`ᴮ, `AgentCoding/KubeEmulatorReleases.swift`ᴮ, `AgentCoding/KubeMCPServer.swift`, `AgentCoding/KubeRegistryEngine.swift`, `AgentCoding/MessagingConnectorEngine.swift`, `AgentCoding/Mitm/CompromiseDetector.swift`, `AgentCoding/Mitm/EcosystemTransforms.swift`, `AgentCoding/Mitm/OSVClient.swift`ᴮ, `AgentCoding/Mitm/PIIPolicy.swift`, `AgentCoding/Mitm/PromptInjectionPolicy.swift`, `AgentCoding/Mitm/PyPIMetadataClient.swift`ᴮ, `AgentCoding/Mitm/SigV4Signer.swift`, `AgentCoding/Mitm/SquelchPolicy.swift`, `AgentCoding/Mitm/SupplyChainPolicy.swift`, `AgentCoding/Switchboard.swift`
6. `AgentCoding/Ext4/Ext4Fsck.swift`ᴮ, `AgentCoding/Mitm/SocketDevClient.swift`ᴮ, `AgentCoding/SwitchboardMCPServer.swift`

(ᴮ = needs shims.) After these, the unlock table above is the next work: splitting `VMConfig`'s data from its VZ half, and `Profile`'s `toVMConfig`/UserDefaults edges, moves the largest dependent group.

## Per file

| file | module | lines | tier | cause / shims | blocked by | todo/skipped entries |
|---|---|---|---|---|---|---|
| `BrowserBridges/CDPBridge.swift` | BrowserBridges | 105 | C | apple-import: imports Virtualization |  | 7/0 |
| `BrowserBridges/CDPWheelInjector.swift` | BrowserBridges | 464 | C | apple-import: imports Virtualization |  | 23/0 |
| `BrowserBridges/CJKInputBridge.swift` | BrowserBridges | 413 | C | apple-import: imports AppKit, Carbon, Virtualization |  | 11/20 |
| `BrowserBridges/CredentialBridge.swift` | BrowserBridges | 692 | C | apple-import: imports AppKit, AuthenticationServices, Virtualization |  | 22/0 |
| `BrowserBridges/FaceSwapEngine.swift` | BrowserBridges | 1071 | C | apple-import: imports Accelerate, CoreGraphics, ImageIO, OnnxRuntimeBindin |  | 38/0 |
| `BrowserBridges/FilePickerBridge.swift` | BrowserBridges | 371 | C | apple-import: imports AppKit, UniformTypeIdentifiers, Virtualization |  | 17/0 |
| `BrowserBridges/GestureBridge.swift` | BrowserBridges | 131 | C | apple-import: imports AppKit, Virtualization |  | 5/0 |
| `BrowserBridges/LinkSenderBridge.swift` | BrowserBridges | 160 | C | apple-import: imports Virtualization |  | 8/0 |
| `BrowserBridges/MediaDevices.swift` | BrowserBridges | 141 | C | apple-import: imports AVFoundation, CoreAudio |  | 10/0 |
| `BrowserBridges/PasskeyProvider.swift` | BrowserBridges | 182 | C | apple-import: imports AppKit, AuthenticationServices |  | 6/0 |
| `BrowserBridges/PhishingAnalysisBridge.swift` | BrowserBridges | 349 | C | apple-import: imports Virtualization |  | 12/0 |
| `BrowserBridges/PrecisionScrollBridge.swift` | BrowserBridges | 319 | C | apple-import: imports AppKit, Virtualization |  | 13/0 |
| `BrowserBridges/TabBridge.swift` | BrowserBridges | 733 | C | apple-import: imports AppKit, Virtualization |  | 45/0 |
| `BrowserBridges/VirusTotalClient.swift` | BrowserBridges | 360 | C | apple-import: imports CommonCrypto |  | 16/0 |
| `BrowserBridges/WarpBridge.swift` | BrowserBridges | 284 | C | apple-import: imports Virtualization |  | 16/0 |
| `BrowserBridges/WebcamBridge.swift` | BrowserBridges | 819 | C | apple-import: imports AVFoundation, CoreGraphics, Virtualization |  | 27/0 |
| `BrowserBridges/iCloudPasswordsBridge.swift` | BrowserBridges | 905 | C | apple-import: imports AppKit, CommonCrypto |  | 35/0 |
| `SandboxEngine/DNSSnoop.swift` | SandboxEngine | 146 | A | as-is |  | 5/0 |
| `SandboxEngine/InitrdShim.swift` | SandboxEngine | 204 | A | as-is |  | 3/0 |
| `SandboxEngine/MACAddressPool.swift` | SandboxEngine | 124 | A | as-is |  | 7/0 |
| `SandboxEngine/ManagedProfile.swift` | SandboxEngine | 148 | A | as-is |  | 5/0 |
| `SandboxEngine/NetworkHealer.swift` | SandboxEngine | 99 | A | as-is |  | 2/0 |
| `SandboxEngine/OpenShellHTTP.swift` | SandboxEngine | 248 | A | as-is |  | 10/0 |
| `SandboxEngine/OpenShellPolicy+RegoGlob.swift` | SandboxEngine | 237 | A | as-is |  | 7/0 |
| `SandboxEngine/ProfilePrefs.swift` | SandboxEngine | 55 | A | as-is |  | 6/0 |
| `SandboxEngine/ProgressEvent.swift` | SandboxEngine | 23 | A | as-is |  | 0/0 |
| `SandboxEngine/SandboxEngine.swift` | SandboxEngine | 15 | A | as-is |  | 1/0 |
| `SandboxEngine/SandboxError.swift` | SandboxEngine | 43 | A | as-is |  | 1/0 |
| `SandboxEngine/VPNConnectionState.swift` | SandboxEngine | 28 | A | as-is |  | 1/0 |
| `SandboxEngine/DHCPLeaseStore.swift` | SandboxEngine | 106 | B | sqlite3 |  | 7/0 |
| `SandboxEngine/ManagedProfileClient.swift` | SandboxEngine | 243 | B | FoundationNetworking, crypto |  | 11/0 |
| `SandboxEngine/AlpinePackageProxy.swift` | SandboxEngine | 699 | C | linux-portability: Sources/SandboxEngine/AlpinePackageProxy.swift:109: cannot c |  | 22/0 |
| `SandboxEngine/BaseImageManager.swift` | SandboxEngine | 412 | C | apple-import: imports Virtualization |  | 16/0 |
| `SandboxEngine/BrowserInstallProgress.swift` | SandboxEngine | 209 | C | linux-portability: Sources/SandboxEngine/BrowserInstallProgress.swift:118: no e |  | 10/0 |
| `SandboxEngine/CloudTraceUploader.swift` | SandboxEngine | 547 | C | apple-import: imports Security |  | 22/0 |
| `SandboxEngine/CuratedExtensions.swift` | SandboxEngine | 9 | C | depends-on-C | `SandboxEngine/Profile.swift` | 0/0 |
| `SandboxEngine/EgressPolicy.swift` | SandboxEngine | 744 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 47/0 |
| `SandboxEngine/EphemeralDisk.swift` | SandboxEngine | 160 | C | apple-import: imports Virtualization |  | 8/0 |
| `SandboxEngine/ExtensionCache.swift` | SandboxEngine | 127 | C | depends-on-C | `SandboxEngine/VMConfig.swift` | 12/0 |
| `SandboxEngine/FileTransferBridge.swift` | SandboxEngine | 345 | C | apple-import: imports Virtualization |  | 13/0 |
| `SandboxEngine/HostNetworkInfo.swift` | SandboxEngine | 124 | C | apple-import: imports SystemConfiguration |  | 5/0 |
| `SandboxEngine/HostNetworkWatcher.swift` | SandboxEngine | 153 | C | apple-import: imports Network |  | 11/0 |
| `SandboxEngine/IKEv2Bridge.swift` | SandboxEngine | 267 | C | apple-import: imports Virtualization |  | 16/0 |
| `SandboxEngine/ImageCatalog.swift` | SandboxEngine | 522 | C | depends-on-C | `SandboxEngine/LinuxImageManager.swift` | 28/0 |
| `SandboxEngine/ImageFetch.swift` | SandboxEngine | 280 | C | apple-import: imports CommonCrypto |  | 10/0 |
| `SandboxEngine/InstallIdentity.swift` | SandboxEngine | 233 | C | apple-import: imports Security |  | 20/0 |
| `SandboxEngine/LANTap.swift` | SandboxEngine | 134 | C | apple-import: imports CVmnet |  | 8/0 |
| `SandboxEngine/LinuxImageManager+Remote.swift` | SandboxEngine | 850 | C | apple-import: imports Virtualization |  | 21/0 |
| `SandboxEngine/LinuxImageManager.swift` | SandboxEngine | 1194 | C | apple-import: imports CommonCrypto, Virtualization |  | 41/0 |
| `SandboxEngine/LinuxSandboxVM.swift` | SandboxEngine | 212 | C | apple-import: imports Virtualization |  | 14/0 |
| `SandboxEngine/MTLSReloadBridge.swift` | SandboxEngine | 135 | C | apple-import: imports Virtualization |  | 7/0 |
| `SandboxEngine/ManagedBundleCrypto.swift` | SandboxEngine | 167 | C | linux-portability: Sources/SandboxEngine/ManagedBundleCrypto.swift:63: cannot f |  | 6/0 |
| `SandboxEngine/ManagedProfileStore.swift` | SandboxEngine | 199 | C | depends-on-C | `SandboxEngine/VMConfig.swift` | 16/0 |
| `SandboxEngine/ManagedProfileSync.swift` | SandboxEngine | 408 | C | depends-on-C | `SandboxEngine/InstallIdentity.swift` | 17/0 |
| `SandboxEngine/NetworkFilter.swift` | SandboxEngine | 768 | C | apple-import: imports CVmnet, Virtualization |  | 22/0 |
| `SandboxEngine/NetworkRefreshBridge.swift` | SandboxEngine | 146 | C | apple-import: imports Virtualization |  | 8/0 |
| `SandboxEngine/OpenShellBoundary.swift` | SandboxEngine | 198 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 11/0 |
| `SandboxEngine/OpenShellMCPParams.swift` | SandboxEngine | 1082 | C | linux-portability: Sources/SandboxEngine/OpenShellMCPParams.swift:158: cannot f |  | 38/0 |
| `SandboxEngine/OpenShellPolicy+Ambiguity.swift` | SandboxEngine | 235 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 17/0 |
| `SandboxEngine/OpenShellPolicy+Destination.swift` | SandboxEngine | 358 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 25/0 |
| `SandboxEngine/OpenShellPolicy+L7.swift` | SandboxEngine | 442 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 20/0 |
| `SandboxEngine/OpenShellPolicy+MCP.swift` | SandboxEngine | 568 | C | linux-portability: Sources/SandboxEngine/OpenShellPolicy+MCP.swift:252: cannot  |  | 22/0 |
| `SandboxEngine/OpenShellPolicy+Parse.swift` | SandboxEngine | 862 | C | linux-portability: Sources/SandboxEngine/OpenShellPolicy+Parse.swift:717: type  |  | 33/0 |
| `SandboxEngine/OpenShellPolicy+YAML.swift` | SandboxEngine | 203 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 5/0 |
| `SandboxEngine/OpenShellPolicy.swift` | SandboxEngine | 1039 | C | depends-on-C | `SandboxEngine/OpenShellPolicy+MCP.swift` | 54/0 |
| `SandboxEngine/OpenShellSandboxSpec.swift` | SandboxEngine | 143 | C | depends-on-C | `SandboxEngine/EgressPolicy.swift` | 9/0 |
| `SandboxEngine/OpenShellWebSocket.swift` | SandboxEngine | 402 | C | apple-import: imports Compression |  | 13/0 |
| `SandboxEngine/OpenVPNBridge.swift` | SandboxEngine | 267 | C | apple-import: imports Virtualization |  | 16/0 |
| `SandboxEngine/PKCS12Builder.swift` | SandboxEngine | 385 | C | apple-import: imports CommonCrypto, Security |  | 18/0 |
| `SandboxEngine/Profile.swift` | SandboxEngine | 683 | C | depends-on-C | `SandboxEngine/VMConfig.swift` | 21/0 |
| `SandboxEngine/ProfileDisk.swift` | SandboxEngine | 155 | C | apple-import: imports Security |  | 9/0 |
| `SandboxEngine/ProfileManager.swift` | SandboxEngine | 372 | C | depends-on-C | `SandboxEngine/VMConfig.swift` | 23/0 |
| `SandboxEngine/Provisioner.swift` | SandboxEngine | 92 | C | depends-on-C | `SandboxEngine/LinuxImageManager.swift` | 2/0 |
| `SandboxEngine/SandboxVM.swift` | SandboxEngine | 193 | C | apple-import: imports Virtualization |  | 12/0 |
| `SandboxEngine/ShellBridge.swift` | SandboxEngine | 106 | C | apple-import: imports Virtualization |  | 2/0 |
| `SandboxEngine/TraceBridge.swift` | SandboxEngine | 259 | C | apple-import: imports Virtualization |  | 15/0 |
| `SandboxEngine/TraceStore.swift` | SandboxEngine | 636 | C | depends-on-C | `SandboxEngine/TraceBridge.swift` | 32/0 |
| `SandboxEngine/VMAutoSuspend.swift` | SandboxEngine | 337 | C | apple-import: imports AppKit, Virtualization |  | 17/0 |
| `SandboxEngine/VMConfig.swift` | SandboxEngine | 1146 | C | apple-import: imports AppKit, Virtualization |  | 19/0 |
| `SandboxEngine/VMNetSwitch.swift` | SandboxEngine | 1609 | C | apple-import: imports CVmnet, Virtualization |  | 79/0 |
| `SandboxEngine/VMPool.swift` | SandboxEngine | 1443 | C | apple-import: imports AppKit, Virtualization |  | 39/0 |
| `SandboxEngine/VPNKeychain.swift` | SandboxEngine | 81 | C | apple-import: imports Security |  | 4/0 |
| `SandboxEngine/VmnetSubnet.swift` | SandboxEngine | 147 | C | depends-on-C | `SandboxEngine/HostNetworkInfo.swift` | 13/0 |
| `SandboxEngine/WireGuardBridge.swift` | SandboxEngine | 284 | C | apple-import: imports Virtualization |  | 16/0 |
| `AgentCoding/AWSConfigParser.swift` | bromure_ac | 137 | A | as-is |  | 6/0 |
| `AgentCoding/AgentDetection.swift` | bromure_ac | 98 | A | as-is |  | 6/0 |
| `AgentCoding/AgentScreen.swift` | bromure_ac | 1236 | A | as-is |  | 53/0 |
| `AgentCoding/BACDebug.swift` | bromure_ac | 35 | A | as-is |  | 2/0 |
| `AgentCoding/BootLaunchAgent.swift` | bromure_ac | 61 | A | as-is |  | 4/0 |
| `AgentCoding/BranchMergeCommands.swift` | bromure_ac | 133 | A | as-is |  | 11/0 |
| `AgentCoding/ClaudeAutoMode.swift` | bromure_ac | 53 | A | as-is |  | 3/0 |
| `AgentCoding/DefaultSSHKey.swift` | bromure_ac | 120 | A | as-is |  | 8/0 |
| `AgentCoding/DelegationFallbacks.swift` | bromure_ac | 48 | A | as-is |  | 6/0 |
| `AgentCoding/DelegationMCPCatalog.swift` | bromure_ac | 182 | A | as-is |  | 0/0 |
| `AgentCoding/DelegationShimCalls.swift` | bromure_ac | 107 | A | as-is |  | 9/0 |
| `AgentCoding/DiskSpace.swift` | bromure_ac | 42 | A | as-is |  | 2/0 |
| `AgentCoding/DockerConfigImport.swift` | bromure_ac | 139 | A | as-is |  | 5/0 |
| `AgentCoding/Ext4/Crc32c.swift` | bromure_ac | 32 | A | as-is |  | 2/0 |
| `AgentCoding/FatClient.swift` | bromure_ac | 111 | A | as-is |  | 5/0 |
| `AgentCoding/GuestCommandEncoding.swift` | bromure_ac | 126 | A | as-is |  | 4/0 |
| `AgentCoding/Inference/AskArgsNormalizer.swift` | bromure_ac | 105 | A | as-is |  | 3/0 |
| `AgentCoding/Inference/LogBuffer.swift` | bromure_ac | 115 | A | as-is |  | 8/0 |
| `AgentCoding/Inference/ToolCallRepair.swift` | bromure_ac | 711 | A | as-is |  | 21/0 |
| `AgentCoding/KubeCluster.swift` | bromure_ac | 1463 | A | as-is |  | 131/0 |
| `AgentCoding/KubeMCPServer.swift` | bromure_ac | 480 | A | as-is |  | 18/0 |
| `AgentCoding/KubeRegistryEngine.swift` | bromure_ac | 182 | A | as-is |  | 10/0 |
| `AgentCoding/MessagingConnectorEngine.swift` | bromure_ac | 651 | A | as-is |  | 37/0 |
| `AgentCoding/Mitm/AWSHosts.swift` | bromure_ac | 31 | A | as-is |  | 1/0 |
| `AgentCoding/Mitm/CompromiseDetector.swift` | bromure_ac | 129 | A | as-is |  | 2/0 |
| `AgentCoding/Mitm/ConsentCredentialID.swift` | bromure_ac | 20 | A | as-is |  | 12/0 |
| `AgentCoding/Mitm/EcosystemTransforms.swift` | bromure_ac | 432 | A | as-is |  | 9/0 |
| `AgentCoding/Mitm/MitmBlockingExecutor.swift` | bromure_ac | 83 | A | as-is |  | 3/0 |
| `AgentCoding/Mitm/OnePasswordCLI.swift` | bromure_ac | 92 | A | as-is |  | 5/0 |
| `AgentCoding/Mitm/PIIPolicy.swift` | bromure_ac | 60 | A | as-is |  | 4/0 |
| `AgentCoding/Mitm/PIIText.swift` | bromure_ac | 687 | A | as-is |  | 30/0 |
| `AgentCoding/Mitm/PrivateSSHAgent.swift` | bromure_ac | 132 | A | as-is |  | 3/0 |
| `AgentCoding/Mitm/PromptInjectionPolicy.swift` | bromure_ac | 74 | A | as-is |  | 5/0 |
| `AgentCoding/Mitm/PublishTimeCache.swift` | bromure_ac | 48 | A | as-is |  | 3/0 |
| `AgentCoding/Mitm/SigV4Signer.swift` | bromure_ac | 305 | A | as-is |  | 12/0 |
| `AgentCoding/Mitm/SignInCapture.swift` | bromure_ac | 73 | A | as-is |  | 5/0 |
| `AgentCoding/Mitm/SquelchCLI.swift` | bromure_ac | 30 | A | as-is |  | 1/0 |
| `AgentCoding/Mitm/SquelchFilter.swift` | bromure_ac | 664 | A | as-is |  | 53/0 |
| `AgentCoding/Mitm/SquelchPolicy.swift` | bromure_ac | 78 | A | as-is |  | 13/0 |
| `AgentCoding/Mitm/SupplyChainLog.swift` | bromure_ac | 89 | A | as-is |  | 5/0 |
| `AgentCoding/Mitm/SupplyChainPolicy.swift` | bromure_ac | 346 | A | as-is |  | 13/0 |
| `AgentCoding/Mitm/Zstd.swift` | bromure_ac | 783 | A | as-is |  | 29/0 |
| `AgentCoding/PushCrypto.swift` | bromure_ac | 52 | A | as-is |  | 3/0 |
| `AgentCoding/QuitDeadline.swift` | bromure_ac | 98 | A | as-is |  | 5/0 |
| `AgentCoding/QuitFlow.swift` | bromure_ac | 84 | A | as-is |  | 2/0 |
| `AgentCoding/RepoGitPrograms.swift` | bromure_ac | 128 | A | as-is |  | 3/0 |
| `AgentCoding/SessionStartCoalescer.swift` | bromure_ac | 159 | A | as-is |  | 11/0 |
| `AgentCoding/SubscriptionTokenSwapState.swift` | bromure_ac | 20 | A | as-is |  | 0/0 |
| `AgentCoding/Switchboard.swift` | bromure_ac | 871 | A | as-is |  | 49/0 |
| `AgentCoding/SwitchboardBrief.swift` | bromure_ac | 109 | A | as-is |  | 1/0 |
| `AgentCoding/SwitchboardMCPServer.swift` | bromure_ac | 416 | A | as-is |  | 8/0 |
| `AgentCoding/TaskDispatch.swift` | bromure_ac | 771 | A | as-is |  | 39/0 |
| `AgentCoding/TaskTranscriptArchive.swift` | bromure_ac | 55 | A | as-is |  | 6/0 |
| `AgentCoding/TranscriptSearchIndex.swift` | bromure_ac | 437 | A | as-is |  | 29/0 |
| `AgentCoding/Ext4/Ext4Fsck.swift` | bromure_ac | 290 | B | as-is |  | 9/0 |
| `AgentCoding/Ext4/Ext4Journal.swift` | bromure_ac | 352 | B | as-is |  | 19/0 |
| `AgentCoding/Ext4/Ext4Volume.swift` | bromure_ac | 592 | B | darwin |  | 54/0 |
| `AgentCoding/Ext4/Ext4Writer.swift` | bromure_ac | 135 | B | as-is |  | 6/0 |
| `AgentCoding/FDGuard.swift` | bromure_ac | 140 | B | darwin, os |  | 6/0 |
| `AgentCoding/GuestURLGate.swift` | bromure_ac | 179 | B | darwin |  | 7/0 |
| `AgentCoding/Inference/EngineKey.swift` | bromure_ac | 114 | B | crypto |  | 11/0 |
| `AgentCoding/KubeEmulatorReleases.swift` | bromure_ac | 56 | B | FoundationNetworking |  | 2/0 |
| `AgentCoding/KubeLANAnnouncer.swift` | bromure_ac | 709 | B | darwin |  | 36/0 |
| `AgentCoding/Mitm/OSVClient.swift` | bromure_ac | 288 | B | FoundationNetworking |  | 9/0 |
| `AgentCoding/Mitm/PyPIMetadataClient.swift` | bromure_ac | 141 | B | FoundationNetworking |  | 6/0 |
| `AgentCoding/Mitm/SecretFingerprint.swift` | bromure_ac | 99 | B | crypto |  | 5/0 |
| `AgentCoding/Mitm/SocketDevClient.swift` | bromure_ac | 593 | B | FoundationNetworking |  | 21/0 |
| `AgentCoding/Mitm/TLSClientHello.swift` | bromure_ac | 109 | B | darwin |  | 2/0 |
| `AgentCoding/Mitm/UnmanagedCredentialGuard.swift` | bromure_ac | 316 | B | crypto |  | 15/0 |
| `AgentCoding/P2P/STUN.swift` | bromure_ac | 283 | B | darwin |  | 23/0 |
| `AgentCoding/PolicyHistory.swift` | bromure_ac | 64 | B | crypto |  | 4/0 |
| `AgentCoding/TUI.swift` | bromure_ac | 307 | B | darwin |  | 21/0 |
| `AgentCoding/WorkspaceLease.swift` | bromure_ac | 99 | B | darwin |  | 9/0 |
| `AgentCoding/AWSSSOResolver.swift` | bromure_ac | 292 | C | apple-import: imports CommonCrypto |  | 9/0 |
| `AgentCoding/AgentConfigScan.swift` | bromure_ac | 373 | C | depends-on-C | `SandboxEngine/Profile.swift` | 12/0 |
| `AgentCoding/AgentDelegation.swift` | bromure_ac | 864 | C | apple-import: imports SwiftUI |  | 56/3 |
| `AgentCoding/AgentSessionEngine.swift` | bromure_ac | 1936 | C | apple-import: imports AppKit |  | 78/0 |
| `AgentCoding/AgentSessions.swift` | bromure_ac | 3909 | C | apple-import: imports SwiftUI |  | 194/32 |
| `AgentCoding/AgentWatchdog.swift` | bromure_ac | 182 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 7/0 |
| `AgentCoding/AppLog.swift` | bromure_ac | 254 | C | apple-import: imports MachO |  | 14/0 |
| `AgentCoding/AutomationHubPreview.swift` | bromure_ac | 223 | C | apple-import: imports AppKit, SwiftUI |  | 2/0 |
| `AgentCoding/AutomationMCPServer.swift` | bromure_ac | 631 | C | depends-on-C | `AgentCoding/TaskBoardMCPServer.swift` | 15/0 |
| `AgentCoding/AutomationRunArchive.swift` | bromure_ac | 127 | C | depends-on-C | `AgentCoding/ScheduledAutomations.swift` | 12/0 |
| `AgentCoding/AutomationServer.swift` | bromure_ac | 2877 | C | depends-on-C | `AgentCoding/AgentSessions.swift` | 110/0 |
| `AgentCoding/BinaryIdentityService.swift` | bromure_ac | 571 | C | apple-import: imports Virtualization |  | 29/0 |
| `AgentCoding/BootBudget.swift` | bromure_ac | 123 | C | apple-import: imports IOKit |  | 7/0 |
| `AgentCoding/BootsInFlight.swift` | bromure_ac | 35 | C | depends-on-C | `SandboxEngine/Profile.swift` | 6/0 |
| `AgentCoding/BranchAlerts.swift` | bromure_ac | 53 | C | apple-import: imports AppKit |  | 2/0 |
| `AgentCoding/BromureAC.swift` | bromure_ac | 18326 | C | apple-import: imports Cocoa, IOKit, Sparkle, SwiftUI, Virtualization |  | 684/5 |
| `AgentCoding/BrowserCDP.swift` | bromure_ac | 665 | C | apple-import: imports Security, Virtualization |  | 36/0 |
| `AgentCoding/BrowserDownloadsModel.swift` | bromure_ac | 205 | C | apple-import: imports SwiftUI |  | 9/2 |
| `AgentCoding/BrowserImageInstaller.swift` | bromure_ac | 242 | C | linux-portability: Sources/AgentCoding/BrowserImageInstaller.swift:20: unknown  |  | 16/0 |
| `AgentCoding/BrowserMCPRelayClient.swift` | bromure_ac | 147 | C | depends-on-C | `AgentCoding/BrowserMCPServer.swift` | 8/0 |
| `AgentCoding/BrowserMCPServer.swift` | bromure_ac | 441 | C | apple-import: Sources/AgentCoding/BrowserMCPServer.swift:1: no such module |  | 17/0 |
| `AgentCoding/BrowserMCPVsockBridge.swift` | bromure_ac | 463 | C | apple-import: imports Virtualization |  | 34/0 |
| `AgentCoding/BrowserPane.swift` | bromure_ac | 373 | C | apple-import: imports AppKit, SwiftUI, Virtualization |  | 2/18 |
| `AgentCoding/BuildInfo.swift` | bromure_ac | 38 | C | apple-import: imports AppKit |  | 4/0 |
| `AgentCoding/CLICommands.swift` | bromure_ac | 1739 | C | depends-on-C | `AgentCoding/CLIModelCommands.swift` | 54/0 |
| `AgentCoding/CLIModelCommands.swift` | bromure_ac | 450 | C | apple-import: imports MLXLLM, MLXLMCommon, MLXHuggingFace, Tokenizers |  | 21/0 |
| `AgentCoding/ChatQueueStore.swift` | bromure_ac | 455 | C | apple-import: imports Combine |  | 31/0 |
| `AgentCoding/ClassifierLifecycle.swift` | bromure_ac | 116 | C | linux-portability: Sources/AgentCoding/ClassifierLifecycle.swift:29: cannot fin |  | 7/0 |
| `AgentCoding/ClaudeRegistrationCoordinator.swift` | bromure_ac | 1083 | C | apple-import: imports AppKit, Virtualization |  | 34/0 |
| `AgentCoding/CloudEvents.swift` | bromure_ac | 344 | C | depends-on-C | `AgentCoding/CloudUploader.swift` | 19/0 |
| `AgentCoding/CloudMTLSIdentity.swift` | bromure_ac | 128 | C | apple-import: imports Security |  | 5/0 |
| `AgentCoding/CloudUploader.swift` | bromure_ac | 213 | C | apple-import: imports Security |  | 8/0 |
| `AgentCoding/CloudflareTunnel.swift` | bromure_ac | 402 | C | apple-import: imports Security |  | 17/0 |
| `AgentCoding/CodexTokenBridge.swift` | bromure_ac | 176 | C | apple-import: imports Virtualization |  | 10/0 |
| `AgentCoding/CodingTaskLanding.swift` | bromure_ac | 1468 | C | linux-portability: Sources/AgentCoding/CodingTaskLanding.swift:75: type 'Coding |  | 63/0 |
| `AgentCoding/CodingTasks.swift` | bromure_ac | 5201 | C | depends-on-C | `SandboxEngine/Profile.swift` | 241/0 |
| `AgentCoding/ConfigFileSanitize.swift` | bromure_ac | 287 | C | depends-on-C | `AgentCoding/GitConfigParse.swift` | 11/0 |
| `AgentCoding/ConfigScan.swift` | bromure_ac | 944 | C | apple-import: imports Security |  | 34/0 |
| `AgentCoding/ConsolePresence.swift` | bromure_ac | 116 | C | apple-import: imports AppKit |  | 10/0 |
| `AgentCoding/ControlClient.swift` | bromure_ac | 388 | C | linux-portability: Sources/AgentCoding/ControlClient.swift:44: cannot find type |  | 11/0 |
| `AgentCoding/DelegationEngine.swift` | bromure_ac | 1929 | C | depends-on-C | `AgentCoding/AgentSessions.swift` | 91/0 |
| `AgentCoding/DelegationMCPServer.swift` | bromure_ac | 647 | C | depends-on-C | `AgentCoding/TaskBoardMCPServer.swift` | 21/0 |
| `AgentCoding/DelegationRelayClient.swift` | bromure_ac | 235 | C | linux-portability: Sources/AgentCoding/DelegationRelayClient.swift:27: cannot f |  | 18/0 |
| `AgentCoding/DelegationShimStream.swift` | bromure_ac | 163 | C | linux-portability: Sources/AgentCoding/DelegationShimStream.swift:63: cannot co |  | 13/0 |
| `AgentCoding/DisplayCards.swift` | bromure_ac | 1076 | C | apple-import: imports SwiftUI, WebKit, AVKit |  | 33/29 |
| `AgentCoding/DockerDashboard.swift` | bromure_ac | 1467 | C | apple-import: imports AppKit, Charts, SwiftUI |  | 9/70 |
| `AgentCoding/Enrollment.swift` | bromure_ac | 644 | C | apple-import: imports Security |  | 43/0 |
| `AgentCoding/EnrollmentCLI.swift` | bromure_ac | 125 | C | depends-on-C | `AgentCoding/Enrollment.swift` | 3/0 |
| `AgentCoding/EnvFileImport.swift` | bromure_ac | 165 | C | depends-on-C | `SandboxEngine/Profile.swift` | 7/0 |
| `AgentCoding/Ext4/Ext4Browser.swift` | bromure_ac | 444 | C | apple-import: imports SwiftUI, AppKit |  | 17/8 |
| `AgentCoding/FatClientRemote.swift` | bromure_ac | 436 | C | linux-portability: Sources/AgentCoding/FatClientRemote.swift:71: cannot find 'S |  | 28/0 |
| `AgentCoding/FatClientTypes.swift` | bromure_ac | 271 | C | linux-portability: Sources/AgentCoding/FatClientTypes.swift:146: cannot find ty |  | 10/0 |
| `AgentCoding/FileExplorer.swift` | bromure_ac | 941 | C | apple-import: imports SwiftUI, UniformTypeIdentifiers, AppKit |  | 42/0 |
| `AgentCoding/FirewallRuleActions.swift` | bromure_ac | 602 | C | apple-import: imports AppKit |  | 39/0 |
| `AgentCoding/FleetAdmission.swift` | bromure_ac | 97 | C | apple-import: imports AppKit |  | 4/0 |
| `AgentCoding/FolderUpload.swift` | bromure_ac | 120 | C | linux-portability: Sources/AgentCoding/FolderUpload.swift:53: cannot find 'Gues |  | 6/0 |
| `AgentCoding/GitConfigParse.swift` | bromure_ac | 203 | C | depends-on-C | `AgentCoding/ConfigScan.swift` | 9/0 |
| `AgentCoding/HostNetwork.swift` | bromure_ac | 54 | C | linux-portability: Sources/AgentCoding/HostNetwork.swift:18: binary operator '& |  | 2/0 |
| `AgentCoding/ImageCatalogAC.swift` | bromure_ac | 57 | C | depends-on-C | `SandboxEngine/ImageCatalog.swift` | 0/0 |
| `AgentCoding/Inference/CatalogStore.swift` | bromure_ac | 292 | C | depends-on-C | `AgentCoding/Inference/ModelCatalog.swift` | 23/0 |
| `AgentCoding/Inference/EngineModelMeta.swift` | bromure_ac | 78 | C | depends-on-C | `AgentCoding/Inference/ExternalEngine.swift` | 6/0 |
| `AgentCoding/Inference/ExternalEngine.swift` | bromure_ac | 521 | C | depends-on-C | `SandboxEngine/CloudTraceUploader.swift` | 15/0 |
| `AgentCoding/Inference/HubDownloader.swift` | bromure_ac | 131 | C | depends-on-C | `AgentCoding/DisplayCards.swift` | 9/0 |
| `AgentCoding/Inference/InferenceMetrics.swift` | bromure_ac | 383 | C | depends-on-C | `SandboxEngine/Profile.swift` | 31/0 |
| `AgentCoding/Inference/InferenceRepairProxy.swift` | bromure_ac | 930 | C | depends-on-C | `SandboxEngine/CloudTraceUploader.swift` | 38/0 |
| `AgentCoding/Inference/InferenceService.swift` | bromure_ac | 556 | C | linux-portability: Sources/AgentCoding/Inference/InferenceService.swift:380: ca |  | 31/0 |
| `AgentCoding/Inference/InferenceVsockBridge.swift` | bromure_ac | 78 | C | apple-import: imports Virtualization |  | 3/0 |
| `AgentCoding/Inference/LLMRouting.swift` | bromure_ac | 105 | C | depends-on-C | `SandboxEngine/Profile.swift` | 5/0 |
| `AgentCoding/Inference/LocalStreamEmitter.swift` | bromure_ac | 589 | C | depends-on-C | `SandboxEngine/CloudTraceUploader.swift` | 23/0 |
| `AgentCoding/Inference/ModelCatalog.swift` | bromure_ac | 244 | C | linux-portability: Sources/AgentCoding/Inference/ModelCatalog.swift:196: cannot |  | 12/0 |
| `AgentCoding/Inference/ModelDownloadManager.swift` | bromure_ac | 146 | C | depends-on-C | `AgentCoding/CLIModelCommands.swift` | 12/0 |
| `AgentCoding/Inference/ModelDownloader.swift` | bromure_ac | 137 | C | depends-on-C | `AgentCoding/Inference/CatalogStore.swift` | 6/0 |
| `AgentCoding/Inference/ModelLaunchPlan.swift` | bromure_ac | 148 | C | depends-on-C | `AgentCoding/Inference/ModelSettings.swift` | 12/0 |
| `AgentCoding/Inference/ModelSettings.swift` | bromure_ac | 668 | C | depends-on-C | `SandboxEngine/Profile.swift` | 54/0 |
| `AgentCoding/Inference/ModelSettingsMigration.swift` | bromure_ac | 272 | C | depends-on-C | `SandboxEngine/Profile.swift` | 11/0 |
| `AgentCoding/Inference/ModelSettingsStore.swift` | bromure_ac | 142 | C | apple-import: imports Combine |  | 14/0 |
| `AgentCoding/Inference/ProfileModelOverlay.swift` | bromure_ac | 508 | C | depends-on-C | `SandboxEngine/Profile.swift` | 15/0 |
| `AgentCoding/InstructionPresets.swift` | bromure_ac | 284 | C | apple-import: imports SwiftUI |  | 10/8 |
| `AgentCoding/KernelSentryService.swift` | bromure_ac | 732 | C | apple-import: imports Virtualization |  | 38/0 |
| `AgentCoding/KubeClusterEngine.swift` | bromure_ac | 1774 | C | apple-import: imports AppKit, Virtualization |  | 84/0 |
| `AgentCoding/KubeDashboard.swift` | bromure_ac | 1654 | C | apple-import: imports AppKit, Charts, SwiftUI |  | 2/75 |
| `AgentCoding/KubeconfigImport.swift` | bromure_ac | 138 | C | depends-on-C | `AgentCoding/Profile.swift` | 6/0 |
| `AgentCoding/LLMEventExtractor.swift` | bromure_ac | 383 | C | linux-portability: Sources/AgentCoding/LLMEventExtractor.swift:35: cannot find  |  | 14/0 |
| `AgentCoding/LaunchRestore.swift` | bromure_ac | 221 | C | apple-import: imports AppKit, SwiftUI |  | 10/3 |
| `AgentCoding/LiveModelRefresh.swift` | bromure_ac | 229 | C | apple-import: imports Combine |  | 8/0 |
| `AgentCoding/LoopbackCallbackForwarder.swift` | bromure_ac | 433 | C | apple-import: imports Virtualization |  | 17/0 |
| `AgentCoding/MCPOAuthBroker.swift` | bromure_ac | 399 | C | apple-import: imports AppKit |  | 14/0 |
| `AgentCoding/MCPServer.swift` | bromure_ac | 399 | C | linux-portability: Sources/AgentCoding/MCPServer.swift:23: cannot find 'CFRunLo |  | 21/0 |
| `AgentCoding/MachineChat.swift` | bromure_ac | 94 | C | apple-import: imports AppKit, SwiftUI |  | 9/3 |
| `AgentCoding/MachineLinks.swift` | bromure_ac | 911 | C | depends-on-C | `AgentCoding/AgentSessions.swift` | 49/0 |
| `AgentCoding/MermaidFence.swift` | bromure_ac | 400 | C | apple-import: imports SwiftUI, WebKit, MarkdownUI |  | 9/7 |
| `AgentCoding/Mitm/AWSCredentialServer.swift` | bromure_ac | 257 | C | depends-on-C | `AgentCoding/Mitm/ConsentBroker.swift` | 16/0 |
| `AgentCoding/Mitm/AWSResigner.swift` | bromure_ac | 353 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 15/0 |
| `AgentCoding/Mitm/BACTraceUploader.swift` | bromure_ac | 472 | C | apple-import: imports Security |  | 19/0 |
| `AgentCoding/Mitm/BromureBlockLog.swift` | bromure_ac | 75 | C | linux-portability: Sources/AgentCoding/Mitm/BromureBlockLog.swift:15: cannot fi |  | 5/0 |
| `AgentCoding/Mitm/BromureCA.swift` | bromure_ac | 206 | C | linux-portability: Sources/AgentCoding/Mitm/BromureCA.swift:28: cannot find typ |  | 7/0 |
| `AgentCoding/Mitm/CertCache.swift` | bromure_ac | 147 | C | depends-on-C | `AgentCoding/Mitm/BromureCA.swift` | 5/0 |
| `AgentCoding/Mitm/ClaudeSubscriptionStore.swift` | bromure_ac | 598 | C | linux-portability: Sources/AgentCoding/Mitm/ClaudeSubscriptionStore.swift:289:  |  | 42/0 |
| `AgentCoding/Mitm/CloudCredentials.swift` | bromure_ac | 792 | C | apple-import: imports Security |  | 34/0 |
| `AgentCoding/Mitm/CodexSubscriptionStore.swift` | bromure_ac | 554 | C | linux-portability: Sources/AgentCoding/Mitm/CodexSubscriptionStore.swift:200: t |  | 40/0 |
| `AgentCoding/Mitm/CommandLineRedactor.swift` | bromure_ac | 272 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 7/0 |
| `AgentCoding/Mitm/ConsentBroker.swift` | bromure_ac | 432 | C | apple-import: imports AppKit |  | 19/0 |
| `AgentCoding/Mitm/ConsentPrompt.swift` | bromure_ac | 739 | C | apple-import: imports AppKit |  | 29/0 |
| `AgentCoding/Mitm/CredentialMint.swift` | bromure_ac | 554 | C | depends-on-C | `AgentCoding/Mitm/AWSCredentialServer.swift` | 32/0 |
| `AgentCoding/Mitm/DepiRegistry.swift` | bromure_ac | 124 | C | apple-import: imports AppKit |  | 5/0 |
| `AgentCoding/Mitm/EgressConnectionRegistry.swift` | bromure_ac | 266 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 17/0 |
| `AgentCoding/Mitm/Fusion.swift` | bromure_ac | 1398 | C | depends-on-C | `SandboxEngine/Profile.swift` | 49/0 |
| `AgentCoding/Mitm/GrokSubscriptionStore.swift` | bromure_ac | 533 | C | linux-portability: Sources/AgentCoding/Mitm/GrokSubscriptionStore.swift:226: ty |  | 40/0 |
| `AgentCoding/Mitm/GuardrailsConsentBroker.swift` | bromure_ac | 260 | C | depends-on-C | `AgentCoding/Mitm/ConsentPrompt.swift` | 11/0 |
| `AgentCoding/Mitm/GuardrailsPolicy.swift` | bromure_ac | 795 | C | depends-on-C | `AgentCoding/Profile.swift` | 37/0 |
| `AgentCoding/Mitm/HTTPProxy.swift` | bromure_ac | 5745 | C | apple-import: imports Compression, Virtualization |  | 124/0 |
| `AgentCoding/Mitm/HostAgentClient.swift` | bromure_ac | 296 | C | linux-portability: Sources/AgentCoding/Mitm/HostAgentClient.swift:193: cannot c |  | 16/0 |
| `AgentCoding/Mitm/KimiProvisioning.swift` | bromure_ac | 336 | C | depends-on-C | `AgentCoding/Mitm/KimiSubscriptionStore.swift` | 15/0 |
| `AgentCoding/Mitm/KimiSubscriptionStore.swift` | bromure_ac | 636 | C | linux-portability: Sources/AgentCoding/Mitm/KimiSubscriptionStore.swift:302: ty |  | 42/0 |
| `AgentCoding/Mitm/MintedCredential.swift` | bromure_ac | 83 | C | depends-on-C | `AgentCoding/Mitm/SessionTokenPlan.swift` | 4/0 |
| `AgentCoding/Mitm/MitmEngine.swift` | bromure_ac | 1020 | C | apple-import: imports Virtualization |  | 43/0 |
| `AgentCoding/Mitm/MitmPassthrough.swift` | bromure_ac | 135 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 10/0 |
| `AgentCoding/Mitm/NPMRegistryTransforms.swift` | bromure_ac | 574 | C | apple-import: imports Compression |  | 18/0 |
| `AgentCoding/Mitm/OnePasswordRefresher.swift` | bromure_ac | 195 | C | linux-portability: Sources/AgentCoding/Mitm/OnePasswordRefresher.swift:76: type |  | 11/0 |
| `AgentCoding/Mitm/OpenSSHKeyFormat.swift` | bromure_ac | 177 | C | linux-portability: Sources/AgentCoding/Mitm/OpenSSHKeyFormat.swift:46: cannot f |  | 6/0 |
| `AgentCoding/Mitm/PIIDetector.swift` | bromure_ac | 350 | C | apple-import: imports OnnxRuntimeBindings |  | 16/0 |
| `AgentCoding/Mitm/PIIRewriter.swift` | bromure_ac | 1044 | C | depends-on-C | `AgentCoding/Inference/ExternalEngine.swift` | 38/0 |
| `AgentCoding/Mitm/PIIScanCLI.swift` | bromure_ac | 91 | C | depends-on-C | `AgentCoding/Mitm/PIIDetector.swift` | 3/0 |
| `AgentCoding/Mitm/PIIVault.swift` | bromure_ac | 499 | C | linux-portability: Sources/AgentCoding/Mitm/PIIVault.swift:38: cannot find 'Sec |  | 31/0 |
| `AgentCoding/Mitm/PassphraseKeychain.swift` | bromure_ac | 84 | C | apple-import: imports Security |  | 5/0 |
| `AgentCoding/Mitm/PromptInjectionClassifier.swift` | bromure_ac | 625 | C | apple-import: imports OnnxRuntimeBindings, Tokenizers |  | 22/0 |
| `AgentCoding/Mitm/PromptInjectionCloudEvent.swift` | bromure_ac | 49 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 1/0 |
| `AgentCoding/Mitm/PromptInjectionConsentBroker.swift` | bromure_ac | 205 | C | apple-import: imports AppKit |  | 14/0 |
| `AgentCoding/Mitm/PromptInjectionModels.swift` | bromure_ac | 335 | C | apple-import: imports AppKit |  | 24/0 |
| `AgentCoding/Mitm/RealtimeEventTap.swift` | bromure_ac | 145 | C | depends-on-C | `AgentCoding/Mitm/WebSocketTrace.swift` | 4/0 |
| `AgentCoding/Mitm/RemoteConsent.swift` | bromure_ac | 87 | C | depends-on-C | `AgentCoding/PendingPromptBroker.swift` | 4/0 |
| `AgentCoding/Mitm/RulesFileScanner.swift` | bromure_ac | 461 | C | linux-portability: Sources/AgentCoding/Mitm/RulesFileScanner.swift:180: cannot  |  | 19/0 |
| `AgentCoding/Mitm/SSHAgent.swift` | bromure_ac | 522 | C | depends-on-C | `AgentCoding/Mitm/ConsentBroker.swift` | 28/0 |
| `AgentCoding/Mitm/SecretsVault.swift` | bromure_ac | 161 | C | apple-import: imports Security |  | 0/0 |
| `AgentCoding/Mitm/SessionTokenPlan.swift` | bromure_ac | 881 | C | depends-on-C | `SandboxEngine/Profile.swift` | 27/0 |
| `AgentCoding/Mitm/SquelchLedger.swift` | bromure_ac | 451 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 33/0 |
| `AgentCoding/Mitm/SquelchRewriter.swift` | bromure_ac | 489 | C | depends-on-C | `AgentCoding/Mitm/PIIRewriter.swift` | 21/0 |
| `AgentCoding/Mitm/SubscriptionFakeMint.swift` | bromure_ac | 129 | C | depends-on-C | `AgentCoding/Mitm/SessionTokenPlan.swift` | 7/0 |
| `AgentCoding/Mitm/SubscriptionStoreFile.swift` | bromure_ac | 290 | C | depends-on-C | `AgentCoding/Mitm/SecretsVault.swift` | 17/0 |
| `AgentCoding/Mitm/SupplyChainConsentBroker.swift` | bromure_ac | 426 | C | apple-import: imports AppKit |  | 19/0 |
| `AgentCoding/Mitm/SupplyChainEnforcer.swift` | bromure_ac | 521 | C | depends-on-C | `AgentCoding/Mitm/DepiRegistry.swift` | 22/0 |
| `AgentCoding/Mitm/TLSServerStream.swift` | bromure_ac | 537 | C | apple-import: imports Security |  | 40/0 |
| `AgentCoding/Mitm/TokenSwap.swift` | bromure_ac | 747 | C | depends-on-C | `AgentCoding/Mitm/ConsentBroker.swift` | 31/0 |
| `AgentCoding/Mitm/TraceRecord.swift` | bromure_ac | 254 | C | depends-on-C | `AgentCoding/Inference/InferenceService.swift` | 11/0 |
| `AgentCoding/Mitm/TraceStore.swift` | bromure_ac | 457 | C | depends-on-C | `AgentCoding/Mitm/SecretsVault.swift` | 22/0 |
| `AgentCoding/Mitm/UpstreamPinning.swift` | bromure_ac | 301 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 14/0 |
| `AgentCoding/Mitm/WebSocketTrace.swift` | bromure_ac | 558 | C | apple-import: imports Compression |  | 19/0 |
| `AgentCoding/Mitm/WebSocketTransform.swift` | bromure_ac | 864 | C | depends-on-C | `AgentCoding/Mitm/HTTPProxy.swift` | 35/0 |
| `AgentCoding/NetworkLineage.swift` | bromure_ac | 504 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 17/0 |
| `AgentCoding/OCSFExport.swift` | bromure_ac | 414 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 29/0 |
| `AgentCoding/OnboardingSignIn.swift` | bromure_ac | 189 | C | apple-import: imports AppKit |  | 6/0 |
| `AgentCoding/OpenShellAdvisor.swift` | bromure_ac | 868 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 38/0 |
| `AgentCoding/OpenShellGovernance.swift` | bromure_ac | 261 | C | depends-on-C | `SandboxEngine/OpenShellBoundary.swift` | 18/0 |
| `AgentCoding/OpenShellPolicyEditor.swift` | bromure_ac | 795 | C | apple-import: imports AppKit, SwiftUI, UniformTypeIdentifiers |  | 2/25 |
| `AgentCoding/OpenShellProviderLayer.swift` | bromure_ac | 108 | C | depends-on-C | `SandboxEngine/Profile.swift` | 4/0 |
| `AgentCoding/P2P/ControlPlaneClient.swift` | bromure_ac | 440 | C | depends-on-C | `AgentCoding/P2P/P2PIdentity.swift` | 36/0 |
| `AgentCoding/P2P/DeviceChannel.swift` | bromure_ac | 342 | C | depends-on-C | `AgentCoding/FatClientTypes.swift` | 20/0 |
| `AgentCoding/P2P/DeviceIdentity.swift` | bromure_ac | 201 | C | linux-portability: Sources/AgentCoding/P2P/DeviceIdentity.swift:86: cannot find |  | 13/0 |
| `AgentCoding/P2P/P2PBroker.swift` | bromure_ac | 1024 | C | apple-import: imports Network |  | 43/0 |
| `AgentCoding/P2P/P2PCandidate.swift` | bromure_ac | 136 | C | linux-portability: Sources/AgentCoding/P2P/P2PCandidate.swift:107: binary opera |  | 3/0 |
| `AgentCoding/P2P/P2PEnroll.swift` | bromure_ac | 132 | C | depends-on-C | `AgentCoding/P2P/DeviceIdentity.swift` | 3/0 |
| `AgentCoding/P2P/P2PEnrollmentCoordinator.swift` | bromure_ac | 225 | C | apple-import: imports AppKit, UIKit, AuthenticationServices |  | 9/0 |
| `AgentCoding/P2P/P2PIdentity.swift` | bromure_ac | 61 | C | depends-on-C | `AgentCoding/Enrollment.swift` | 2/0 |
| `AgentCoding/P2P/P2PSignaling.swift` | bromure_ac | 133 | C | depends-on-C | `AgentCoding/P2P/P2PCandidate.swift` | 5/0 |
| `AgentCoding/P2P/P2PTransport.swift` | bromure_ac | 383 | C | linux-portability: Sources/AgentCoding/P2P/P2PTransport.swift:26: cannot find ' |  | 17/0 |
| `AgentCoding/P2P/PortMap.swift` | bromure_ac | 395 | C | depends-on-C | `AgentCoding/FatClientTypes.swift` | 15/0 |
| `AgentCoding/P2P/RelayARQ.swift` | bromure_ac | 710 | C | linux-portability: Sources/AgentCoding/P2P/RelayARQ.swift:578: cannot convert v |  | 37/0 |
| `AgentCoding/P2P/TurnRelayTransport.swift` | bromure_ac | 276 | C | depends-on-C | `AgentCoding/FatClientTypes.swift` | 17/0 |
| `AgentCoding/P2P/TurnTCP.swift` | bromure_ac | 577 | C | depends-on-C | `AgentCoding/P2P/P2PCandidate.swift` | 24/0 |
| `AgentCoding/P2P/TurnTLS.swift` | bromure_ac | 181 | C | apple-import: imports Network |  | 4/0 |
| `AgentCoding/P2P/TurnUDP.swift` | bromure_ac | 597 | C | depends-on-C | `AgentCoding/P2P/P2PCandidate.swift` | 26/0 |
| `AgentCoding/PendingPromptBroker.swift` | bromure_ac | 160 | C | apple-import: imports AppKit |  | 9/0 |
| `AgentCoding/PlanEventBridge.swift` | bromure_ac | 311 | C | apple-import: imports Virtualization |  | 17/0 |
| `AgentCoding/PlanStreamHub.swift` | bromure_ac | 243 | C | depends-on-C | `SandboxEngine/Profile.swift` | 12/0 |
| `AgentCoding/PlatformShims.swift` | bromure_ac | 310 | C | apple-import: imports SwiftUI, AppKit, UIKit |  | 15/10 |
| `AgentCoding/PolicySteering.swift` | bromure_ac | 504 | C | depends-on-C | `SandboxEngine/OpenShellPolicy.swift` | 23/0 |
| `AgentCoding/PolicySteeringDelivery.swift` | bromure_ac | 174 | C | depends-on-C | `AgentCoding/BromureAC.swift` | 7/0 |
| `AgentCoding/Profile.swift` | bromure_ac | 7060 | C | apple-import: imports AppKit |  | 224/0 |
| `AgentCoding/QuickTask.swift` | bromure_ac | 627 | C | apple-import: imports AppKit, Carbon, SwiftUI |  | 12/16 |
| `AgentCoding/RegistrationLaunch.swift` | bromure_ac | 191 | C | depends-on-C | `AgentCoding/ClaudeRegistrationCoordinator.swift` | 8/1 |
| `AgentCoding/RemoteAccessServer.swift` | bromure_ac | 455 | C | depends-on-C | `AgentCoding/RemoteSSHHandlers.swift` | 25/0 |
| `AgentCoding/RemoteMenu.swift` | bromure_ac | 2004 | C | depends-on-C | `AgentCoding/ControlClient.swift` | 75/0 |
| `AgentCoding/RemoteSSHHandlers.swift` | bromure_ac | 986 | C | apple-import: imports OpenDirectory |  | 45/0 |
| `AgentCoding/RemoteTraceStore.swift` | bromure_ac | 81 | C | linux-portability: Sources/AgentCoding/RemoteTraceStore.swift:16: cannot find t |  | 6/0 |
| `AgentCoding/RepoWatch.swift` | bromure_ac | 1311 | C | depends-on-C | `SandboxEngine/Profile.swift` | 83/0 |
| `AgentCoding/RepoWatchEngine.swift` | bromure_ac | 532 | C | apple-import: imports AppKit, UserNotifications |  | 30/0 |
| `AgentCoding/RepoWatchWiring.swift` | bromure_ac | 285 | C | apple-import: imports AppKit |  | 12/0 |
| `AgentCoding/RequestLedger.swift` | bromure_ac | 116 | C | depends-on-C | `AgentCoding/FatClientTypes.swift` | 5/0 |
| `AgentCoding/ScheduledAutomations.swift` | bromure_ac | 2902 | C | depends-on-C | `SandboxEngine/Profile.swift` | 116/0 |
| `AgentCoding/SecurityTimeline.swift` | bromure_ac | 1097 | C | depends-on-C | `AgentCoding/CloudEvents.swift` | 63/0 |
| `AgentCoding/SentryModuleStore.swift` | bromure_ac | 436 | C | depends-on-C | `SandboxEngine/ImageCatalog.swift` | 29/0 |
| `AgentCoding/SessionBranches.swift` | bromure_ac | 444 | C | depends-on-C | `AgentCoding/AgentSessionEngine.swift` | 25/0 |
| `AgentCoding/SessionDisk.swift` | bromure_ac | 2593 | C | apple-import: imports AppKit |  | 82/0 |
| `AgentCoding/SessionModels.swift` | bromure_ac | 609 | C | depends-on-C | `SandboxEngine/Profile.swift` | 29/0 |
| `AgentCoding/SessionSignIn.swift` | bromure_ac | 402 | C | apple-import: imports AppKit |  | 12/0 |
| `AgentCoding/SessionTimeline.swift` | bromure_ac | 255 | C | linux-portability: Sources/AgentCoding/SessionTimeline.swift:95: cannot find ty |  | 16/0 |
| `AgentCoding/SlashCommands.swift` | bromure_ac | 414 | C | apple-import: imports AppKit, SwiftUI |  | 12/4 |
| `AgentCoding/SubscriptionTokenBridge.swift` | bromure_ac | 199 | C | apple-import: imports Virtualization |  | 10/0 |
| `AgentCoding/SupplyChainOverrides.swift` | bromure_ac | 41 | C | apple-import: imports AppKit |  | 2/0 |
| `AgentCoding/SwitchMitmForwarder.swift` | bromure_ac | 144 | C | depends-on-C | `SandboxEngine/VMNetSwitch.swift` | 6/0 |
| `AgentCoding/TCPFlow.swift` | bromure_ac | 224 | C | linux-portability: Sources/AgentCoding/TCPFlow.swift:39: cannot find type 'Utun |  | 15/0 |
| `AgentCoding/TaskBoardMCPServer.swift` | bromure_ac | 574 | C | apple-import: imports Virtualization |  | 29/0 |
| `AgentCoding/TranscriptActivity.swift` | bromure_ac | 1132 | C | apple-import: imports SwiftUI |  | 43/7 |
| `AgentCoding/UbuntuImageManager+Remote.swift` | bromure_ac | 297 | C | apple-import: imports Virtualization |  | 5/0 |
| `AgentCoding/UbuntuImageManager.swift` | bromure_ac | 1412 | C | apple-import: imports AppKit, CommonCrypto, Virtualization |  | 53/0 |
| `AgentCoding/UbuntuSandboxVM.swift` | bromure_ac | 1499 | C | apple-import: imports Virtualization |  | 48/0 |
