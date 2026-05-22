# SSH Agent + PKI Parity Audit: macOS ↔ Windows

**Scope:** SSH agent stack, Default SSH key, Bromure CA, CertCache, Cloud credentials registries, KubeconfigMaterializer, PassphraseKeychain.

**macOS sources audited:**
- Sources/AgentCoding/Mitm/HostAgentClient.swift
- Sources/AgentCoding/Mitm/OpenSSHKeyFormat.swift
- Sources/AgentCoding/Mitm/PrivateSSHAgent.swift
- Sources/AgentCoding/Mitm/SSHAgent.swift
- Sources/AgentCoding/Mitm/PassphraseKeychain.swift
- Sources/AgentCoding/DefaultSSHKey.swift
- Sources/AgentCoding/Mitm/BromureCA.swift
- Sources/AgentCoding/Mitm/CertCache.swift
- Sources/AgentCoding/Mitm/CloudCredentials.swift
- Sources/AgentCoding/BromureAC.swift (session-launch wiring, lines 2080–2204, 3030–3300)

**Windows targets audited:**
- windows/Bromure.AC.Mitm/Ssh/{HostAgentClient,OpenSshKeyFormat,PrivateSshAgent,SshAgentServer,AgentKey}.cs
- windows/Bromure.AC.Core/Ssh/{DefaultSshKey,ProfileSshKey}.cs
- windows/Bromure.AC.Mitm/Pki/{BromureCa,CertCache,Registries,KubeconfigMaterializer,MitmException}.cs
- windows/Bromure.Platform/{ISecretStore,WindowsSecretStore}.cs
- windows/Bromure.AC.Mitm/Engine/MitmEngine.cs
- windows/Bromure.AC/ViewModels/{SessionViewModel,ProfilesViewModel}.cs

Severity tags below: **CRITICAL** (security or feature-breaking), **HIGH** (functional gap), **MEDIUM** (behavioural divergence), **LOW** (cosmetic / minor).

---

## 1. SSH Agent Server Transport / Listener Wiring

### 1.1 SSH agent listener never opened to the VM — **CRITICAL**
- **macOS source:** BromureAC.swift wires `engine.sshAgent.setKeys()` (line 2120) and then a VZVirtioSocketListener routes vsock port `8444` connections from inside the VM into `SSHAgentServer.serve(fd:, profileID:)` (SSHAgent.swift:91–127). The VM's `SSH_AUTH_SOCK` env var points at the in-VM bridge that proxies to that vsock listener.
- **Windows status:** **MISSING — show-stopper.**
- **Detail:** `MitmEngine.cs` declares `SshAgentVsockPort = 8444` (line 42) and constructs `SshAgentServer` (line 105), but **nothing ever opens a listener for it**. Search of the entire Windows tree shows no `SshAgentServer.serve`, no `HandleSignRequestAsync` caller, and no hvsocket/Plan-9/TCP bridge for the agent port. The PrivateSshAgent named-pipe at `\\.\pipe\bromure-ac-ssh-agent` is the only listener that exists, and the VM has no way to reach a Windows host named pipe directly — there is no plumbing analogous to macOS's vsock→unix bridge. As a result, **in-VM ssh clients have no working agent on Windows.** `MitmEngine.SshAgent.SetKeys()` is never called either (see 1.3).

### 1.2 SSH agent server is never given the profile's keys — **CRITICAL**
- **macOS source:** BromureAC.swift:2119–2120 calls `loadAgentKeys(for: profile)` and `engine.sshAgent.setKeys(agentKeys, for: profile.id)` at session launch; `loadAgentKeys` (line 3034) reads the 64-byte `agent/id_ed25519.raw`. Without this, IDENTITIES_ANSWER is empty.
- **Windows status:** **MISSING.**
- **Detail:** `SessionViewModel.cs:155–290` (the session-launch path) never touches `_engine.SshAgent.SetKeys`. Only `UnregisterAsync` clears it (MitmEngine.cs:175). Grep across `windows/` for `SshAgent.SetKeys`, `SetKeys(`, `loadAgentKeys`, etc. returns zero hits outside the class itself. The per-profile key vault is therefore always empty even if a listener existed.

### 1.3 `SshAgentServer` has no `Serve(stream, profileId)` entry point — **HIGH**
- **macOS source:** SSHAgent.swift:91 `func serve(fd:Int32, profileID: UUID) async` runs the read/dispatch loop, handling both REQUEST_IDENTITIES and SIGN_REQUEST in one connection.
- **Windows status:** **PARTIAL.**
- **Detail:** `SshAgentServer.cs` only exposes `BuildIdentitiesAnswer(profileId)` (line 73) and `HandleSignRequestAsync(body, profileId, …)` (line 92). There is no `ServeAsync(Stream, Guid)` that drives the wire loop. Whatever bridge eventually plumbs the VM into the agent will have to re-implement framing on its own.

