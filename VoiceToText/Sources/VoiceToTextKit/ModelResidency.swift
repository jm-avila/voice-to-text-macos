import Foundation

/// Whether a local model is in memory and waiting, for Whisper's server and
/// Parakeet alike. Settings, the HUD, and `vtt status` show it.
public enum ModelResidency: Equatable, Sendable {
    /// Not selected, or freed.
    case off
    /// Loading, or the first time downloading.
    case loading
    /// Loaded: a dictation does not wait for it.
    case ready
    /// The last load failed, and why. Picking the model again, or Try Again in Settings, loads it again.
    case failed(String)

    /// For `vtt status`.
    public var name: String {
        switch self {
        case .off: "off"
        case .loading: "loading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    public var error: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}
