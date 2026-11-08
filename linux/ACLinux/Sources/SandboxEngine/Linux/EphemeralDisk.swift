import Foundation

/// macOS's EphemeralDisk is a clonefile(2) copy of a base image; a Linux VM's
/// disks are the daemon's own (FirecrackerMachine). The name is kept for its
/// shared free-space floor (EphemeralDisk+Space.swift), which the daemon and
/// the shared code check before they make or grow an image.
// @port-skip linux-only: the namespace of EphemeralDisk's shared free-space check (the clonefile half is macOS's)
public enum EphemeralDisk {}