### 1.4 PrivateSshAgent loop is profile-blind — **HIGH**
- **macOS source:** PrivateSSHAgent is a global ssh-add target; per-profile selection happens in SSHAgentServer via `profileID`.
- **Windows status:** **DIFFERENT.**
- **Detail:** `PrivateSshAgent.cs` runs its own accept loop on the named pipe and serves identities from a *single* `_keys` `ConcurrentDictionary` (line 44). There is no profile dimension. If a future bridge routes the VM through the named pipe directly, every profile sees every other profile's keys. Either the pipe must be per-profile or the bridge must go via `SshAgentServer` (which is what macOS does).

### 1.5 macOS-style fallback: SshAgentServer.HandleSignRequest never forwards to PrivateSshAgent — **HIGH**
- **macOS source:** SSHAgent.swift:226–273 — after the in-process key lookup misses, the code consults `importedApprovals`, applies the consent gate, and **forwards the SIGN_REQUEST to `HostAgentClient._bromurePrivate`** (i.e. the spawned ssh-agent). This is how imported keys actually sign.
- **Windows status:** **MISSING.**
- **Detail:** `SshAgentServer.HandleSignRequestAsync` (lines 92–131) returns `SSH_AGENT_FAILURE` whenever the public-blob isn't in the per-profile vault. The TODO is even acknowledged in the source: *"Could be an imported-only key the user added via the profile UI. We don't sign those here — the macOS port forwards to a host-side ssh-agent. On Windows we'd add an 'imported keys' namespace into the agent; pending."* (line 109). Imported keys cannot sign.

---

## 2. SSH Wire Protocol Coverage

### 2.1 Key types — **DIFFERENT**
- **macOS source:** SSHAgent.swift:421–424 — only ed25519 keys are minted/signed in-process; **everything else (RSA, ECDSA) is forwarded to the host's bromure ssh-agent subprocess**, which speaks the full OpenSSH protocol — so RSA/ECDSA work transparently for imported keys.
- **Windows status:** **PARTIAL — only ed25519.**
- **Detail:** Both `SshAgentServer.SignEd25519` (line 133) and `PrivateSshAgent.SignEd25519` (line 208) hard-code BouncyCastle `Ed25519Signer`. The `TryAddIdentity` (PrivateSshAgent.cs:217) rejects anything that isn't `"ssh-ed25519"`. So even if a future bridge wires keys through, RSA and ECDSA keys are unsignable. **Imported RSA keys (still the GitHub default historically) will silently fail to sign.**

### 2.2 RSA-SHA2 signature flags — **CRITICAL**
- **macOS source:** SSHAgent.swift:182–184 reads the u32 flags from SIGN_REQUEST (bit 1 = rsa-sha2-256, bit 2 = rsa-sha2-512), and forwards them **verbatim** to the upstream ssh-agent (line 254). The comment is explicit: *"Modern OpenSSH servers reject the legacy SHA-1 ssh-rsa signatures, so we must forward the flags verbatim — dropping them makes the host agent sign with SHA-1 and the client throws 'incorrect signature type'."*
- **Windows status:** **MISSING (consequence of 2.1, but called out separately because the field is silently dropped).**
- **Detail:** `SshAgentServer.ParseSignRequest` (line 152) reads only `publicBlob` and `data`, never the u32 flags. `PrivateSshAgent.BuildSignResponse` (line 178) comments *"flags ignored — we always do raw ed25519."* When RSA support is added, this needs to be re-introduced or the SHA-1 regression will reappear.

### 2.3 SSH_AGENTC_ADD_IDENTITY / REMOVE_IDENTITY — **DIFFERENT (Windows extra)**
- **macOS source:** SSHAgentServer rejects anything that isn't REQUEST_IDENTITIES or SIGN_REQUEST (SSHAgent.swift:122–124). Keys are added via the external `/usr/bin/ssh-agent` + `ssh-add` (PrivateSSHAgent.swift:34, BromureAC.swift:3221).
- **Windows status:** **DIFFERENT.**
- **Detail:** `PrivateSshAgent.cs:39–40` adds `SSH_AGENTC_ADD_IDENTITY (17)` and `SSH_AGENTC_REMOVE_IDENTITY (18)`. The Windows port implements ADD natively for ed25519 (line 217) because it can't shell out to ssh-add. This is fine as a divergence and arguably cleaner, BUT it means there is no shell-out path for passphrase-protected imported keys (see 5.2).

