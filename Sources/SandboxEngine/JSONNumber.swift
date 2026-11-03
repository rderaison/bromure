import Foundation

/// What JSONSerialization put in an NSNumber, on either Foundation: Apple's
/// answers through CoreFoundation; the open-source one (Linux) has no CF
/// calls, but its type encodings tell the same apart.
extension NSNumber {
    /// Made from `true`/`false`: a CFBoolean on Apple platforms; elsewhere
    /// an `__NSCFBoolean`, encoding "c" (JSON numbers come out as "i", "q"
    /// or "d"; `is Bool` would also match 0 and 1 there).
    public var isJSONBoolean: Bool {
        #if canImport(ObjectiveC)
        return CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        return String(cString: objCType) == "c"
        #endif
    }

    /// Holds a floating-point value (a JSON number with a fraction or exponent).
    public var isJSONFloat: Bool {
        #if canImport(ObjectiveC)
        return CFNumberIsFloatType(self)
        #else
        let t = String(cString: objCType)
        return t == "d" || t == "f"
        #endif
    }
}
