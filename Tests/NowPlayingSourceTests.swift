import Foundation

@main
struct NowPlayingSourceTests {
    static func main() {
        let sources = [NowPlayingAudioSource(id: "pid-1419", bundleIDs: ["com.apple.WebKit.GPU"]), NowPlayingAudioSource(id: "com.apple.Music", bundleIDs: ["com.apple.Music"])]
        precondition(nowPlayingSourceID(bundleIdentifier: "com.apple.WebKit.GPU", sources: sources) == "pid-1419")
        precondition(nowPlayingSourceID(bundleIdentifier: "com.apple.Music", sources: sources) == "com.apple.Music")
        precondition(nowPlayingSourceID(bundleIdentifier: "com.apple.Safari", sources: sources) == nil)
        precondition(nowPlayingSourceID(bundleIdentifier: "unknown", sources: sources) == nil)
        precondition(nowPlayingSourceID(bundleIdentifier: "com.apple.WebKit.GPU", sources: sources + [NowPlayingAudioSource(id: "pid-2", bundleIDs: ["com.apple.WebKit.GPU"])]) == nil)
        testSourceMetadata()
        testMetadataCache()
        print("Now Playing source matching and metadata lifecycle tests passed")
    }
    static func testSourceMetadata() {
        let safari = BrowserAudioMetadata(bundleID: "com.apple.Safari", name: "Safari", titles: ["Background video", "Another stream"])
        let webkit = AudioMetadataSource(id: "pid-1", bundleIDs: ["com.apple.WebKit.GPU"], isProducingAudio: true, isUnresolvedWebKit: true)
        let confirmed = AudioMetadataSource(id: "com.apple.Safari", bundleIDs: ["com.apple.Safari"], isProducingAudio: true, isUnresolvedWebKit: false)
        let silent = AudioMetadataSource(id: "com.apple.Safari", bundleIDs: ["com.apple.Safari"], isProducingAudio: false, isUnresolvedWebKit: false)
        func resolve(_ sources: [AudioMetadataSource], _ browsers: [BrowserAudioMetadata] = [safari], _ titles: [String: String] = [:]) -> [String: AudioSourceMetadata] {
            resolveAudioSourceMetadata(sources: sources, browsers: browsers, clientTitles: titles, global: .unavailable)
        }
        precondition(resolve([webkit])[webkit.id]?.titles == safari.titles)
        precondition(resolve([confirmed])[confirmed.id]?.titles == safari.titles)
        precondition(resolve([silent]).isEmpty, "Stopped audio must clear titles")
        precondition(resolve([webkit, silent])[webkit.id]?.titles == safari.titles, "Silent app rows cannot steal a live client")
        let other = AudioMetadataSource(id: "pid-2", bundleIDs: ["com.apple.WebKit.GPU"], isProducingAudio: true, isUnresolvedWebKit: true)
        precondition(resolve([webkit, other]).isEmpty, "Ambiguous clients cannot be assigned to one tab")
        precondition(resolve([webkit], []).isEmpty, "Missing permission or closed tabs must clear previous metadata")
        precondition(resolve([webkit], [], [webkit.id: " Media title "])[webkit.id]?.summary == "Media title")
        precondition(resolve([webkit], [safari], [webkit.id: "Only one media item"])[webkit.id]?.titles.count == 2)
        let chrome = AudioMetadataSource(id: "com.google.Chrome", bundleIDs: ["com.google.Chrome.helper"], isProducingAudio: true, isUnresolvedWebKit: false)
        let chromeTabs = BrowserAudioMetadata(bundleID: chrome.id, name: "Chrome", titles: ["Audio test"])
        precondition(resolve([chrome], [chromeTabs])[chrome.id]?.summary == "Audio test")
        let music = AudioMetadataSource(id: "com.apple.Music", bundleIDs: ["com.apple.Music"], isProducingAudio: true, isUnresolvedWebKit: false)
        let track = resolve([music], [], [music.id: "Track — Artist"])[music.id]
        precondition(track?.summary == "Track — Artist" && track?.label == "Faixa atual")
        let inactiveMusic = AudioMetadataSource(id: music.id, bundleIDs: music.bundleIDs, isProducingAudio: false, isUnresolvedWebKit: false)
        precondition(resolve([inactiveMusic], [], [music.id: "Previous track"]).isEmpty)
        precondition(audioMediaDisplayTitle(title: " Track\nname ", artist: "Artist") == "Track name — Artist")
        precondition(cleanedAudioTitle(" \n ") == nil)
        var paused = MediaRemoteNowPlayingSnapshot.unavailable
        paused = MediaRemoteNowPlayingSnapshot(frameworkLoaded: true, requestClassAvailable: true, playerPathAvailable: true,
            clientAvailable: true, bundleIdentifier: webkit.bundleIDs[0], title: "Old paused title", playbackRate: 0, status: "media-paused", exceptionName: nil)
        precondition(paused.verifiedTitle == nil)
    }

    static func testMetadataCache() {
        let source = AudioMetadataSource(id: "pid-1419", bundleIDs: ["com.apple.WebKit.GPU"], isProducingAudio: true, isUnresolvedWebKit: true)
        let browser = BrowserAudioMetadata(pid: 1326, bundleID: "com.apple.Safari", name: "Safari", titles: ["Video A"])
        let fresh = resolveAudioSourceMetadata(sources: [source], browsers: [browser], clientTitles: [:], global: .unavailable)
        var cache = AudioSourceMetadataCache()
        precondition(cache.apply(sources: [source], browsers: [browser], fresh: fresh)[source.id]?.isCached == false)
        let saved = cache
        _ = cache.apply(sources: [source], browsers: [browser], fresh: fresh)
        precondition(cache == saved, "Identical polls must not rewrite persistent cache")
        let persisted = try! JSONEncoder().encode(cache)
        cache = try! JSONDecoder().decode(AudioSourceMetadataCache.self, from: persisted)
        let empty = BrowserAudioMetadata(pid: 1326, bundleID: browser.bundleID, name: "Safari", titles: [])
        let fallback = cache.apply(sources: [source], browsers: [empty], fresh: [:])[source.id]
        precondition(fallback?.titles == ["Video A"] && fallback?.browserBundleID == browser.bundleID && fallback?.isCached == true, "Empty read preserves title/icon identity across Mixer restart")
        precondition(cache.apply(sources: [source], browsers: [], fresh: [:]).isEmpty, "Closed browser invalidates the active association")
        let restarted = BrowserAudioMetadata(pid: 9999, bundleID: browser.bundleID, name: "Safari", titles: [])
        precondition(cache.apply(sources: [source], browsers: [restarted], fresh: [:]).isEmpty, "Different browser process cannot inherit old WebKit identity")
        let updated = BrowserAudioMetadata(pid: 1326, bundleID: browser.bundleID, name: "Safari", titles: ["Video B"])
        let newData = resolveAudioSourceMetadata(sources: [source], browsers: [updated], clientTitles: [:], global: .unavailable)
        precondition(cache.apply(sources: [source], browsers: [updated], fresh: newData)[source.id]?.titles == ["Video B"], "Fresh title replaces the cached title immediately")
    }

}