### 2.4 Agent constraints (lifetime / confirm) — **MISSING on both sides**
- **macOS source:** Not implemented — bromure's own approval flag is the equivalent.
- **Windows status:** **OK (parity).**

---

## 3. Default SSH Key + Per-Profile Key Generation

### 3.1 `DefaultSshKey` is never invoked anywhere — **HIGH**
- **macOS source:** DefaultSSHKey.swift:55–84 (mint) + 104–118 (`copy(to:)`). The macOS source pre-mints a shared default keypair under `~/Library/Application Support/BromureAC/default-ssh/` and copies it into each new profile's `agent/` directory at save time so all freshly-spawned profiles start with the *same* SSH identity.
- **Windows status:** **MISSING wiring.**
- **Detail:** `DefaultSshKey.cs` is implemented (correctly, mirroring the macOS layout), but **grep across the Windows tree finds zero callers** — neither `ProfilesViewModel.AddProfile` nor `App.xaml.cs` instantiates it. Every new profile instead gets a *fresh* unique keypair via `ProfileSshKey.EnsureExists` (ProfilesViewModel.cs:119). This breaks the macOS contract that all profiles share one default public key for paste-into-GitHub.

### 3.2 Per-profile key location differs from session-disk layout — **MEDIUM**
- **macOS source:** Profile.swift:1644 — the per-profile keypair lives under `profiles/<id>/agent/id_ed25519.raw`. The session-disk code in BromureAC.swift:1696 reads that path to install the key into the VM's home `.ssh/`.
- **Windows status:** **DIFFERENT path; no session-disk install.**
- **Detail:** `ProfileSshKey.cs:25–26` puts the raw key at `%LOCALAPPDATA%\Bromure\AC\agent\<profileId>\id_ed25519.raw` — not under the profile JSON's directory. That alone is fine, but **`SessionViewModel` does not copy the key into the VM's home overlay** (the home-files dictionary at line 225 has no `.ssh/id_ed25519` entry). In-VM ssh clients have neither an agent socket (gap 1.1) nor an on-disk key. This is a complete gap.

### 3.3 `SshKeyRequiresApproval` per-sign consent flag — **CRITICAL**
- **macOS source:** Profile.swift:868 `sshKeyRequiresApproval: Bool`, fed into AgentKey at BromureAC.swift:3062. SSHAgent.swift:192–203 pops a consent prompt before signing if the flag is set.
- **Windows status:** **MISSING** (also flagged in 01-profile-model.md gap row 70).
- **Detail:** No equivalent field on `Profile.cs`. Even if SshAgent were wired, every signature would proceed without the consent gate.

### 3.4 OpenSSH public-key text format — **OK**
- Both compute the SSH wire blob (`string("ssh-ed25519") + string(pub32)`) and base64 it with the same surrounding text format.

### 3.5 0o700 / 0o600 file permissions — **DIFFERENT**
- **macOS source:** DefaultSSHKey.swift:60,69 sets `posixPermissions: 0o700` on dir, `0o600` on the raw file.
- **Windows status:** **DIFFERENT (acceptable — NTFS ACLs handle this differently).**
- **Detail:** `DefaultSshKey.cs:48,62` calls `Directory.CreateDirectory` + `File.WriteAllBytes` with default ACLs. Bromure documents this in `WIN32_AC_PLAN.md` as relying on the per-user profile ACLs and BitLocker.

---

## 4. Host-Agent Forwarding (`HostAgentClient`)

### 4.1 Daily-driver agent isolation policy — **OK**
- **macOS source:** HostAgentClient.swift:6–15 and SSHAgent.swift:141–150 both document the deliberate decision *not* to multiplex `SSH_AUTH_SOCK` into the VM.
- **Windows status:** **OK.**
- **Detail:** `HostAgentClient.cs:24–29` and `PrivateSshAgent.cs:14–27` mirror the policy. Windows defaults to a named-pipe endpoint at `\\.\pipe\bromure-ac-ssh-agent`. Good.

### 4.2 Transport surface — **DIFFERENT (improvement)**
- **macOS source:** AF_UNIX socket via raw POSIX `socket(2)` + `connect(2)`.
- **Windows status:** **DIFFERENT but legitimate.**
- **Detail:** `HostAgentClient.cs` supports three endpoints — `NamedPipe`, `UnixSocket`, `LoopbackTcp` (line 130–135). NamedPipe is the production path. This is a clean improvement.

