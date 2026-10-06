import Foundation

struct BrowserAudioMetadata: Equatable, Sendable {
    var pid: Int32? = nil
    var tabs: [BrowserTabReference] = []
    let bundleID: String
    let name: String
    let titles: [String]
}

struct AudioMetadataSource {
    let id: String
    let bundleIDs: [String]
    let isProducingAudio: Bool
    let isUnresolvedWebKit: Bool
}

struct AudioSourceMetadata: Equatable {
    let titles: [String]
    var label: String
    let method: String
    var browserBundleID: String? = nil
    var browserPID: Int32? = nil
    var tabs: [BrowserTabReference] = []
    var isCached = false

    var summary: String { titles.joined(separator: " · ") }
}

/// Match only current audio clients. A browser's frontmost tab is never evidence
/// that it produces audio. Multiple unresolved WebKit clients remain ambiguous.
func resolveAudioSourceMetadata(
    sources: [AudioMetadataSource],
    browsers: [BrowserAudioMetadata],
    clientTitles: [String: String],
    global: MediaRemoteNowPlayingSnapshot
) -> [String: AudioSourceMetadata] {
    let active = sources.filter(\.isProducingAudio)
    let globalID = nowPlayingSourceID(bundleIdentifier: global.bundleIdentifier,
        sources: active.map { NowPlayingAudioSource(id: $0.id, bundleIDs: $0.bundleIDs) })
    var result: [String: AudioSourceMetadata] = [:]
    for source in active {
        if let title = cleanedAudioTitle(clientTitles[source.id]) {
            result[source.id] = AudioSourceMetadata(titles: [title], label: source.id == "com.apple.Music" ? "Faixa atual" : "Reproduzindo agora", method: "client-media")
        } else if source.id == globalID, let title = global.verifiedTitle {
            result[source.id] = AudioSourceMetadata(titles: [title], label: "Reproduzindo agora", method: "global-media")
        }
    }
    for browser in browsers where !browser.titles.isEmpty {
        var matches = active.filter { $0.id == browser.bundleID || $0.bundleIDs.contains(browser.bundleID) }
        var method = "browser-tabs"
        if matches.isEmpty && browser.bundleID == "com.apple.Safari" {
            matches = active.filter(\.isUnresolvedWebKit)
            method = "safari-tabs-shared-webkit"
        }
        guard matches.count == 1 else { continue }
        let id = matches[0].id
        // Keep every audible tab, even when a global media item names only one.
        let count = browser.titles.count
        let label = count == 1 ? browser.name : "\(browser.name) · \(count) abas com áudio"
        result[id] = AudioSourceMetadata(titles: browser.titles, label: label, method: method, browserBundleID: browser.bundleID, browserPID: browser.pid, tabs: browser.tabs.filter(\.audible))
    }
    return result
}

func cleanedAudioTitle(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : String(text.prefix(1_024))
}

func audioMediaDisplayTitle(title: String?, artist: String?) -> String? {
    guard let title = cleanedAudioTitle(title) else { return nil }
    guard let artist = cleanedAudioTitle(artist), artist != title else { return title }
    return "\(title) — \(artist)"
}

/// Persist presentation metadata, never AX handles or audio routing settings.
/// A cached WebKit association is reusable only for the same process and browser.
struct AudioSourceMetadataCache: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let sourceBundleIDs: [String]
        let titles: [String]
        let label: String
        let method: String
        let browserBundleID: String?
        let browserPID: Int32?
        let updatedAt: Date
    }
    private(set) var entries: [String: Entry] = [:]

    mutating func apply(sources: [AudioMetadataSource], browsers: [BrowserAudioMetadata], fresh: [String: AudioSourceMetadata]) -> [String: AudioSourceMetadata] {
        var result: [String: AudioSourceMetadata] = [:]
        for source in sources {
            let fingerprint = source.bundleIDs.sorted()
            let saved = entries[source.id].flatMap { entry -> Entry? in
                guard entry.sourceBundleIDs == fingerprint else { return nil }
                if let bundle = entry.browserBundleID {
                    guard browsers.contains(where: { $0.bundleID == bundle && $0.pid == entry.browserPID }) else { return nil }
                }
                return entry
            }
            if var value = fresh[source.id] {
                // Client metadata may arrive before the tab scan. Keep the already
                // confirmed browser identity while accepting the fresh media title.
                if value.browserBundleID == nil, let saved, let bundle = saved.browserBundleID {
                    value.browserBundleID = bundle
                    value.browserPID = saved.browserPID
                    value.label = browsers.first(where: { $0.bundleID == bundle })?.name ?? saved.label
                }
                let entry = Entry(sourceBundleIDs: fingerprint, titles: value.titles, label: value.label,
                    method: value.method, browserBundleID: value.browserBundleID, browserPID: value.browserPID,
                    updatedAt: Date())
                if let old = entries[source.id], old.sourceBundleIDs == entry.sourceBundleIDs,
                   old.titles == entry.titles, old.label == entry.label, old.method == entry.method,
                   old.browserBundleID == entry.browserBundleID, old.browserPID == entry.browserPID {
                    // No disk writes for identical one-second polls.
                } else { entries[source.id] = entry }
                result[source.id] = value
            } else if let saved {
                result[source.id] = AudioSourceMetadata(titles: saved.titles, label: saved.label,
                    method: saved.method, browserBundleID: saved.browserBundleID, browserPID: saved.browserPID,
                    isCached: true)
            }
        }
        if entries.count > 100 {
            let keep = Set(entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(100).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        return result
    }
}
