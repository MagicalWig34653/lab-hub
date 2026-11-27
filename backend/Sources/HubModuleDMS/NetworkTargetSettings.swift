import Foundation
import HubCore

/// WP-ST3: Der Schalter für interne Ziele ist eine Einstellung des DMS (Mail-Quelle, Paperless-Import); die Zieladress-Prüfung im Kern kennt ihn nicht.
extension NetworkTargetPolicy {
    /// Betreiber erlauben interne Ziele nur ausdrücklich mit `DMS_ALLOW_INTERNAL_TARGETS=true` (Test/Heim-Setups).
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> NetworkTargetPolicy {
        NetworkTargetPolicy(allowInternal: env["DMS_ALLOW_INTERNAL_TARGETS"]?.lowercased() == "true")
    }
}