### 4.3 `BromurePrivate` singleton lifecycle — **OK**
- Both expose a static singleton that the engine sets after spawning the agent (HostAgentClient.swift:22 / HostAgentClient.cs:41). MitmEngine.cs:114 sets it during construction.

### 4.4 256 KiB frame cap — **OK** (both clients enforce identical bounds).

---

## 5. Imported SSH Keys (Passphrase-Protected User Keys)

### 5.1 Imported-key approval map — **CRITICAL (dead code on Windows)**
- **macOS source:** BromureAC.swift:2196–2204 builds `[Data: SSHAgentServer.ImportedApproval]` from `profile.importedSSHKeys.where(.requireApproval)` and calls `engine.sshAgent.setImportedKeyApprovals(approvals, for: profile.id)`. SSHAgent.swift:236–244 uses this map to gate forwarded SIGN_REQUESTs.
- **Windows status:** **MISSING wire-up.**
- **Detail:** `SshAgentServer.SetImportedKeyApprovals` exists (line 40) but **no caller**. Grep: zero matches. Combined with gap 1.5 (no forward to private agent), imported keys are doubly broken.

### 5.2 `loadImportedSSHKeys` + `sshAddImportedKey` (passphrase flow) — **MISSING**
- **macOS source:** BromureAC.swift:3194–3278. Per-session:
  1. Iterates `profile.importedSSHKeys`,
  2. Reads passphrase from `PassphraseKeychain.get(...)`,
  3. Writes a single-use `SSH_ASKPASS` shell script to `/tmp`,
  4. Spawns `/usr/bin/ssh-add` with `SSH_AUTH_SOCK` pointed at the private agent + `SSH_ASKPASS_REQUIRE=force`,
  5. Unlinks the script.
- **Windows status:** **MISSING.**
- **Detail:** No callers of `PrivateSshAgent.AddEd25519` for imported keys. No askpass equivalent. The Windows `ImportedSshKey` model (Credentials.cs:66) stores `PrivateKeyPem` *inline plaintext* and `Comment`; **there is no passphrase field at all** (already flagged in 01-profile-model.md rows 78–79). This means:
  - Windows cannot import a passphrase-protected key (no place to put the passphrase).
  - Windows stores the PEM as plaintext profile JSON — **security regression vs macOS, which writes the encrypted PEM to `agent/imported/` with 0o600 and stores only the passphrase in Keychain.**

### 5.3 `importSSHKey(at:passphrase:label:)` — **MISSING**
- **macOS source:** BromureAC.swift:3091–3174 — copies the file, derives the public-key text via `ssh-keygen -y`, persists passphrase to Keychain, returns an `ImportedSSHKey` record.
- **Windows status:** **MISSING.**
- **Detail:** `ProfilesViewModel.cs:264` constructs `new ImportedSshKey` directly from UI fields (no decryption check, no public-key derivation, no Keychain). The profile JSON ends up with raw PEM only.

### 5.4 `PassphraseKeychain` API — **MISSING for SSH**
- **macOS source:** PassphraseKeychain.swift exposes `set/get/delete(passphrase, profileID:, filename:)` keyed by `"<profileUUID>/<filename>"`.
- **Windows status:** **MISSING.**
- **Detail:** `ISecretStore.StoreSecret(service, account, value)` has the right *shape* (service + account + string), but **no SSH caller exists**. Used only by `Enrollment.cs:126` (`"BromureAC" + "InstallTokenSecret"`). The Windows `WindowsSecretStore` covers the API surface — but the agent-side consumers are gone (see 5.1–5.3). PARITY_IGNORE entry for `PassphraseKeychain.swift` says the contract is "verified by ISecretStore tests" — that is misleading: the *only* test is generic, not SSH-specific.

---

## 6. Bromure CA

### 6.1 Subject DN / issuer fields — **OK**
- Both: `CN=Bromure Agentic Coding Root CA, O=Bromure`. (BromureCA.swift:86–88 / BromureCa.cs:122.)

### 6.2 Validity window — **OK**
- Both: notBefore = now − 60 s; notAfter = now + 10 years. (BromureCA.swift:91–92 / BromureCa.cs:124–125.)

### 6.3 Serial number — **DIFFERENT (subtle)**
- **macOS:** 20 random bytes via `randomBytes(20)` → `Certificate.SerialNumber(bytes:)`. Sign bit can be set → may produce a 20-byte negative integer (RFC 5280 allows up to 20 bytes including sign; some clients dislike negatives but X509 lib usually masks).
- **Windows:** `new BigInteger(160, new SecureRandom()).Abs()` — strictly positive, up to 20 bytes. (BromureCa.cs:127.)
- **Status:** **DIFFERENT.** Functionally equivalent. **LOW** severity.

