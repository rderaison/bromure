#!/usr/bin/env python3
"""Sync the iOS fat-client source farm.

The iOS target (ios/BromureRemote) compiles a SUBSET of Sources/AgentCoding
plus its own iOS-only files. Rather than fork those shared files, we symlink
them into ios/BromureRemote/Sources/BromureRemote/_shared/ so the SwiftPM
target (and the generated Xcode project) build the exact same sources the
macOS app does. Run this after adding/removing a shared file.

    python3 scripts/gen-ios-sources.py
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "Sources", "AgentCoding")
DST = os.path.join(REPO, "ios", "BromureRemote", "Sources", "BromureRemote", "_shared")

# The fat-client subset: transport, models, stores, and the platform-guarded
# shared SwiftUI views. Terminal/ is Ghostty (macOS) EXCEPT GridLayoutStore.
# BromureAC.swift, AutomationServer.swift, SessionPane, the *Window NSWindow
# hosts, SessionDisk, UbuntuSandboxVM, browser/VM/MITM engine files, and the
# Ghostty terminal surfaces are macOS-only and deliberately excluded.
SHARED = [
    # Transport + protocol
    "FatClient.swift",
    "FatClientTypes.swift",
    "FatClientSSHDial.swift",
    "FatClientNIOSSH.swift",
    "FatClientFleet.swift",
    "FatClientPAC.swift",
    "ControlClient.swift",
    # Models + stores (the mirror reconciles /state into these)
    "SessionModels.swift",
    "Profile.swift",
    "CodingTasks.swift",
    "ScheduledAutomations.swift",
    # Policy / token / routing types Profile.swift and the mirror reference.
    "Mitm/TraceRecord.swift",
    "Mitm/PromptInjectionPolicy.swift",
    "Mitm/SupplyChainPolicy.swift",
    "Mitm/GuardrailsPolicy.swift",
    "Mitm/SecretsVault.swift",
    "Mitm/SessionTokenPlan.swift",
    "SubscriptionTokenSwapState.swift",
    "Mitm/ConsentCredentialID.swift",
    "FatForward.swift",
    "Terminal/GridLayoutStore.swift",
    "Terminal/TerminalImagePaste.swift",  # pure upload core (AppKit parts #if'd out)
    # Controller + connect flow (models; iOS provides the views)
    "FatClientController.swift",
    "FatClientConnect.swift",
    # Shared, platform-guarded SwiftUI views + support
    "PlatformShims.swift",
    "SharedStatusViews.swift",
    "Icons.swift",
    "BACDebug.swift",
    "TerminalAppDefaults.swift",
    "FileExplorer.swift",
    "FileExplorerViews.swift",
    "FileBrowserView.swift",
    "AutomationKanbanView.swift",
    "CodingKanbanView.swift",
    "ScheduledAutomationViews.swift",
    "AutomationRunWindow.swift",
    "AutomationRunArchive.swift",
    "ClaudeTranscriptView.swift",
    "PushCrypto.swift",  # HPKE seal/open — shared by the Mac sender + iOS NSE
    "ConversationView.swift",
    "VMDashboard.swift",
    "DockerDashboard.swift",
    "TaskReviewWindow.swift",
    "TaskTranscriptWindow.swift",
    "TaskTranscriptArchive.swift",
    # P2P client transport (reach a NAT'd server) — all Darwin/URLSession/Crypto
    "P2P/ControlPlaneClient.swift",
    "P2P/DeviceChannel.swift",
    "P2P/DeviceIdentity.swift",
    "P2P/P2PBroker.swift",
    "P2P/P2PCandidate.swift",
    "P2P/P2PEnroll.swift",
    "P2P/P2PEnrollmentCoordinator.swift",
    "P2P/P2PIdentity.swift",
    "P2P/P2PSignaling.swift",
    "P2P/P2PTransport.swift",
    "P2P/PortMap.swift",
    "P2P/STUN.swift",
    "P2P/TurnRelayTransport.swift",
    "P2P/TurnTCP.swift",
    "P2P/TurnTLS.swift",
]


def main():
    if os.path.isdir(DST):
        for name in os.listdir(DST):
            p = os.path.join(DST, name)
            if os.path.islink(p) or os.path.isfile(p):
                os.remove(p)
    else:
        os.makedirs(DST)

    missing = []
    for rel in SHARED:
        src = os.path.join(SRC, rel)
        if not os.path.exists(src):
            missing.append(rel)
            continue
        # Flatten subdir names so every symlink is a sibling (SwiftPM globs the
        # target dir recursively, but a flat farm keeps the listing legible).
        link = os.path.join(DST, rel.replace("/", "__"))
        rel_target = os.path.relpath(src, DST)
        os.symlink(rel_target, link)

    if missing:
        print("MISSING shared files:", ", ".join(missing), file=sys.stderr)
        return 1
    print(f"linked {len(SHARED)} shared files into {os.path.relpath(DST, REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
