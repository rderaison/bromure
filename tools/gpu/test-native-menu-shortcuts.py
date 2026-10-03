#!/usr/bin/env python3
"""Exercise actual host shortcut map through AppKit menu dispatch."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "Sources/Browser/SafariSandbox.swift").read_text()
start = source.index("    static let nativeMenuShortcutChords:")
end = source.index("\n    ]", start) + 6
mapping = source[start:end].replace("static let", "let", 1)
PREFIX = 'import AppKit\nlet app = NSApplication.shared\nfinal class Receiver: NSObject {\n var received = 0\n @objc func invoke(_ sender: Any?) { received += 1 }\n}\nlet receiver = Receiver()\n'
SUFFIX = '\nfor (_, chord) in nativeMenuShortcutChords {\n let menu = NSMenu(); menu.autoenablesItems = false\n let item = NSMenuItem(title: "Action", action: #selector(Receiver.invoke(_:)), keyEquivalent: chord.character)\n item.target = receiver; item.keyEquivalentModifierMask = chord.modifiers; menu.addItem(item)\n let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: chord.character, charactersIgnoringModifiers: chord.character, isARepeat: false, keyCode: 0)!\n let before = receiver.received\n precondition(menu.performKeyEquivalent(with: event)); precondition(receiver.received == before + 1)\n item.isEnabled = false\n _ = menu.performKeyEquivalent(with: event); precondition(receiver.received == before + 1)\n}\nprint("APPKIT_MENU_SHORTCUTS_PASS count=\\(receiver.received)")\n'
with tempfile.TemporaryDirectory(prefix="bromure-menu-shortcuts-") as directory:
    fixture = pathlib.Path(directory) / "main.swift"
    fixture.write_text(PREFIX + mapping + SUFFIX)
    subprocess.run(["swift", str(fixture)], check=True, timeout=60)