### 6.4 Key algorithm — **OK**
- Both: P-256 EC, signed `ecdsaWithSHA256`. (BromureCA.swift:79–110 / BromureCa.cs:117–143.)

### 6.5 Extensions — **PARTIAL**
- **macOS source:** `BasicConstraints.isCertificateAuthority(maxPathLength: 1)` (critical), `KeyUsage(keyCertSign, cRLSign)` (critical), `SubjectKeyIdentifier`. (BromureCA.swift:94–98.)
- **Windows status:** **DIFFERENT.** `new BasicConstraints(cA: true)` — **no path-length constraint** (BromureCa.cs:137). Same KeyUsage + SKI. Minor: macOS caps the chain depth at 1 intermediate, Windows does not. **LOW** severity (we issue only direct leaves anyway).

### 6.6 Key persistence — **DIFFERENT (intended)**
- **macOS:** Plain files at `~/Library/Application Support/BromureAC/ca/{cert.pem,key.pem}` with 0600 on the key (BromureCA.swift:14–18, 119–122).
- **Windows:** Public cert as plain file under `IAppPaths.MachineDataRoot`; private key DPAPI-wrapped via `ISecretStore.StoreBlob(KeyBlobName, …, LocalMachine)` (BromureCa.cs:79, 150). **Materially safer than macOS** (DPAPI binds the key to the machine; macOS leaves it as a plaintext file).
- **Status:** **DIFFERENT (improvement).**

### 6.7 SecIdentity ↔ X509Certificate2 — **OK**
- macOS uses `SecIdentityCreate` SPI (`@_silgen_name`) to bind cert+key (CertCache.swift:140–146).
- Windows round-trips through PKCS#12 + `X509Certificate2(pfx, "x", UserKeySet | Exportable)` (BromureCa.cs:160–188). Important note: explicitly NOT `EphemeralKeySet` because Schannel rejects ephemeral keys (the comment at 178–186 documents the discovery).
- **Status:** **OK** — pragmatic platform difference, well-documented.

---

## 7. CertCache (Per-Host Leaves)

### 7.1 Cache scope — **OK**
- Both: in-memory, process-lifetime, no on-disk persistence, no eviction policy. Keyed by host string lowercase (Windows uses `OrdinalIgnoreCase`, macOS lowercases manually). (CertCache.swift:11–34 / CertCache.cs:28–38.)

### 7.2 Per-host fresh EC key — **OK**
- Both: per-host P-256 EC keypair, so leaf compromise scope = one host. (CertCache.swift:40–42 / CertCache.cs:45–48 with identical rationale comments.)

### 7.3 Validity window — **OK**
- Both: notBefore = now − 24 h; notAfter = now + 365 days. Identical comment about guest clock skew. (CertCache.swift:60–71 / CertCache.cs:57–64.)

### 7.4 Extensions — **OK**
- Both: `BasicConstraints(cA=false, critical)`, `KeyUsage(digitalSignature + keyEncipherment, critical)`, `ExtendedKeyUsage([serverAuth])`, `SubjectAlternativeName` (DNS or IP). (CertCache.swift:51–56 / CertCache.cs:67–74.)

### 7.5 IP-vs-DNS SAN detection — **OK**
- Both probe `inet_pton(AF_INET)`/`inet_pton(AF_INET6)` (macOS) / `IPAddress.TryParse` (Windows). Both produce an `iPAddress` SAN when host is an IP. (CertCache.swift:111–129 / CertCache.cs:82–89.)

### 7.6 DN escaping for hostnames — **DIFFERENT (Windows extra)**
- Windows escapes `\,=+` in the DN (CertCache.cs:96–97). macOS uses `CommonName(host)` which the swift-certificates lib handles. **LOW** severity, behavioural equivalent.

---

## 8. Cloud Credentials Registries

### 8.1 ClientIdentityRegistry — **OK with one note**
- **macOS source:** CloudCredentials.swift:13–76. Per-profile `[String: Entry]` keyed by `host[:port]` lowercased, plus a duplicate entry for the bare host. Carries optional `consentCredentialID` + `consentDisplayName`.
- **Windows status:** **OK.** Registries.cs:14–63 mirrors all of this. Same indexing strategy. **LOW**: macOS NSLock vs Windows monitor — irrelevant.

