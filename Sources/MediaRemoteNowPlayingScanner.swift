import Foundation
import Carbon

struct MediaRemoteNowPlayingSnapshot: Equatable {
    let frameworkLoaded: Bool
    let requestClassAvailable: Bool
    let playerPathAvailable: Bool
    let clientAvailable: Bool
    let bundleIdentifier: String?
    let title: String?
    let playbackRate: Double?
    let status: String
    let exceptionName: String?

    var verifiedTitle: String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              status != "client-changed", status != "exception",
              playbackRate == nil || playbackRate! > 0 else { return nil }
        return cleanedAudioTitle(title)
    }

    var diagnosticLine: String {
        let bundle = bundleIdentifier ?? "none"
        let rate = playbackRate.map { String(format: "%.2f", $0) } ?? "none"
        let exception = exceptionName.map { " exception=\($0)" } ?? ""
        return "mediaRemote loaded=\(frameworkLoaded) class=\(requestClassAvailable) path=\(playerPathAvailable) client=\(clientAvailable) hasTitle=\(title != nil) bundleId=\(bundle) rate=\(rate) status=\(status)\(exception)"
    }

    static let unavailable = MediaRemoteNowPlayingSnapshot(
        frameworkLoaded: false,
        requestClassAvailable: false,
        playerPathAvailable: false,
        clientAvailable: false,
        bundleIdentifier: nil,
        title: nil,
        playbackRate: nil,
        status: "not-scanned",
        exceptionName: nil
    )
}

final class MediaRemoteNowPlayingScanner {
    func scan() -> MediaRemoteNowPlayingSnapshot {
        let result = MXBReadMediaRemoteNowPlaying() as? [String: Any] ?? [:]
        return MediaRemoteNowPlayingSnapshot(
            frameworkLoaded: result["frameworkLoaded"] as? Bool ?? false,
            requestClassAvailable: result["classAvailable"] as? Bool ?? false,
            playerPathAvailable: result["playerPathAvailable"] as? Bool ?? false,
            clientAvailable: result["clientAvailable"] as? Bool ?? false,
            bundleIdentifier: result["bundleIdentifier"] as? String,
            title: audioMediaDisplayTitle(title: result["title"] as? String, artist: result["artist"] as? String),
            playbackRate: (result["rate"] as? NSNumber)?.doubleValue,
            status: result["status"] as? String ?? "unavailable",
            exceptionName: (result["exception"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

struct NowPlayingAudioSource {
    let id: String
    let bundleIDs: [String]
}

func nowPlayingSourceID(bundleIdentifier: String?, sources: [NowPlayingAudioSource]) -> String? {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
    let matches = sources.filter { $0.id == bundleIdentifier || $0.bundleIDs.contains(bundleIdentifier) }
    return matches.count == 1 ? matches[0].id : nil
}

struct NowPlayingClientTarget: Sendable {
    let sourceID: String
    let bundleID: String
    let pid: Int
}
struct NowPlayingClientResult: Sendable {
    let sourceID: String
    let bundleID: String
    let title: String?
    let status: String
}
func readNowPlayingClients(_ targets: [NowPlayingClientTarget]) -> [NowPlayingClientResult] {
    var seen = Set<String>()
    let unique = targets.filter { seen.insert("\($0.pid):\($0.bundleID)").inserted }
    let args = unique.map { ["sourceID": $0.sourceID, "bundleIdentifier": $0.bundleID, "pid": $0.pid] as [String: Any] }
    return MXBReadMediaRemoteClients(args).compactMap { value in
        guard let sourceID = value["sourceID"] as? String, let bundleID = value["bundleIdentifier"] as? String else { return nil }
        return NowPlayingClientResult(sourceID: sourceID, bundleID: bundleID,
            title: audioMediaDisplayTitle(title: value["title"] as? String, artist: value["artist"] as? String), status: value["status"] as? String ?? "unknown")
    }
}

// Music exposes current-track metadata through its supported scripting dictionary.
// The audio catalog gates this read; player state may lag during buffering or transitions.
// This child inherits the app's normal Automation consent; no private entitlement.
func readMusicTrack(_ targets: [NowPlayingClientTarget]) -> [NowPlayingClientResult] {
    guard let target = targets.first(where: { $0.bundleID == "com.apple.Music" }) else { return [] }
    let receiver = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
    let consent = AEDeterminePermissionToAutomateTarget(receiver.aeDesc, typeWildCard, typeWildCard, true)
    guard consent == noErr else {
        return [NowPlayingClientResult(sourceID: target.sourceID, bundleID: target.bundleID, title: nil, status: "music-automation-status-\(consent)")]
    }
    let script = """
    with timeout of 3 seconds
        if application id "com.apple.Music" is not running then return ""
        tell application id "com.apple.Music"
            set trackTitle to name of current track
            set trackArtist to artist of current track
            if trackArtist is "" then return trackTitle
            return trackTitle & " — " & trackArtist
        end tell
    end timeout
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch {
        return [NowPlayingClientResult(sourceID: target.sourceID, bundleID: target.bundleID, title: nil, status: "music-script-launch-failed")]
    }
    let deadline = Date().addingTimeInterval(4)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
    guard !process.isRunning else {
        process.terminate()
        return [NowPlayingClientResult(sourceID: target.sourceID, bundleID: target.bundleID, title: nil, status: "music-script-timeout")]
    }
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let status = process.terminationStatus != 0 ? (error.contains("-1743") ? "music-automation-denied" : "music-script-error") : (text.isEmpty ? "music-no-current-track" : "music-track")
    return [NowPlayingClientResult(sourceID: target.sourceID, bundleID: target.bundleID, title: process.terminationStatus == 0 && !text.isEmpty ? text : nil, status: status)]
}

