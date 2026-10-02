import Foundation

/// The app-wide renderer choice applies when a VM's devices are created.
public enum MetalRendererPreference {
    public static let defaultsKey = "vm.experimentalGPU"
    public static var isSupported: Bool {
        #if arch(arm64)
        if #available(macOS 27.0, *) { return true }
        #endif
        return false
    }
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