### 8.2 ClusterCATrustRegistry — **OK**
- Same shape, same lazy port-stripped indexing, same fallback-to-system-trust behaviour when the PEM is unparseable. (CloudCredentials.swift:85–137 / Registries.cs:70–127.)

### 8.3 PEM parsing — **DIFFERENT (Windows simpler)**
- macOS hand-rolls BEGIN/END marker scanning (CloudCredentials.swift:126–136).
- Windows uses a regex (Registries.cs:108–120).
- Functionally equivalent. **LOW**.

---

## 9. KubeconfigMaterializer

### 9.1 YAML shape (current-context position) — **DIFFERENT**
- **macOS source:** CloudCredentials.swift:303–318 emits the YAML with `current-context:` **at the top**, immediately after the header.
- **Windows status:** **DIFFERENT — current-context at bottom.**
- **Detail:** KubeconfigMaterializer.cs:135–145 puts `current-context:` after `users:`. Both are valid YAML; kubectl parses by key, so this is purely cosmetic. **LOW**.

### 9.2 `safeName` slug — **DIFFERENT**
- **macOS source:** `entry.id.uuidString.prefix(8).lowercased()` when name is empty (CloudCredentials.swift:203).
- **Windows status:** `entry.Id.ToString("D")[..8]` — same 8 chars but **NOT forced lowercase**. C# Guids serialise lowercase by default so this happens to match, but the behaviour is platform-dependent. **LOW**.

### 9.3 Throwaway client-cert key algorithm — **DIFFERENT**
- **macOS source:** P-256 EC, signed ecdsaWithSHA256 (CloudCredentials.swift:347–367). Critically uses **one key for both signing and the PEM payload** — comment at line 343–345 says *"Two keys = mismatch + kubectl rejects on load."*
- **Windows status:** **DIFFERENT.** Uses RSA-2048 + SHA256 PKCS#1 v1.5 (KubeconfigMaterializer.cs:198–215). The single-key invariant is preserved.
- **Status:** **MEDIUM.** kubectl loads both. The bytes never authenticate anything (the proxy re-handshakes upstream). Divergent crypto, but functionally equivalent.

### 9.4 Throwaway cert PEM line wrapping — **MEDIUM (Windows bug-smell)**
- KubeconfigMaterializer.cs:203–214: the `.Chunk(64).Aggregate(...)` chain is awkward and produces 64-char lines. macOS uses BC's standard PEM serialisation (`cert.serializeAsPEM().pemString`) which produces standard line widths. **LOW** — kubectl parses either.

### 9.5 Fake token format — **DIFFERENT**
- **macOS source:** `"brm-k8s-" + 32-byte hex` (64 hex chars) → 72 chars total (CloudCredentials.swift:328–331).
- **Windows status:** 40-char random base62 string (KubeconfigMaterializer.cs:161–170).
- **Impact:** The token **shape** the in-VM kubectl sees differs across platforms. The proxy looks it up by exact match in the swap map, so it works — but log lines / trace inspector output will look very different. **LOW**.

### 9.6 `makeSecIdentity` / `TryBuildIdentity` — **DIFFERENT**
- macOS tries PKCS#8 with RSA + EC type-hints, falls back to RSA PRIVATE KEY and EC PRIVATE KEY markers (CloudCredentials.swift:381–429).
- Windows uses `X509Certificate2.CreateFromPem(certPem, keyPem)` (KubeconfigMaterializer.cs:172–189). The .NET API accepts PKCS#8, PKCS#1 RSA, and SEC1 EC keys.
- **Status:** **OK** — both cover the same set of inbound formats. Windows uses `EphemeralKeySet` here (line 181) — fine for *client* certs in `SslClientAuthenticationOptions`, but contrast with BromureCa's deliberate avoidance of EphemeralKeySet (gap 6.7). Worth checking if mTLS upstream handshakes actually work with this.

### 9.7 **ExecCredentialPoller — CRITICAL MISSING**
- **macOS source:** CloudCredentials.swift:451–551 — `@MainActor public final class ExecCredentialPoller` runs a `Task` per kubeconfig exec-plugin entry, spawning the configured `command` + `args`, parsing the resulting `ExecCredential` JSON's `status.token` field, and pushing the fresh token into the `TokenSwapper` via `updateSwap()`. The previous consent metadata is preserved when refreshing. Sleeps for `refreshSeconds` between calls. Stopped via `stopAll()` from `UnregisterAsync`.
- **Windows status:** **MISSING.** Grep across `windows/`: zero hits for `ExecCredentialPoller`, `ExecPoller`, or `RunExec`.
- **Detail:** KubeconfigMaterializer.cs:21–23 admits the gap: *"The macOS port also drives an exec-credential poller for the kubectl exec-plugin flow. That poller belongs to a follow-up port."* The `ExecContext` records are emitted (line 125), but **never consumed**. Consequences:
  - `aws-iam-authenticator`, `gke-gcloud-auth-plugin`, `eks-pod-identity-agent` and every other exec-plugin auth method is **broken on Windows**: the swap map carries an empty real token (line 124: `RealToken=""`), so the proxy substitutes the fake → empty string and the API server returns 401.
  - This is a Day-1 reproducible failure for any AWS EKS user.

