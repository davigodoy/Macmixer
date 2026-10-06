import Foundation

@main
struct ExceptionBridgeTests {
    static func main() {
        var error: NSError?
        precondition(MXBTestExceptionCatcher(false, &error), "Objective-C bridge allows a normal operation")
        precondition(error == nil, "normal operation leaves no error")
        precondition(!MXBTestExceptionCatcher(true, &error), "Objective-C bridge catches NSException")
        precondition(error?.domain == "com.codex.mixer.objc-exception", "caught exception becomes an NSError")
        precondition(error?.localizedDescription == "synthetic exception", "caught exception keeps its reason")
        print("Objective-C exception bridge tests passed")
    }
}
