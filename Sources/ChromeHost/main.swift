import Darwin
import Foundation

// TabScoutChromeHost: Chrome starts this helper when Tab Scout's extension connects to it, and talks to it over
// standard input and output. It passes whole messages between the extension and the Tab Scout app's socket. While
// Tab Scout is not running it tries again every second, so the extension stays connected and is ready the moment
// the app starts. It talks only to the app in its own bundle, checked by code signature.

signal(SIGPIPE, SIG_IGN)
// Contents/MacOS/TabScoutChromeHost inside Tab Scout.app.
let appURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let lock = NSLock()
var app: Int32 = -1

func setApp(_ socket: Int32) {
    lock.lock()
    defer { lock.unlock() }
    if app >= 0 { close(app) }
    app = socket
}

// From the extension to the app; replies arriving while the app is away are dropped. Chrome closing the
// connection ends the helper.
Thread.detachNewThread {
    while let message = NativeMessage.read(from: STDIN_FILENO) {
        lock.lock()
        if app >= 0 { _ = NativeMessage.write(NativeMessage.frame(message), to: app) }
        lock.unlock()
    }
    exit(0)
}

// From the app to the extension.
while true {
    let socket = NativeMessage.connect(to: NativeMessage.socketURL)
    if socket >= 0 {
        if CodeIdentity.peer(of: socket, isSignedLike: appURL) {
            // The app greets each helper it lets in. One turned away is out of date, after Tab Scout was rebuilt,
            // so it quits and the extension starts the current one.
            guard NativeMessage.read(from: socket) != nil else { exit(0) }
            setApp(socket)
            while let message = NativeMessage.read(from: socket) {
                guard NativeMessage.write(NativeMessage.frame(message), to: STDOUT_FILENO) else { exit(0) }
            }
            setApp(-1)
        } else {
            close(socket)
        }
    }
    sleep(1)
}