### 9.8 `bearerSwaps` includes `consentCredentialId` from `ExecPlugin` entries — **OK**
- Both pass `consentCredentialId = entry.requireApproval ? ConsentCredentialID.kubeconfig(id) : nil` into the BearerSwap before the poller fills the real token. The `ExecCredentialPoller` (when ported) must preserve this on update; macOS does that explicitly at line 542–544.

### 9.9 ClientIdentitySpec dispatch on session launch — **MISSING on Windows**
- **macOS source:** BromureAC.swift:2080–2098: walks `kubeMat.clientIdentities` → `engine.clientIdentities.setIdentity(...)`, then `kubeMat.clusterCAs` → `engine.clusterCAs.setCA(...)`, then **starts the exec poller**.
- **Windows status:** **MISSING.** SessionViewModel.cs:228–244 only emits `homeFiles[".kube/config"]`; it never feeds `matz.ClientIdentities`, `matz.ClusterCas`, or `matz.ExecContexts` into the engine. So client-cert-auth kubeconfigs **and** cluster-CA-pinned kubeconfigs are both ignored on the wire. (Bearer-token kubeconfigs work, because the proxy's swap map gets populated via the bearerSwaps — but I see no call to `Swapper.AppendEntries(matz.BearerSwaps...)` either. Need to confirm.)

---

## 10. ISecretStore / PassphraseKeychain Equivalent

### 10.1 API shape — **OK**
- Both expose `(service, account) -> value` semantics. macOS `kSecClassGenericPassword` with hard-coded service `"io.bromure.agentic-coding.ssh-key-passphrases"`. Windows `WindowsSecretStore.StoreSecret(service, account, value)` uses target `"Bromure.AC:{service}:{account}"`.

### 10.2 Call sites — **PARTIAL**
- **macOS PassphraseKeychain callers:** BromureAC.swift:3164 (set), 3186 (delete), 3209 (get) — all in the SSH key import / load path. PARITY_IGNORE says ISecretStore "covers all callers."
- **Windows status:** Zero SSH callers. **The PARITY_IGNORE assertion is incorrect** — ISecretStore *contractually* covers it, but no Windows code actually calls it for SSH key passphrases. (Used only by Enrollment.)

### 10.3 Encoding — **DIFFERENT**
- macOS stores the passphrase as raw UTF-8 bytes in `kSecValueData`.
- Windows encodes via `Encoding.Unicode` (UTF-16LE) in CredWrite (WindowsSecretStore.cs:25). **LOW** — opaque to callers as long as they call back through the same API.

### 10.4 Size limits — **DIFFERENT**
- macOS Keychain: effectively unlimited for generic passwords.
- Windows Credential Manager: hard-capped at 2500 bytes (WindowsSecretStore.cs:26). Blobs > 2.5 KB must route to `StoreBlob` (DPAPI). SSH passphrases are tiny so this is fine.

### 10.5 Scope — **DIFFERENT**
- macOS `kSecClassGenericPassword` scoped to the bundle ID — user-only.
- Windows `CRED_PERSIST_LOCAL_MACHINE` (WindowsSecretStore.cs:38) — **persists across users on shared machines**. PARITY_IGNORE flags this as intended for kiosk deployments. **MEDIUM**: a security-conscious user would expect their passphrases to be wiped when their Windows account is deleted; with LocalMachine persistence they survive.

---

## 11. Audit Events (`credential.ssh_sign`)

### 11.1 SSH-sign audit event — **MISSING on Windows**
- **macOS source:** SSHAgent.swift:209–216 and 263–270 emit `BACEventEmitter.shared.emitDetached(profileID, eventType: "credential.ssh_sign", eventData: { key_label, key_fingerprint_sha256, key_kind })` once per signature, distinguishing `"managed"` vs `"imported"` keys.
- **Windows status:** **MISSING.**
- **Detail:** `SshAgentServer.HandleSignRequestAsync` has no `OnCloudEvent` invocation. No equivalent emission anywhere. Also broadly flagged in 02-http-proxy.md, but specifically for SSH it's a hole: signature events are audit-relevant.

### 11.2 SHA-256 fingerprint format — **DIFFERENT**
- **macOS:** `"SHA256:" + base64(sha256(publicBlob)).stripped("=")` — matches `ssh-keygen -lf` format (SSHAgent.swift:279–284).
- **Windows:** `FingerprintHex(key)` returns hex (SshAgentServer.cs:142–149). **DIFFERENT format** — when audit events get wired up, this will produce inconsistent fingerprints across the macOS/Windows fleet for the same key.

---

## 12. Misc / Configuration

### 12.1 `MitmException` vs `MitmError` — **OK**
- Discrete cases line up. Windows merges `tlsReadFailed`/`tlsWriteFailed` into the enum but does not surface them as factories (MitmException.cs:18–37). **LOW**.

### 12.2 `PrivateSshAgent` orphan-reaping — **N/A**
- macOS reaps stale `ssh-agent` processes from prior crashes (PrivateSSHAgent.swift:67–117). Windows doesn't fork a subprocess (in-process named pipe), so no analogue is needed.

### 12.3 BromureCA's `secCertificate` / `secPrivateKey` exposure — **N/A**
- macOS exposes SecCertificate + SecKey on BromureCA for upstream `URLSession` mTLS. Windows replaces with `X509Certificate2` on `ServerCertificate`. Pragmatic difference.

---

## 13. Summary Table — Gap Count by Severity

| Severity | Count | Areas |
|----------|-------|-------|
| **CRITICAL** | 6 | 1.1 no SSH agent listener; 1.2 no SetKeys at launch; 1.5 no PrivateSshAgent forward; 3.3 no `SshKeyRequiresApproval`; 5.1 no imported-key approval wiring; 9.7 no ExecCredentialPoller |
| **HIGH** | 4 | 1.3 no Serve loop; 1.4 PrivateSshAgent is profile-blind; 3.1 DefaultSshKey never invoked; 9.9 no ClientIdentitySpec/ClusterCAs dispatch on launch |
| **MEDIUM** | 4 | 2.1 only ed25519 (RSA/ECDSA missing); 2.2 RSA-SHA2 flags dropped (deferred consequence of 2.1); 5.2 imported-key passphrase flow missing; 5.3 importSSHKey helper missing; 9.3 throwaway cert key algo difference; 10.5 LocalMachine secret scope; 11.1 missing ssh_sign audit event |
| **LOW** | 7 | 3.2 file paths; 3.5 file perms; 6.3 serial sign-bit; 6.5 missing maxPathLength; 7.6 DN escaping; 9.1–9.6 YAML/cosmetic; 11.2 fingerprint format; 12.1 exception factories |

---

## 14. Top 5 Most Impactful Gaps

1. **#1.1 + #1.2 — The Windows SSH agent has no listener and no keys.** The entire ssh-agent feature is functionally dead. Nothing inside the VM can sign with a bromure-managed SSH key. `MitmEngine.SshAgent` is plumbed structurally but never wired to a VM bridge nor populated. This needs a vsock/hvsocket/9p listener + a `SessionViewModel` call to `SetKeys` at launch.
2. **#9.7 — ExecCredentialPoller is completely missing.** Every kubeconfig that uses an exec plugin (the default for AWS EKS, GKE, AKS) will silently 401. This is a Day-1 reproducible failure for the most common cloud-Kubernetes setups.
3. **#9.9 — Client-cert + cluster-CA kubeconfigs are ignored on the wire.** `KubeconfigMaterializer.Materialize` returns `ClientIdentities` and `ClusterCas`, but `SessionViewModel` never plumbs them into `MitmEngine.ClientIdentities` / `MitmEngine.ClusterCaTrust`. Bearer-token kubeconfigs may work; mTLS / private-CA kubeconfigs definitely don't.
4. **#5.1 + #5.2 + #5.3 — Imported SSH keys are unusable AND less secure.** Windows has no passphrase keychain wiring, no `importSSHKey` helper, no ssh-add forwarding, no per-key approval registration. Worse, `ImportedSshKey.PrivateKeyPem` stores the *plaintext PEM* in profile JSON, vs macOS's encrypted-PEM-on-disk-plus-Keychain-passphrase model. Security regression.
5. **#3.3 — `SshKeyRequiresApproval` consent flag is missing from the Profile model.** Even if the SSH agent listener gets wired (gap #1), there is no field on `Profile` to drive the per-sign consent prompt for the auto-generated bromure key. Users would have no way to opt into being prompted.
