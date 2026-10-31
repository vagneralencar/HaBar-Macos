import Foundation
import LocalAuthentication

@MainActor
public enum BiometricAuthHelper {
    public static var evaluator: (@Sendable (String) async -> Bool)? = nil

    public static var isBiometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func authenticate(reason: String) async -> Bool {
        if let customEvaluator = evaluator {
            return await customEvaluator(reason)
        }

        let context = LAContext()
        context.localizedCancelTitle = L10n.t("Cancelar", "Cancel")

        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
        return false
    }
}
