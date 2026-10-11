import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // All functionality uses browser APIs; native messages process no user data.
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
