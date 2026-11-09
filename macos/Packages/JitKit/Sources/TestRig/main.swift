import Foundation

// Dev-only local enterprise test rig (ADR-0039). Never embedded in the app. Everything binds to 127.0.0.1.
//   TestRig git-server …   HTTP(S) front for `git http-backend` + GitLab API stub
//   TestRig proxy …        HTTP CONNECT / absolute-URI proxy and optional SOCKS5 proxy
// Prints `READY <port> <role>` per listener; exits cleanly on SIGTERM/SIGINT.

let usage = """
    usage: TestRig <git-server|proxy> [options]

    \(GitServerConfig.usage)

    \(ProxyConfig.usage)
    """

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    warn("missing command\n\(usage)")
    exit(2)
}

do {
    switch arguments[1] {
    case "git-server": try GitServer.run(arguments.dropFirst(2))
    case "proxy": try ProxyConfig.run(arguments.dropFirst(2))
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    default: throw RigError.usage("unknown command '\(arguments[1])'\n\(usage)")
    }
} catch {
    warn("\(error)")
    exit(2)
}

var signalSources: [any DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        registry.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
