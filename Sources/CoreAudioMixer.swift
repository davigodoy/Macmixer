import AppKit
import AVFAudio
import ApplicationServices
import CoreAudio
import Darwin
import Foundation
import libkern
import os

struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let processIDs: [AudioObjectID]
    let processPIDs: [pid_t]
    let processAttributions: [AudioProcessAttribution]
    let isProducingAudio: Bool
    var sourceMetadata: AudioSourceMetadata?
    var hasAudioClient: Bool { !processIDs.isEmpty }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processIDs == rhs.processIDs && lhs.processPIDs == rhs.processPIDs && lhs.processAttributions == rhs.processAttributions && lhs.isProducingAudio == rhs.isProducingAudio && lhs.sourceMetadata == rhs.sourceMetadata
    }
}

struct AudioOutput: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

struct AppAudioSettings: Codable, Equatable {
    var volume: Int = 100
    var isMuted = false
    var outputUID: String?
}

private struct AudioAppCandidate {
    let id: String
    let bundleID: String?
    let processIDs: [AudioObjectID]
    let processPIDs: [pid_t]
    let processAttributions: [AudioProcessAttribution]
    let isProducingAudio: Bool
}

private struct CoreAudioSnapshot {
    let outputs: [AudioOutput]
    let defaultOutputUID: String?
    let apps: [AudioAppCandidate]
}

private struct AudioFormatRead {
    let formats: [AudioStreamBasicDescription]
    let status: OSStatus
}

private let mixerLogger = Logger(subsystem: "com.codex.mixer", category: "audio")

@MainActor
final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var permissionMessage: String?
    @Published private(set) var routeErrors: [String: String] = [:]
    @Published private(set) var diagnosticText = "Mixer iniciando…"
    @Published private(set) var browserAccessibilityTrusted = false
    @Published private(set) var browsersRunning = false
    @Published var otherAppsExpanded = false
    private var popoverLayoutDiagnostic: String?

    @Published private var savedSettings: [String: AppAudioSettings] = [:]
    private var sessions: [String: SessionRecord] = [:]
    private var refreshTask: Task<Void, Never>?
    private var sourceMetadataTask: Task<Void, Never>?
    private var browserMetadata: [BrowserAudioMetadata] = []
    private var sourceMetadataCache = AudioSourceMetadataCache()
    private var nowPlayingSnapshot = MediaRemoteNowPlayingSnapshot.unavailable
    private var clientNowPlayingTitles: [String: String] = [:]
    private var browserAXDiagnostics = "safariAX=not-scanned"
    private var mediaRemoteDiagnostics = MediaRemoteNowPlayingSnapshot.unavailable.diagnosticLine
    private var listenerRegistrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var refreshInFlight = false
    private var forceRetryPending = false
    private var isStopped = false
    private var lastDiagnosticWrite = Date.distantPast
    private let diagnosticsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Mixer/Mixer-diagnostics.txt")
    private var defaultOutputUID: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "Mixer.sourceMetadataCache"),
           let cache = try? JSONDecoder().decode(AudioSourceMetadataCache.self, from: data) { sourceMetadataCache = cache }
        if let data = UserDefaults.standard.data(forKey: "Mixer.appSettings"),
           let decoded = try? JSONDecoder().decode([String: AppAudioSettings].self, from: data) {
            savedSettings = decoded
        }
    }

    var footerText: String { "Ajustes aplicados por app" }

    func start() {
        guard refreshTask == nil else { return }
        isStopped = false
        installCoreAudioListeners()
        refreshNow(forceRetry: true)
        startSourceMetadataPolling()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshNow()
            }
        }
    }

    func stop() {
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        sourceMetadataTask?.cancel()
        sourceMetadataTask = nil
        forceRetryPending = false
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for (address, listener) in listenerRegistrations {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(systemObject, &mutableAddress, DispatchQueue.main, listener)
        }
        listenerRegistrations.removeAll()
        for session in sessions.values { session.session?.stop() }
        sessions.removeAll()
    }

    var shouldRequestAccessibilityPermission: Bool {
        browsersRunning && !browserAccessibilityTrusted
    }

    func openAccessibilitySettings() {
        SafariAudioTabScanner.requestAccessibilityTrustPrompt()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startSourceMetadataPolling() {
        guard sourceMetadataTask == nil else { return }
        sourceMetadataTask = Task { [weak self] in
            let supported = [
                ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"),
                ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge")
            ]
            while !Task.isCancelled {
                let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
                let browserTargets = supported.compactMap { bundle, name -> (String, String, pid_t)? in
                    guard let app = running.first(where: { $0.bundleIdentifier == bundle }) else { return nil }
                    return (bundle, name, app.processIdentifier)
                }
                let mediaTargets: [NowPlayingClientTarget] = (self?.apps ?? []).filter { $0.hasAudioClient && $0.isProducingAudio }.flatMap { app in
                    app.processAttributions.compactMap { attribution in
                        attribution.processBundleID.map { NowPlayingClientTarget(sourceID: app.id, bundleID: $0, pid: Int(attribution.pid)) }
                    }
                }
                let snapshots = await Task.detached(priority: .utility) {
                    let browsers = browserTargets.map { bundle, name, pid in
                        (bundle, name, SafariAudioTabScanner().scan(browserPID: pid,
                            kind: bundle == "com.apple.Safari" ? .safari : .chromium))
                    }
                    var clients = readNowPlayingClients(mediaTargets)
                    let missingMusic = mediaTargets.filter { target in
                        target.bundleID == "com.apple.Music" && !clients.contains { $0.sourceID == target.sourceID && $0.title != nil }
                    }
                    clients += readMusicTrack(missingMusic)
                    return (browsers, MediaRemoteNowPlayingScanner().scan(), clients)
                }.value
                guard !Task.isCancelled else { break }
                if let model = self, !model.isStopped {
                    model.browsersRunning = !browserTargets.isEmpty
                    model.browserAccessibilityTrusted = snapshots.0.first?.2.accessibilityTrusted ?? AXIsProcessTrusted()
                    model.browserMetadata = snapshots.0.map { bundle, name, snapshot in
                        BrowserAudioMetadata(pid: browserTargets.first(where: { $0.0 == bundle })?.2,
                            tabs: snapshot.extraction.allTabs, bundleID: bundle, name: name, titles: snapshot.extraction.titles)
                    }
                    model.nowPlayingSnapshot = snapshots.1
                    var titles: [String: String] = [:]
                    for record in snapshots.2 {
                        if let title = cleanedAudioTitle(record.title) { titles[record.sourceID] = title }
                    }
                    model.clientNowPlayingTitles = titles
                    model.browserAXDiagnostics = snapshots.0.map { bundle, _, snapshot in
                        let e = snapshot.extraction
                        return "browserAX bundle=\(bundle) trusted=\(snapshot.accessibilityTrusted) tabBars=\(e.tabBarCount) tabs=\(e.tabCount) audibleTabs=\(e.titles.count) truncated=\(e.wasTruncated) axErrors=\(e.attributeErrorCount) structure=[\(e.structureSummary.joined(separator: ","))]"
                    }.joined(separator: "\n")
                    model.mediaRemoteDiagnostics = snapshots.1.diagnosticLine + " clients=[" + snapshots.2.map { "\($0.bundleID):\($0.status)" }.joined(separator: ",") + "]"
                    model.applySourceMetadataToAudioRows()
                    model.updateDiagnostics()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func applySourceMetadataToAudioRows() {
        let sources = apps.filter(\.hasAudioClient).map {
            AudioMetadataSource(id: $0.id, bundleIDs: $0.processAttributions.compactMap(\.processBundleID),
                isProducingAudio: $0.isProducingAudio, isUnresolvedWebKit: isUnresolvedWebKit($0))
        }
        let fresh = resolveAudioSourceMetadata(sources: sources, browsers: browserMetadata,
            clientTitles: clientNowPlayingTitles, global: nowPlayingSnapshot)
        let previousCache = sourceMetadataCache
        let resolved = sourceMetadataCache.apply(sources: sources, browsers: browserMetadata, fresh: fresh)
        if previousCache != sourceMetadataCache, let data = try? JSONEncoder().encode(sourceMetadataCache) {
            UserDefaults.standard.set(data, forKey: "Mixer.sourceMetadataCache")
        }
        var updated = apps
        for index in updated.indices {
            let id = updated[index].id
            updated[index].sourceMetadata = resolved[id]

        }
        if apps != updated { apps = updated }
    }

    private func isUnresolvedWebKit(_ app: AudioApp) -> Bool {
        app.processAttributions.contains {
            $0.method == "unresolved-bundle-id" && ($0.processBundleID?.hasPrefix("com.apple.WebKit.") ?? false)
        }
    }

    func refreshNow(forceRetry: Bool = false) {
        guard !isStopped else { return }
        if refreshInFlight {
            if forceRetry { forceRetryPending = true }
            return
        }
        refreshInFlight = true
        let retainedProcessIDs = Set(sessions.values.flatMap { $0.signature.processIDs })
        let visibleApps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let visibleAppBundleIDsByPID = Dictionary(uniqueKeysWithValues: visibleApps.map { ($0.processIdentifier, $0.bundleIdentifier!) })
        let visibleAppBundleIDs = Set(visibleAppBundleIDsByPID.values)
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                CoreAudioCatalog().snapshot(
                    retaining: retainedProcessIDs,
                    visibleAppBundleIDsByPID: visibleAppBundleIDsByPID,
                    visibleAppBundleIDs: visibleAppBundleIDs
                )
            }.value
            guard let self else { return }
            await self.apply(snapshot, forceRetry: forceRetry)
            self.refreshInFlight = false
            if self.forceRetryPending {
                self.forceRetryPending = false
                self.refreshNow(forceRetry: true)
            }
        }
    }

    private func apply(_ snapshot: CoreAudioSnapshot, forceRetry: Bool) async {
        let newOutputs = snapshot.outputs
        let defaultUID = snapshot.defaultOutputUID
        defaultOutputUID = defaultUID
        let currentApps = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let newApps = snapshot.apps.map { candidate -> AudioApp in
            let ownerApp = candidate.bundleID.flatMap { bundleID in
                NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
            }
            let processApp = candidate.processPIDs
                .compactMap { NSRunningApplication(processIdentifier: $0) }
                .first
            let runningApp = ownerApp ?? processApp
            let unresolvedWebKit = candidate.processAttributions.contains {
                $0.method == "unresolved-bundle-id" && ($0.processBundleID?.hasPrefix("com.apple.WebKit.") ?? false)
            }
            let baseName = runningApp?.localizedName ?? candidate.bundleID ?? "App"
            let name = unresolvedWebKit ? "Áudio do navegador · WebKit" : baseName
            if let current = currentApps[candidate.id],
               current.name == name,
               current.processIDs == candidate.processIDs,
               current.processPIDs == candidate.processPIDs,
               current.processAttributions == candidate.processAttributions,
               current.isProducingAudio == candidate.isProducingAudio {
                return current
            }
            return AudioApp(
                id: candidate.id,
                name: name,
                icon: runningApp?.icon ?? NSWorkspace.shared.icon(for: .application),
                processIDs: candidate.processIDs,
                processPIDs: candidate.processPIDs,
                processAttributions: candidate.processAttributions,
                isProducingAudio: candidate.isProducingAudio
            )
        }
        .sorted { lhs, rhs in
            let orderedIDs = orderedAudioSourceIDs([
                AudioSourceOrderEntry(id: lhs.id, hasCoreAudioClient: lhs.hasAudioClient, isProducingAudio: lhs.isProducingAudio),
                AudioSourceOrderEntry(id: rhs.id, hasCoreAudioClient: rhs.hasAudioClient, isProducingAudio: rhs.isProducingAudio)
            ])
            return orderedIDs.first == lhs.id
        }
        if outputs != newOutputs {
            mixerLogger.debug("Audio outputs changed: \(newOutputs.count, privacy: .public)")
            outputs = newOutputs
        }
        if apps != newApps {
            let processIDs = snapshot.apps.map(\.processPIDs)
            mixerLogger.debug("Audio clients changed: \(newApps.count, privacy: .public), PIDs \(String(describing: processIDs), privacy: .public)")
            apps = newApps
        }

        applySourceMetadataToAudioRows()

        let liveIDs = Set(newApps.map(\.id))
        for staleID in sessions.keys.filter({ !liveIDs.contains($0) }) {
            sessions.removeValue(forKey: staleID)?.session?.stop()
            setRouteError(nil, for: staleID)
        }

        var deniedCapture = false
        for app in newApps {
            guard !app.processIDs.isEmpty else {
                sessions.removeValue(forKey: app.id)?.session?.stop()
                setRouteError(nil, for: app.id)
                continue
            }
            let settings = settings(for: app.id)
            let shouldProcess = settings.volume < 100 || settings.isMuted || settings.outputUID != nil
            if !shouldProcess {
                sessions.removeValue(forKey: app.id)?.session?.stop()
                setRouteError(nil, for: app.id)
                continue
            }
            let requestedUID = settings.outputUID
            let targetUID: String?
            let missingRequestedOutput: Bool
            if let requestedUID, newOutputs.contains(where: { $0.uid == requestedUID }) {
                targetUID = requestedUID
                missingRequestedOutput = false
            } else {
                targetUID = defaultUID
                missingRequestedOutput = requestedUID != nil
            }

            let signature = RouteSignature(processIDs: app.processIDs, outputUID: targetUID)
            if let record = sessions[app.id], record.signature == signature {
                if let session = record.session {
                    if session.hasRuntimeLayoutIssue() {
                        session.stop()
                        sessions[app.id] = SessionRecord(
                            signature: signature,
                            session: nil,
                            error: String(MixerAudioError.runtimeLayout.rawValue),
                            diagnostic: session.diagnosticLine(
                                appID: app.id,
                                processPIDs: app.processPIDs,
                                processAttributions: app.processAttributions,
                                targetUID: targetUID ?? "none",
                                volume: settings.volume,
                                muted: settings.isMuted
                            ),
                            retryAfter: .distantFuture
                        )
                        mixerLogger.error("Audio buffer layout mismatch; stopped route for \(app.id, privacy: .public)")
                        setRouteError("Formato incompatível; áudio voltou à saída original.", for: app.id)
                        continue
                    }
                        session.set(volume: settings.volume, muted: settings.isMuted)
                    setRouteError(
                        missingRequestedOutput ? "Saída desconectada. Usando a saída do sistema." : nil,
                        for: app.id
                    )
                    continue
                }
                if !forceRetry && Date() < record.retryAfter {
                    setRouteError(userFacingError(for: record.error), for: app.id)
                    if record.error == String(MixerAudioError.capturePermission.rawValue) { deniedCapture = true }
                    continue
                }
            }

            sessions.removeValue(forKey: app.id)?.session?.stop()
            guard let targetUID else {
                sessions[app.id] = SessionRecord(signature: signature, session: nil, error: "no-output", diagnostic: "stage=route.resolve status=n/a app=\(app.id) pids=\(app.processPIDs) detail=no-output", retryAfter: .distantFuture)
                setRouteError("Nenhuma saída de áudio disponível.", for: app.id)
                continue
            }

            let result: Result<AudioRouteSession, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try AudioRouteSession(
                        processIDs: app.processIDs,
                        outputUID: targetUID,
                        volume: settings.volume,
                        muted: settings.isMuted
                    )
                }
            }.value
            if isStopped {
                if case let .success(session) = result { session.stop() }
                break
            }
            switch result {
            case let .success(session):
                sessions[app.id] = SessionRecord(signature: signature, session: session, error: nil, diagnostic: nil, retryAfter: .distantFuture)
                mixerLogger.info("Routed \(app.id, privacy: .public) to \(targetUID, privacy: .public)")
                setRouteError(
                    missingRequestedOutput ? "Saída desconectada. Usando a saída do sistema." : nil,
                    for: app.id
                )
            case let .failure(error):
                let failure = error as? AudioRouteFailure
                let audioError = failure?.kind ?? (error as? MixerAudioError)
                let errorValue = audioError.map { String($0.rawValue) } ?? String(describing: error)
                let diagnostic = failure?.diagnostic(appID: app.id, processPIDs: app.processPIDs)
                    ?? "stage=route.create status=n/a app=\(app.id) pids=\(app.processPIDs) detail=\(String(describing: error))"
                sessions[app.id] = SessionRecord(signature: signature, session: nil, error: errorValue, diagnostic: diagnostic, retryAfter: .distantFuture)
                mixerLogger.error("Route failed: \(diagnostic, privacy: .public)")
                setRouteError(userFacingError(for: audioError.map { String($0.rawValue) }), for: app.id)
                if audioError == .capturePermission { deniedCapture = true }
            }
        }

        let newPermissionMessage = deniedCapture
            ? "Permita a captura de áudio em Privacidade e Segurança."
            : nil
        if permissionMessage != newPermissionMessage { permissionMessage = newPermissionMessage }
        updateDiagnostics()
    }

    func settings(for id: String) -> AppAudioSettings {
        savedSettings[id] ?? AppAudioSettings()
    }

    func setVolume(_ volume: Int, for id: String) {
        var value = settings(for: id)
        value.volume = min(100, max(0, volume))
        save(value, for: id)
        if let session = sessions[id]?.session {
            session.set(volume: value.volume, muted: value.isMuted)
        } else if value.volume < 100 || value.isMuted || value.outputUID != nil {
            refreshNow(forceRetry: true)
        }
        updateDiagnostics()
    }

    func setMuted(_ muted: Bool, for id: String) {
        var value = settings(for: id)
        value.isMuted = muted
        save(value, for: id)
        if let session = sessions[id]?.session {
            session.set(volume: value.volume, muted: value.isMuted)
        } else if value.volume < 100 || value.isMuted || value.outputUID != nil {
            refreshNow(forceRetry: true)
        }
        updateDiagnostics()
    }

    func setOutput(_ outputUID: String?, for id: String) {
        var value = settings(for: id)
        value.outputUID = outputUID
        save(value, for: id)
        refreshNow(forceRetry: true)
        updateDiagnostics()
    }

    func outputTitle(for settings: AppAudioSettings) -> String {
        guard let uid = settings.outputUID else { return "Saída do sistema" }
        return outputs.first(where: { $0.uid == uid })?.name ?? "Saída indisponível"
    }

    func error(for id: String) -> String? { routeErrors[id] }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText, forType: .string)
    }

    func recordPopoverLayout(viewportHeight: Double, event: String) {
        let audioClientCount = apps.filter { !$0.processIDs.isEmpty }.count
        let producingClientCount = apps.filter(\.isProducingAudio).count
        popoverLayoutDiagnostic = "popover=\(event) apps=\(apps.count) audioClients=\(audioClientCount) producing=\(producingClientCount) viewportHeight=\(Int(viewportHeight.rounded()))pt expandedOthers=\(otherAppsExpanded)"
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let outputNames = outputs.map(\.name).joined(separator: ", ")
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let audioClientCount = apps.filter { !$0.processIDs.isEmpty }.count
        let producingClientCount = apps.filter(\.isProducingAudio).count
        var lines = [
            "Mixer \(version) (\(build)) diagnostics | \(timestamp) pid=\(getpid()) bundle=\(Bundle.main.bundlePath)",
            "defaultOutput=\(defaultOutputUID ?? "none") | outputs=\(outputNames)",
            "apps=\(apps.count) | audioClients=\(audioClientCount) | producing=\(producingClientCount) | routes=\(sessions.count)",
            "file=\(diagnosticsURL.path)"
        ]
        for app in apps {
            let settings = settings(for: app.id)
            let targetUID = settings.outputUID ?? defaultOutputUID ?? "none"
            let route = sessions[app.id]
            if app.processIDs.isEmpty {
                lines.append("app=\(app.name) id=\(app.id) pids=\(app.processPIDs) processes=[\(attributionSummary(app.processAttributions))] target=\(targetUID) gain=\(settings.isMuted ? 0 : settings.volume)% status=WAITING (no active Core Audio client)")
            } else if let session = route?.session {
                lines.append(session.diagnosticLine(
                    appID: app.id,
                    processPIDs: app.processPIDs,
                    processAttributions: app.processAttributions,
                    targetUID: targetUID,
                    volume: settings.volume,
                    muted: settings.isMuted
                ))
            } else if let route, let diagnostic = route.diagnostic {
                lines.append("app=\(app.name) id=\(app.id) pids=\(app.processPIDs) processes=[\(attributionSummary(app.processAttributions))] target=\(targetUID) gain=\(settings.isMuted ? 0 : settings.volume)% status=FAILED \(diagnostic)")
            } else {
                lines.append("app=\(app.name) id=\(app.id) pids=\(app.processPIDs) processes=[\(attributionSummary(app.processAttributions))] target=\(targetUID) gain=\(settings.isMuted ? 0 : settings.volume)% status=PASS-THROUGH (no tap)")
            }
        }
        if let permissionMessage { lines.append("permission=\(permissionMessage)") }
        for app in apps where app.sourceMetadata != nil {
            lines.append("sourceMetadata app=\(app.id) method=\(app.sourceMetadata!.method) titleCount=\(app.sourceMetadata!.titles.count)")
        }
        lines.append(browserAXDiagnostics)
        lines.append(mediaRemoteDiagnostics)
        if let popoverLayoutDiagnostic { lines.append(popoverLayoutDiagnostic) }
        let text = lines.joined(separator: "\n") + "\n"
        diagnosticText = text

        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticWrite) >= 1 else { return }
        lastDiagnosticWrite = now
        let url = diagnosticsURL
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                mixerLogger.error("Diagnostic file write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func attributionSummary(_ attributions: [AudioProcessAttribution]) -> String {
        attributions.map(\.diagnosticText).joined(separator: ";")
    }

    private func save(_ value: AppAudioSettings, for id: String) {
        var updated = savedSettings
        updated[id] = value
        savedSettings = updated
        if let data = try? JSONEncoder().encode(savedSettings) {
            UserDefaults.standard.set(data, forKey: "Mixer.appSettings")
        }
    }

    private func setRouteError(_ value: String?, for id: String) {
        guard routeErrors[id] != value else { return }
        var updated = routeErrors
        updated[id] = value
        routeErrors = updated
    }

    private func userFacingError(for value: String?) -> String {
        if value == String(MixerAudioError.capturePermission.rawValue) {
            return "Não foi possível acessar a captura de áudio."
        }
        if value == String(MixerAudioError.runtimeLayout.rawValue)
            || value == String(MixerAudioError.unsupportedFormat.rawValue) {
            return "Formato incompatível; áudio voltou à saída original."
        }
        return "Não foi possível direcionar o áudio."
    }

    private func installCoreAudioListeners() {
        guard listenerRegistrations.isEmpty else { return }
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let properties: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        for selector in properties {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let shouldRetryFailedRoutes = selector != kAudioHardwarePropertyProcessObjectList
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshNow(forceRetry: shouldRetryFailedRoutes)
                }
            }
            var mutableAddress = address
            if AudioObjectAddPropertyListenerBlock(systemObject, &mutableAddress, DispatchQueue.main, listener) == noErr {
                listenerRegistrations.append((address, listener))
            }
        }
    }
}

private struct RouteSignature: Equatable {
    let processIDs: [AudioObjectID]
    let outputUID: String?
}

private final class SessionRecord {
    let signature: RouteSignature
    let session: AudioRouteSession?
    let error: String?
    let diagnostic: String?
    let retryAfter: Date

    init(signature: RouteSignature, session: AudioRouteSession?, error: String?, diagnostic: String?, retryAfter: Date) {
        self.signature = signature
        self.session = session
        self.error = error
        self.diagnostic = diagnostic
        self.retryAfter = retryAfter
    }
}

private func systemParentProcessID(_ processID: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let bytesRead = proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard bytesRead >= Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid > 1 else { return nil }
    return pid_t(info.pbi_ppid)
}

private struct CoreAudioCatalog {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func snapshot(
        retaining retainedProcessIDs: Set<AudioObjectID>,
        visibleAppBundleIDsByPID: [pid_t: String],
        visibleAppBundleIDs: Set<String>
    ) -> CoreAudioSnapshot {
        CoreAudioSnapshot(
            outputs: outputDevices(),
            defaultOutputUID: defaultOutputUID(),
            apps: activeOutputApps(
                retaining: retainedProcessIDs,
                visibleAppBundleIDsByPID: visibleAppBundleIDsByPID,
                visibleAppBundleIDs: visibleAppBundleIDs
            )
        )
    }

    func outputDevices() -> [AudioOutput] {
        let deviceIDs = readIDs(object: systemObject, selector: kAudioHardwarePropertyDevices)
        return deviceIDs.compactMap { deviceID in
            let streams = readIDs(object: deviceID, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard !streams.isEmpty,
                  let uid = readString(object: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.codex.mixer."),
                  let name = readString(object: deviceID, selector: kAudioObjectPropertyName) else { return nil }
            return AudioOutput(uid: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultOutputUID() -> String? {
        guard let deviceID = readUInt32(object: systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice),
              deviceID != kAudioObjectUnknown else { return nil }
        return readString(object: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func activeOutputApps(
        retaining retainedProcessIDs: Set<AudioObjectID>,
        visibleAppBundleIDsByPID: [pid_t: String],
        visibleAppBundleIDs: Set<String>
    ) -> [AudioAppCandidate] {
        let processObjects = readIDs(object: systemObject, selector: kAudioHardwarePropertyProcessObjectList)
        var parentCache: [pid_t: pid_t] = [:]
        func cachedParentPID(_ pid: pid_t) -> pid_t? {
            if let cached = parentCache[pid] { return cached > 1 ? cached : nil }
            let parent = systemParentProcessID(pid) ?? -1
            parentCache[pid] = parent
            return parent > 1 ? parent : nil
        }
        var grouped: [String: (bundleID: String?, processIDs: [AudioObjectID], processPIDs: [pid_t], attributions: [AudioProcessAttribution], isProducingAudio: Bool)] = [:]

        for processObject in processObjects {
            let isActive = readUInt32(object: processObject, selector: kAudioProcessPropertyIsRunningOutput) == 1
            guard isActive || retainedProcessIDs.contains(processObject),
                  let pidValue = readUInt32(object: processObject, selector: kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(pidValue)
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }

            let rawBundleID = readString(object: processObject, selector: kAudioProcessPropertyBundleID)
            let resolution = resolveAudioProcessOwner(
                processPID: pid,
                processBundleID: rawBundleID,
                visibleAppBundleIDsByPID: visibleAppBundleIDsByPID,
                visibleAppBundleIDs: visibleAppBundleIDs,
                parentPIDForProcess: cachedParentPID
            )
            let bundleID = resolution.bundleID
            let key = audioProcessGroupKey(
                processPID: pid,
                processBundleID: rawBundleID,
                ownerBundleID: bundleID,
                method: resolution.method
            )
            if grouped[key] == nil {
                grouped[key] = (bundleID, [], [], [], false)
            }
            var item = grouped[key]!
            item.processIDs.append(processObject)
            item.processPIDs.append(pid)
            item.isProducingAudio = item.isProducingAudio || isActive
            item.attributions.append(AudioProcessAttribution(
                pid: pid,
                processBundleID: rawBundleID,
                ownerBundleID: bundleID,
                method: resolution.method
            ))
            grouped[key] = item
        }

        for (pid, bundleID) in visibleAppBundleIDsByPID where pid != ProcessInfo.processInfo.processIdentifier {
            let key = bundleID
            var item = grouped[key] ?? (bundleID, [], [], [], false)
            if !item.processPIDs.contains(pid) {
                item.processPIDs.append(pid)
                item.attributions.append(AudioProcessAttribution(
                    pid: pid,
                    processBundleID: bundleID,
                    ownerBundleID: bundleID,
                    method: item.processIDs.isEmpty ? "visible-app-no-audio" : "visible-app"
                ))
            }
            grouped[key] = item
        }

        return grouped.map { key, item in
            AudioAppCandidate(
                id: key,
                bundleID: item.bundleID,
                processIDs: item.processIDs.sorted(),
                processPIDs: item.processPIDs.sorted(),
                processAttributions: item.attributions.sorted { $0.pid < $1.pid },
                isProducingAudio: item.isProducingAudio
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func outputFormats(deviceUID: String) -> AudioFormatRead {
        let devices = readIDsResult(object: systemObject, selector: kAudioHardwarePropertyDevices)
        guard let deviceID = devices.ids.first(where: {
            readString(object: $0, selector: kAudioDevicePropertyDeviceUID) == deviceUID
        }) else { return AudioFormatRead(formats: [], status: devices.status) }
        return streamFormats(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    func outputDeviceID(deviceUID: String) -> AudioDeviceID? {
        readIDs(object: systemObject, selector: kAudioHardwarePropertyDevices).first(where: {
            readString(object: $0, selector: kAudioDevicePropertyDeviceUID) == deviceUID
        })
    }

    func streamFormats(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioFormatRead {
        let streamList = readIDsResult(object: deviceID, selector: kAudioDevicePropertyStreams, scope: scope)
        guard streamList.status == noErr else { return AudioFormatRead(formats: [], status: streamList.status) }
        var firstFailure: OSStatus = noErr
        let formats = streamList.ids.compactMap { streamID -> AudioStreamBasicDescription? in
            var property = address(kAudioStreamPropertyVirtualFormat)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = withUnsafeMutablePointer(to: &format) { pointer in
                AudioObjectGetPropertyData(streamID, &property, 0, nil, &size, pointer)
            }
            if status != noErr && firstFailure == noErr { firstFailure = status }
            return status == noErr ? format : nil
        }
        return AudioFormatRead(formats: formats, status: firstFailure)
    }

    func tapFormat(tapID: AudioObjectID) -> (format: AudioStreamBasicDescription?, status: OSStatus) {
        var property = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutablePointer(to: &format) { pointer in
            AudioObjectGetPropertyData(tapID, &property, 0, nil, &size, pointer)
        }
        return (status == noErr ? format : nil, status)
    }

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func readIDs(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        readIDsResult(object: object, selector: selector, scope: scope).ids
    }

    private func readIDsResult(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> (ids: [AudioObjectID], status: OSStatus) {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard sizeStatus == noErr else { return ([], sizeStatus) }
        guard size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return ([], noErr) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: 0, count: count)
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, buffer.baseAddress!)
        }
        return (status == noErr ? values : [], status)
    }

    private func readUInt32(object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
        }
        return status == noErr ? value : nil
    }

    private func readString(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private enum MixerAudioError: Int32, Error {
    case capturePermission = -2000
    case missingOutput = -2001
    case unsupportedFormat = -2002
    case tapCreateFailed = -2003
    case tapUIDReadFailed = -2004
    case aggregateCreateFailed = -2005
    case ioProcCreateFailed = -2006
    case deviceStartFailed = -2007
    case runtimeLayout = -2008

    init(status: OSStatus, fallback: MixerAudioError) {
        if status == kAudioDevicePermissionsError {
            self = .capturePermission
        } else {
            self = fallback
        }
    }
}

private struct AudioRouteFailure: Error {
    let kind: MixerAudioError
    let stage: String
    let status: OSStatus?
    let detail: String?

    func diagnostic(appID: String, processPIDs: [pid_t]) -> String {
        let statusText = status.map(String.init) ?? "n/a"
        let detailText = detail.map { " detail=\($0)" } ?? ""
        return "stage=\(stage) status=\(statusText) kind=\(kind.rawValue) app=\(appID) pids=\(processPIDs)\(detailText)"
    }
}

private struct RenderState {
    var volume: Int32
    var muted: Int32
    var layoutIssue: Int32
    var callbackCount: Int32
    var captureCallbackCount: Int32
    var outputSourceCallbackCount: Int32
    var emptyInputCallbacks: Int32
    var renderedFrames: Int32
    var inputPeakMicros: Int32
    var outputPeakMicros: Int32
    var inputBufferCount: Int32
    var outputBufferCount: Int32
    var inputChannels: Int32
    var outputChannels: Int32
    var inputBytes: Int32
    var outputBytes: Int32
    var inputFrames: Int32
    var outputFrames: Int32
    var ringBuffer: UnsafeMutableRawPointer?
}

private func formatDescription(_ format: AudioStreamBasicDescription?) -> String {
    guard let format else { return "unavailable" }
    let sampleFormat: String
    if format.mFormatID == kAudioFormatLinearPCM, (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
        sampleFormat = "Float\(format.mBitsPerChannel)"
    } else if format.mFormatID == kAudioFormatLinearPCM {
        sampleFormat = "PCM\(format.mBitsPerChannel)"
    } else {
        sampleFormat = "formatID=\(format.mFormatID)"
    }
    let layout = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? "planar" : "interleaved"
    return "\(sampleFormat) \(layout) ch=\(format.mChannelsPerFrame) rate=\(format.mSampleRate) bpf=\(format.mBytesPerFrame)"
}

@inline(__always)
private func atomicStore(_ value: Int32, to pointer: UnsafeMutablePointer<Int32>) {
    var oldValue = OSAtomicAdd32Barrier(0, pointer)
    while !OSAtomicCompareAndSwap32Barrier(oldValue, value, pointer) {
        oldValue = OSAtomicAdd32Barrier(0, pointer)
    }
}

@inline(__always)
private func atomicMax(_ value: Int32, at pointer: UnsafeMutablePointer<Int32>) {
    var oldValue = OSAtomicAdd32Barrier(0, pointer)
    while value > oldValue && !OSAtomicCompareAndSwap32Barrier(oldValue, value, pointer) {
        oldValue = OSAtomicAdd32Barrier(0, pointer)
    }
}

@inline(__always)
private func atomicTakeAndReset(_ pointer: UnsafeMutablePointer<Int32>) -> Int32 {
    var oldValue = OSAtomicAdd32Barrier(0, pointer)
    while !OSAtomicCompareAndSwap32Barrier(oldValue, 0, pointer) {
        oldValue = OSAtomicAdd32Barrier(0, pointer)
    }
    return oldValue
}

@inline(__always)
private func scaledPeak(_ peak: Float) -> Int32 {
    guard peak.isFinite, peak > 0 else { return 0 }
    return Int32(min(Double(Int32.max), Double(peak) * 1_000_000).rounded())
}

private struct StereoFloatBufferSet {
    let left: UnsafePointer<Float>
    let right: UnsafePointer<Float>
    let frameCount: Int
    let interleaved: Bool

    init?(buffers: UnsafeMutableAudioBufferListPointer) {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard buffer.mNumberChannels == 2,
                  Int(buffer.mDataByteSize) % MemoryLayout<Float>.size == 0,
                  let data = buffer.mData else { return nil }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount % 2 == 0 else { return nil }
            let pointer = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            left = pointer
            right = pointer
            frameCount = sampleCount / 2
            interleaved = true
        } else if buffers.count == 2 {
            let leftBuffer = buffers[0]
            let rightBuffer = buffers[1]
            guard leftBuffer.mNumberChannels == 1,
                  rightBuffer.mNumberChannels == 1,
                  Int(leftBuffer.mDataByteSize) % MemoryLayout<Float>.size == 0,
                  Int(rightBuffer.mDataByteSize) % MemoryLayout<Float>.size == 0,
                  let leftData = leftBuffer.mData,
                  let rightData = rightBuffer.mData else { return nil }
            left = UnsafePointer(leftData.assumingMemoryBound(to: Float.self))
            right = UnsafePointer(rightData.assumingMemoryBound(to: Float.self))
            frameCount = min(
                Int(leftBuffer.mDataByteSize),
                Int(rightBuffer.mDataByteSize)
            ) / MemoryLayout<Float>.size
            interleaved = false
        } else {
            return nil
        }
    }
}

/// Single-producer/single-consumer ring used only when the tap and selected output
/// have different nominal rates. Storage is allocated before either real-time callback starts.
private final class StereoFloatRingBuffer {
    private let capacity = 16_384
    private let mask = 16_383
    private let samples: UnsafeMutablePointer<Float>
    private var writeFrame: Int64 = 0
    private var readFrame: Int64 = 0
    private var overflowFrames: Int32 = 0
    private var underflowFrames: Int32 = 0

    init() {
        samples = .allocate(capacity: capacity * 2)
    }

    deinit { samples.deallocate() }

    @inline(__always)
    func write(_ source: StereoFloatBufferSet) -> Int {
        let write = OSAtomicAdd64Barrier(0, &writeFrame)
        let read = OSAtomicAdd64Barrier(0, &readFrame)
        let queued = max(0, min(capacity, Int(write &- read)))
        let count = min(source.frameCount, capacity - queued)
        for frame in 0..<count {
            let sourceIndex = source.interleaved ? frame * 2 : frame
            let left = source.left[sourceIndex]
            let right = source.right[source.interleaved ? sourceIndex + 1 : sourceIndex]
            let ringIndex = (Int(write &+ Int64(frame)) & mask) * 2
            samples[ringIndex] = left
            samples[ringIndex + 1] = right
        }
        if count > 0 { _ = OSAtomicAdd64Barrier(Int64(count), &writeFrame) }
        if count < source.frameCount {
            _ = OSAtomicAdd32Barrier(Int32(min(source.frameCount - count, Int(Int32.max))), &overflowFrames)
        }
        return count
    }

    @inline(__always)
    func render(
        frameCount: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        gain: Float,
        state: UnsafeMutablePointer<RenderState>
    ) -> StereoRenderMetrics? {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for index in 0..<buffers.count {
            if let data = buffers[index].mData {
                memset(data, 0, Int(buffers[index].mDataByteSize))
            }
        }

        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let interleaved: Bool
        if buffers.count == 1,
           buffers[0].mNumberChannels == 2,
           Int(buffers[0].mDataByteSize) >= frameCount * 2 * MemoryLayout<Float>.size,
           let data = buffers[0].mData {
            left = data.assumingMemoryBound(to: Float.self)
            right = left
            interleaved = true
        } else if buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  Int(buffers[0].mDataByteSize) >= frameCount * MemoryLayout<Float>.size,
                  Int(buffers[1].mDataByteSize) >= frameCount * MemoryLayout<Float>.size,
                  let leftData = buffers[0].mData,
                  let rightData = buffers[1].mData {
            left = leftData.assumingMemoryBound(to: Float.self)
            right = rightData.assumingMemoryBound(to: Float.self)
            interleaved = false
        } else {
            _ = OSAtomicCompareAndSwap32Barrier(0, 1, &state.pointee.layoutIssue)
            return nil
        }

        let write = OSAtomicAdd64Barrier(0, &writeFrame)
        let read = OSAtomicAdd64Barrier(0, &readFrame)
        let available = max(0, min(capacity, Int(write &- read)))
        let count = min(frameCount, available)
        var inputPeak: Float = 0
        var outputPeak: Float = 0
        for frame in 0..<count {
            let ringIndex = (Int(read &+ Int64(frame)) & mask) * 2
            let inputLeft = samples[ringIndex]
            let inputRight = samples[ringIndex + 1]
            let outputLeft = inputLeft * gain
            let outputRight = inputRight * gain
            if inputLeft.isFinite { inputPeak = max(inputPeak, abs(inputLeft)) }
            if inputRight.isFinite { inputPeak = max(inputPeak, abs(inputRight)) }
            if outputLeft.isFinite { outputPeak = max(outputPeak, abs(outputLeft)) }
            if outputRight.isFinite { outputPeak = max(outputPeak, abs(outputRight)) }
            let outputIndex = interleaved ? frame * 2 : frame
            left[outputIndex] = outputLeft
            right[interleaved ? outputIndex + 1 : outputIndex] = outputRight
        }
        if count > 0 { _ = OSAtomicAdd64Barrier(Int64(count), &readFrame) }
        if count < frameCount {
            _ = OSAtomicAdd32Barrier(Int32(min(frameCount - count, Int(Int32.max))), &underflowFrames)
        }
        atomicStore(Int32(buffers.count), to: &state.pointee.outputBufferCount)
        atomicStore(Int32(buffers.reduce(0) { $0 + Int($1.mNumberChannels) }), to: &state.pointee.outputChannels)
        atomicStore(Int32(buffers.reduce(0) { $0 + min(Int($1.mDataByteSize), Int(Int32.max)) }), to: &state.pointee.outputBytes)
        atomicStore(Int32(min(frameCount, Int(Int32.max))), to: &state.pointee.outputFrames)
        _ = OSAtomicAdd32Barrier(Int32(min(frameCount, Int(Int32.max))), &state.pointee.renderedFrames)
        atomicMax(scaledPeak(outputPeak), at: &state.pointee.outputPeakMicros)
        return StereoRenderMetrics(inputPeak: inputPeak, outputPeak: outputPeak)
    }

    func metrics() -> (fillFrames: Int, overflowFrames: Int, underflowFrames: Int) {
        let write = OSAtomicAdd64Barrier(0, &writeFrame)
        let read = OSAtomicAdd64Barrier(0, &readFrame)
        return (
            max(0, min(capacity, Int(write &- read))),
            Int(OSAtomicAdd32Barrier(0, &overflowFrames)),
            Int(OSAtomicAdd32Barrier(0, &underflowFrames))
        )
    }
}

private final class AudioEngineOutput {
    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    let ring: StereoFloatRingBuffer
    let outputFormatSummary: String
    private var isStopped = false

    init(
        deviceID: AudioDeviceID,
        tapRate: Double,
        expectedOutputRate: Double,
        expectedOutputChannels: UInt32,
        renderState: UnsafeMutablePointer<RenderState>
    ) throws {
        var bridgeError: NSError?
        guard let engine = MXBCreateEngine(&bridgeError) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.create", status: nil, detail: bridgeError?.localizedDescription ?? "engine unavailable")
        }
        guard let outputNode = MXBOutputNode(engine, &bridgeError) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.outputNode", status: nil, detail: bridgeError?.localizedDescription ?? "output node unavailable")
        }
        guard let outputUnit = MXBOutputAudioUnit(outputNode, &bridgeError) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.outputUnit", status: nil, detail: bridgeError?.localizedDescription ?? "missing HAL output unit")
        }
        var requestedDevice = deviceID
        let deviceStatus = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &requestedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw AudioRouteFailure(kind: MixerAudioError(status: deviceStatus, fallback: .missingOutput), stage: "engine.selectOutput", status: deviceStatus, detail: "deviceID=\(deviceID)")
        }
        var actualDevice: AudioDeviceID = kAudioObjectUnknown
        var actualDeviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let actualDeviceStatus = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &actualDevice,
            &actualDeviceSize
        )
        guard actualDeviceStatus == noErr, actualDevice == deviceID else {
            throw AudioRouteFailure(
                kind: .missingOutput,
                stage: "engine.verifyOutput",
                status: actualDeviceStatus,
                detail: "requestedDevice=\(deviceID) actualDevice=\(actualDevice)"
            )
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.sourceFormat", status: nil, detail: "tapRate=\(tapRate)")
        }
        guard (1...2).contains(expectedOutputChannels),
              let mixerTargetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: expectedOutputRate,
                channels: AVAudioChannelCount(expectedOutputChannels),
                interleaved: false
              ) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.targetFormat", status: nil, detail: "outputRate=\(expectedOutputRate) outputChannels=\(expectedOutputChannels)")
        }

        let ring = StereoFloatRingBuffer()
        renderState.pointee.ringBuffer = Unmanaged.passUnretained(ring).toOpaque()
        guard let sourceNode = MXBCreateSourceNode(sourceFormat, { _, _, frameCount, outputData in
            _ = OSAtomicIncrement32Barrier(&renderState.pointee.outputSourceCallbackCount)
            let currentVolume = OSAtomicAdd32Barrier(0, &renderState.pointee.volume)
            let isMuted = OSAtomicAdd32Barrier(0, &renderState.pointee.muted) != 0
            let gain = isMuted ? 0 : Float(max(0, min(100, currentVolume))) / 100.0
            guard ring.render(
                frameCount: Int(frameCount),
                outputData: outputData,
                gain: gain,
                state: renderState
            ) != nil else { return noErr }
            return noErr
        }, &bridgeError) else {
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.sourceNode", status: nil, detail: bridgeError?.localizedDescription ?? "source node unavailable")
        }
        guard MXBAttachNode(engine, sourceNode, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.attach", status: nil, detail: bridgeError?.localizedDescription ?? "attach failed")
        }
        guard let mixer = MXBMainMixerNode(engine, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.mainMixerNode", status: nil, detail: bridgeError?.localizedDescription ?? "main mixer unavailable")
        }
        guard MXBConnectNode(engine, sourceNode, mixer, sourceFormat, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.connectSource", status: nil, detail: bridgeError?.localizedDescription ?? "source-to-mixer connect failed")
        }
        guard MXBConnectNode(engine, mixer, outputNode, mixerTargetFormat, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.connectOutput", status: nil, detail: bridgeError?.localizedDescription ?? "mixer-to-output connect failed")
        }
        guard MXBPrepareEngine(engine, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.prepare", status: nil, detail: bridgeError?.localizedDescription ?? "prepare failed")
        }
        guard let hardwareFormat = MXBNodeOutputFormat(outputNode, 0, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.readOutputFormat", status: nil, detail: bridgeError?.localizedDescription ?? "hardware format unavailable")
        }
        guard let preparedMixerFormat = MXBNodeOutputFormat(mixer, 0, &bridgeError) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "engine.readMixerFormat", status: nil, detail: bridgeError?.localizedDescription ?? "mixer format unavailable")
        }
        guard hardwareFormat.sampleRate > 0,
              hardwareFormat.channelCount == AVAudioChannelCount(expectedOutputChannels),
              abs(hardwareFormat.sampleRate - expectedOutputRate) < 0.5,
              abs(preparedMixerFormat.sampleRate - expectedOutputRate) < 0.5,
              preparedMixerFormat.channelCount == AVAudioChannelCount(expectedOutputChannels) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(
                kind: .unsupportedFormat,
                stage: "engine.outputFormat",
                status: nil,
                detail: "expected=\(expectedOutputRate) hardware=\(hardwareFormat.sampleRate) mixer=\(preparedMixerFormat.sampleRate) channels=\(hardwareFormat.channelCount)"
            )
        }

        self.engine = engine
        self.sourceNode = sourceNode
        self.ring = ring
        self.outputFormatSummary = "AVAudioEngine mainMixer Float32 \(tapRate)->\(preparedMixerFormat.sampleRate) channels=2->\(hardwareFormat.channelCount)"
    }

    func start() throws {
        var error: NSError?
        guard MXBStartEngine(engine, &error) else {
            Self.stopAndReset(engine)
            throw AudioRouteFailure(kind: .deviceStartFailed, stage: "engine.start", status: nil, detail: error?.localizedDescription ?? "start failed")
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        var stopError: NSError?
        if !MXBStopEngine(engine, &stopError) {
            let detail = stopError?.localizedDescription ?? "unknown"
            mixerLogger.error("AVAudioEngine stop exception: \(detail, privacy: .public)")
        }
        var resetError: NSError?
        if !MXBResetEngine(engine, &resetError) {
            let detail = resetError?.localizedDescription ?? "unknown"
            mixerLogger.error("AVAudioEngine reset exception: \(detail, privacy: .public)")
        }
    }

    private static func stopAndReset(_ engine: AVAudioEngine) {
        var error: NSError?
        if !MXBStopEngine(engine, &error) {
            let detail = error?.localizedDescription ?? "unknown"
            mixerLogger.error("AVAudioEngine cleanup stop exception: \(detail, privacy: .public)")
        }
        error = nil
        if !MXBResetEngine(engine, &error) {
            let detail = error?.localizedDescription ?? "unknown"
            mixerLogger.error("AVAudioEngine cleanup reset exception: \(detail, privacy: .public)")
        }
    }

    deinit { stop() }
}

private let mixerIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let state = clientData.assumingMemoryBound(to: RenderState.self)
    _ = OSAtomicIncrement32Barrier(&state.pointee.callbackCount)
    let volume = OSAtomicAdd32Barrier(0, &state.pointee.volume)
    let muted = OSAtomicAdd32Barrier(0, &state.pointee.muted)
    let gain = muted == 0 ? Float(max(0, min(100, volume))) / 100.0 : 0.0
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    for outputIndex in 0..<outputBuffers.count {
        let output = outputBuffers[outputIndex]
        if let bytes = output.mData {
            memset(bytes, 0, Int(output.mDataByteSize))
        }
    }
    // The aggregate excludes hardware inputs, so this list contains only the app tap.
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    var inputChannels: Int32 = 0
    var inputBytes: Int32 = 0
    var hasInput = false
    for inputIndex in 0..<inputBuffers.count {
        let buffer = inputBuffers[inputIndex]
        inputChannels += Int32(buffer.mNumberChannels)
        inputBytes += Int32(min(Int(buffer.mDataByteSize), Int(Int32.max)))
        if buffer.mData != nil && buffer.mDataByteSize > 0 { hasInput = true }
    }
    atomicStore(Int32(inputBuffers.count), to: &state.pointee.inputBufferCount)
    atomicStore(inputChannels, to: &state.pointee.inputChannels)
    atomicStore(inputBytes, to: &state.pointee.inputBytes)
    // An idle tap may have no data. In that case the source app stays audible through
    // .mutedWhenTapped; don't turn an empty cycle into a format failure.
    guard hasInput else {
        _ = OSAtomicIncrement32Barrier(&state.pointee.emptyInputCallbacks)
        return noErr
    }
    var outputChannels: Int32 = 0
    var outputBytes: Int32 = 0
    var hasOutput = false
    for outputIndex in 0..<outputBuffers.count {
        let buffer = outputBuffers[outputIndex]
        outputChannels += Int32(buffer.mNumberChannels)
        outputBytes += Int32(min(Int(buffer.mDataByteSize), Int(Int32.max)))
        if buffer.mData != nil && buffer.mDataByteSize > 0 { hasOutput = true }
    }
    atomicStore(Int32(outputBuffers.count), to: &state.pointee.outputBufferCount)
    atomicStore(outputChannels, to: &state.pointee.outputChannels)
    atomicStore(outputBytes, to: &state.pointee.outputBytes)
    guard hasOutput else { return noErr }
    guard let source = StereoFloatBufferSet(buffers: inputBuffers),
          let destination = StereoFloatBufferSet(buffers: outputBuffers),
          source.frameCount == destination.frameCount else {
        _ = OSAtomicCompareAndSwap32Barrier(0, 1, &state.pointee.layoutIssue)
        return noErr
    }
    let metrics = renderStereoFloat32(
        inputLeft: source.left,
        inputRight: source.right,
        outputLeft: UnsafeMutablePointer(mutating: destination.left),
        outputRight: UnsafeMutablePointer(mutating: destination.right),
        frameCount: source.frameCount,
        gain: gain,
        inputInterleaved: source.interleaved,
        outputInterleaved: destination.interleaved
    )
    atomicStore(Int32(min(source.frameCount, Int(Int32.max))), to: &state.pointee.inputFrames)
    atomicStore(Int32(min(destination.frameCount, Int(Int32.max))), to: &state.pointee.outputFrames)
    _ = OSAtomicAdd32Barrier(Int32(min(source.frameCount, Int(Int32.max))), &state.pointee.renderedFrames)
    atomicMax(scaledPeak(metrics.inputPeak), at: &state.pointee.inputPeakMicros)
    atomicMax(scaledPeak(metrics.outputPeak), at: &state.pointee.outputPeakMicros)
    return noErr
}

private let mixerCaptureIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let state = clientData.assumingMemoryBound(to: RenderState.self)
    _ = OSAtomicIncrement32Barrier(&state.pointee.callbackCount)
    _ = OSAtomicIncrement32Barrier(&state.pointee.captureCallbackCount)

    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    for index in 0..<outputBuffers.count {
        if let bytes = outputBuffers[index].mData {
            memset(bytes, 0, Int(outputBuffers[index].mDataByteSize))
        }
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    var inputChannels: Int32 = 0
    var inputBytes: Int32 = 0
    var hasInput = false
    for index in 0..<inputBuffers.count {
        let buffer = inputBuffers[index]
        inputChannels += Int32(buffer.mNumberChannels)
        inputBytes += Int32(min(Int(buffer.mDataByteSize), Int(Int32.max)))
        if buffer.mData != nil && buffer.mDataByteSize > 0 { hasInput = true }
    }
    atomicStore(Int32(inputBuffers.count), to: &state.pointee.inputBufferCount)
    atomicStore(inputChannels, to: &state.pointee.inputChannels)
    atomicStore(inputBytes, to: &state.pointee.inputBytes)
    guard hasInput,
          let source = StereoFloatBufferSet(buffers: inputBuffers),
          let ringPointer = state.pointee.ringBuffer else {
        if hasInput {
            _ = OSAtomicCompareAndSwap32Barrier(0, 1, &state.pointee.layoutIssue)
        } else {
            _ = OSAtomicIncrement32Barrier(&state.pointee.emptyInputCallbacks)
        }
        return noErr
    }

    atomicStore(Int32(min(source.frameCount, Int(Int32.max))), to: &state.pointee.inputFrames)
    var inputPeak: Float = 0
    for frame in 0..<source.frameCount {
        let index = source.interleaved ? frame * 2 : frame
        let left = source.left[index]
        let right = source.right[source.interleaved ? index + 1 : index]
        if left.isFinite { inputPeak = max(inputPeak, abs(left)) }
        if right.isFinite { inputPeak = max(inputPeak, abs(right)) }
    }
    atomicMax(scaledPeak(inputPeak), at: &state.pointee.inputPeakMicros)
    let ring = Unmanaged<StereoFloatRingBuffer>.fromOpaque(ringPointer).takeUnretainedValue()
    _ = ring.write(source)
    return noErr
}

private final class AudioRouteSession {
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID? = nil
    private let renderState: UnsafeMutablePointer<RenderState>
    private let tapFormatSummary: String
    private let outputFormatSummary: String
    private let aggregateInputFormatSummary: String
    private let aggregateOutputFormatSummary: String
    private var routeModeSummary = "pending"
    private var outputEngine: AudioEngineOutput? = nil
    private var isStopped = false

    init(processIDs: [AudioObjectID], outputUID: String, volume: Int, muted: Bool) throws {
        guard !processIDs.isEmpty else {
            throw AudioRouteFailure(kind: .tapCreateFailed, stage: "tap.validateProcesses", status: nil, detail: "empty process-object list")
        }
        let catalog = CoreAudioCatalog()
        guard catalog.outputDevices().contains(where: { $0.uid == outputUID }),
              let outputDeviceID = catalog.outputDeviceID(deviceUID: outputUID) else {
            throw AudioRouteFailure(kind: .missingOutput, stage: "route.resolveOutput", status: nil, detail: "uid=\(outputUID)")
        }
        renderState = .allocate(capacity: 1)
        renderState.initialize(to: RenderState(
            volume: Int32(volume), muted: muted ? 1 : 0, layoutIssue: 0,
            callbackCount: 0, captureCallbackCount: 0, outputSourceCallbackCount: 0,
            emptyInputCallbacks: 0, renderedFrames: 0,
            inputPeakMicros: 0, outputPeakMicros: 0,
            inputBufferCount: 0, outputBufferCount: 0,
            inputChannels: 0, outputChannels: 0, inputBytes: 0, outputBytes: 0,
            inputFrames: 0, outputFrames: 0, ringBuffer: nil
        ))

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDescription.name = "Mixer process tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped
        var createdTap: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTap)
        guard tapStatus == noErr else {
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            throw AudioRouteFailure(kind: MixerAudioError(status: tapStatus, fallback: .tapCreateFailed), stage: "tap.create", status: tapStatus, detail: nil)
        }
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: Unmanaged<CFString>?
        var tapUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(createdTap, &property, 0, nil, &tapUIDSize, pointer)
        }
        guard uidStatus == noErr, let tapUID else {
            AudioHardwareDestroyProcessTap(createdTap)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            throw AudioRouteFailure(kind: .tapUIDReadFailed, stage: "tap.readUID", status: uidStatus, detail: nil)
        }
        tapID = createdTap
        let tapUIDString = tapUID.takeRetainedValue() as String

        let tapRead = catalog.tapFormat(tapID: createdTap)
        let outputRead = catalog.outputFormats(deviceUID: outputUID)
        let outputFormats = outputRead.formats
        guard let tapFormat = tapRead.format,
              outputFormats.count == 1,
              let outputFormat = outputFormats.first,
              Self.supportsStereoFloat32(tapFormat),
              Self.supportsFloat32Output(outputFormat) else {
            let formatDetail = "tapReadStatus=\(tapRead.status) outputReadStatus=\(outputRead.status) tap=\(formatDescription(tapRead.format)) outputCount=\(outputFormats.count) outputs=[\(outputFormats.map { formatDescription($0) }.joined(separator: ";"))]"
            AudioHardwareDestroyProcessTap(createdTap)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            let status = tapRead.status != noErr ? tapRead.status : (outputRead.status != noErr ? outputRead.status : nil)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "format.preAggregate", status: status, detail: formatDetail)
        }
        tapFormatSummary = formatDescription(tapFormat)
        outputFormatSummary = formatDescription(outputFormat)

        let conversionRequired = requiresNativeOutputConversion(
            tapRate: tapFormat.mSampleRate,
            selectedOutputRate: outputFormat.mSampleRate,
            selectedOutputChannels: outputFormat.mChannelsPerFrame
        )
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer · \(String(UUID().uuidString.prefix(8)))",
            kAudioAggregateDeviceUIDKey: "com.codex.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUIDString
            ]],
            kAudioAggregateDeviceTapAutoStartKey: 0
        ]
        if conversionRequired {
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = []
        } else {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceInputChannelsKey: 0
            ]]
            aggregateDescription[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUIDString,
                kAudioSubTapDriftCompensationKey: 1,
                kAudioSubTapDriftCompensationQualityKey: Int(kAudioAggregateDriftCompensationHighQuality)
            ]]
        }
        var createdAggregate: AudioObjectID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            throw AudioRouteFailure(kind: MixerAudioError(status: aggregateStatus, fallback: .aggregateCreateFailed), stage: "aggregate.create", status: aggregateStatus, detail: "output=\(outputUID)")
        }
        aggregateID = createdAggregate

        let aggregateInputRead = catalog.streamFormats(deviceID: aggregateID, scope: kAudioDevicePropertyScopeInput)
        let aggregateOutputRead = catalog.streamFormats(deviceID: aggregateID, scope: kAudioDevicePropertyScopeOutput)
        let aggregateInputs = aggregateInputRead.formats
        let aggregateOutputs = aggregateOutputRead.formats
        aggregateInputFormatSummary = aggregateInputs.map { formatDescription($0) }.joined(separator: ";")
        aggregateOutputFormatSummary = aggregateOutputs.map { formatDescription($0) }.joined(separator: ";")
        let aggregateInputMatchesTap = aggregateInputs.count == 1
            && Self.supportsStereoFloat32(aggregateInputs[0])
            && aggregateCaptureMatchesTap(tapRate: tapFormat.mSampleRate, aggregateInputRate: aggregateInputs[0].mSampleRate)
        let aggregateOutputMatchesDevice = conversionRequired || (
            aggregateOutputs.count == 1
                && Self.supportsStereoFloat32(aggregateOutputs[0])
                && Self.formatsAreCompatible(outputFormat, aggregateOutputs[0])
        )
        guard aggregateInputMatchesTap, aggregateOutputMatchesDevice else {
            let formatDetail = "inputReadStatus=\(aggregateInputRead.status) outputReadStatus=\(aggregateOutputRead.status) tap=\(tapFormatSummary) output=\(outputFormatSummary) aggregateInputs.count=\(aggregateInputs.count) [\(aggregateInputFormatSummary)] aggregateOutputs.count=\(aggregateOutputs.count) [\(aggregateOutputFormatSummary)] conversionRequired=\(conversionRequired)"
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            let status = aggregateInputRead.status != noErr ? aggregateInputRead.status : (aggregateOutputRead.status != noErr ? aggregateOutputRead.status : nil)
            throw AudioRouteFailure(kind: .unsupportedFormat, stage: "format.aggregate", status: status, detail: formatDetail)
        }

        if conversionRequired {
            routeModeSummary = "tap-only aggregate + AVAudioEngine conversion"
            do {
                outputEngine = try AudioEngineOutput(
                    deviceID: outputDeviceID,
                    tapRate: tapFormat.mSampleRate,
                    expectedOutputRate: outputFormat.mSampleRate,
                    expectedOutputChannels: outputFormat.mChannelsPerFrame,
                    renderState: renderState
                )
            } catch {
                renderState.pointee.ringBuffer = nil
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                renderState.deinitialize(count: 1)
                renderState.deallocate()
                throw error
            }
        } else {
            routeModeSummary = "same-rate aggregate IOProc"
        }

        var createdIOProc: AudioDeviceIOProcID?
        let callback = conversionRequired ? mixerCaptureIOProc : mixerIOProc
        let procStatus = AudioDeviceCreateIOProcID(aggregateID, callback, UnsafeMutableRawPointer(renderState), &createdIOProc)
        guard procStatus == noErr, let createdIOProc else {
            outputEngine?.stop()
            outputEngine = nil
            renderState.pointee.ringBuffer = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            throw AudioRouteFailure(kind: MixerAudioError(status: procStatus, fallback: .ioProcCreateFailed), stage: "ioproc.create", status: procStatus, detail: nil)
        }
        ioProcID = createdIOProc

        let startStatus = AudioDeviceStart(aggregateID, createdIOProc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, createdIOProc)
            outputEngine?.stop()
            outputEngine = nil
            renderState.pointee.ringBuffer = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            renderState.deinitialize(count: 1)
            renderState.deallocate()
            throw AudioRouteFailure(kind: MixerAudioError(status: startStatus, fallback: .deviceStartFailed), stage: "aggregate.start", status: startStatus, detail: nil)
        }

        if let outputEngine {
            let ring = outputEngine.ring
            let prefillDeadline = Date().addingTimeInterval(0.08)
            while ring.metrics().fillFrames < 1_024 && Date() < prefillDeadline {
                usleep(1_000)
            }
            do {
                try outputEngine.start()
            } catch {
                AudioDeviceStop(aggregateID, createdIOProc)
                AudioDeviceDestroyIOProcID(aggregateID, createdIOProc)
                self.ioProcID = nil
                outputEngine.stop()
                self.outputEngine = nil
                renderState.pointee.ringBuffer = nil
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                renderState.deinitialize(count: 1)
                renderState.deallocate()
                throw error
            }
        }
    }

    func set(volume: Int, muted: Bool) {
        let current = OSAtomicAdd32Barrier(0, &renderState.pointee.volume)
        _ = OSAtomicAdd32Barrier(Int32(volume) - current, &renderState.pointee.volume)
        let oldMuted = OSAtomicAdd32Barrier(0, &renderState.pointee.muted)
        let newMuted: Int32 = muted ? 1 : 0
        _ = OSAtomicAdd32Barrier(newMuted - oldMuted, &renderState.pointee.muted)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if outputEngine != nil { set(volume: 0, muted: true) }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        outputEngine?.stop()
        outputEngine = nil
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        renderState.pointee.ringBuffer = nil
        renderState.deinitialize(count: 1)
        renderState.deallocate()
    }

    deinit { stop() }

    private static func supportsStereoFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        supportsFloat32(format, expectedChannels: 2)
    }

    private static func supportsFloat32Output(_ format: AudioStreamBasicDescription) -> Bool {
        (format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2)
            && supportsFloat32(format, expectedChannels: format.mChannelsPerFrame)
    }

    private static func supportsFloat32(_ format: AudioStreamBasicDescription, expectedChannels: UInt32) -> Bool {
        let planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let expectedBytesPerFrame = planar ? 4 : expectedChannels * 4
        return format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame == expectedChannels
            && format.mSampleRate.isFinite
            && format.mSampleRate > 0
            && format.mFramesPerPacket == 1
            && format.mBytesPerFrame == expectedBytesPerFrame
    }

    private static func formatsAreCompatible(_ tap: AudioStreamBasicDescription, _ output: AudioStreamBasicDescription) -> Bool {
        supportsStereoFloat32(tap)
            && supportsFloat32Output(output)
            && output.mChannelsPerFrame == 2
            && tap.mSampleRate == output.mSampleRate
    }

    func hasRuntimeLayoutIssue() -> Bool {
        OSAtomicAdd32Barrier(0, &renderState.pointee.layoutIssue) != 0
    }

    func diagnosticLine(appID: String, processPIDs: [pid_t], processAttributions: [AudioProcessAttribution], targetUID: String, volume: Int, muted: Bool) -> String {
        let atomicVolume = OSAtomicAdd32Barrier(0, &renderState.pointee.volume)
        let atomicMuted = OSAtomicAdd32Barrier(0, &renderState.pointee.muted) != 0
        let callbacks = OSAtomicAdd32Barrier(0, &renderState.pointee.callbackCount)
        let captureCallbacks = OSAtomicAdd32Barrier(0, &renderState.pointee.captureCallbackCount)
        let outputSourceCallbacks = OSAtomicAdd32Barrier(0, &renderState.pointee.outputSourceCallbackCount)
        let emptyCallbacks = OSAtomicAdd32Barrier(0, &renderState.pointee.emptyInputCallbacks)
        let frames = OSAtomicAdd32Barrier(0, &renderState.pointee.renderedFrames)
        let inputPeak = Float(atomicTakeAndReset(&renderState.pointee.inputPeakMicros)) / 1_000_000
        let outputPeak = Float(atomicTakeAndReset(&renderState.pointee.outputPeakMicros)) / 1_000_000
        let inputBuffers = OSAtomicAdd32Barrier(0, &renderState.pointee.inputBufferCount)
        let outputBuffers = OSAtomicAdd32Barrier(0, &renderState.pointee.outputBufferCount)
        let inputChannels = OSAtomicAdd32Barrier(0, &renderState.pointee.inputChannels)
        let outputChannels = OSAtomicAdd32Barrier(0, &renderState.pointee.outputChannels)
        let inputBytes = OSAtomicAdd32Barrier(0, &renderState.pointee.inputBytes)
        let outputBytes = OSAtomicAdd32Barrier(0, &renderState.pointee.outputBytes)
        let inputFrames = OSAtomicAdd32Barrier(0, &renderState.pointee.inputFrames)
        let outputFrames = OSAtomicAdd32Barrier(0, &renderState.pointee.outputFrames)
        let issue = OSAtomicAdd32Barrier(0, &renderState.pointee.layoutIssue)
        let ringMetrics = outputEngine?.ring.metrics()
        let gain = atomicMuted ? 0 : atomicVolume
        let status: String
        if issue != 0 {
            status = "FAILED_LAYOUT"
        } else if callbacks == 0 {
            status = "STARTED_NO_CALLBACK"
        } else if outputEngine != nil && outputSourceCallbacks == 0 {
            status = "NO_ENGINE_CALLBACK"
        } else if inputPeak == 0 && outputPeak == 0 {
            status = "NO_RECENT_AUDIO"
        } else {
            status = "ACTIVE"
        }
        let processes = processAttributions.map(\.diagnosticText).joined(separator: ";")
        return "app=\(appID) pids=\(processPIDs) processes=[\(processes)] target=\(targetUID) status=\(status) route=\(routeModeSummary) requested=\(muted ? 0 : volume)% atomicGain=\(gain)% tapFormat={\(tapFormatSummary)} outputFormat={\(outputFormatSummary)} aggregateInput={\(aggregateInputFormatSummary)} aggregateOutput={\(aggregateOutputFormatSummary)} callbacks=\(callbacks) captureCallbacks=\(captureCallbacks) engineCallbacks=\(outputSourceCallbacks) emptyInput=\(emptyCallbacks) framesOut=\(frames) lastInputFrames=\(inputFrames) lastOutputFrames=\(outputFrames) ringFill=\(ringMetrics?.fillFrames ?? 0) ringOverflowFrames=\(ringMetrics?.overflowFrames ?? 0) ringUnderflowFrames=\(ringMetrics?.underflowFrames ?? 0) peakInLastInterval=\(String(format: "%.6f", inputPeak)) peakOutLastInterval=\(String(format: "%.6f", outputPeak)) buffersIn=\(inputBuffers)/\(inputChannels)ch/\(inputBytes)B buffersOut=\(outputBuffers)/\(outputChannels)ch/\(outputBytes)B engineOutput={\(outputEngine?.outputFormatSummary ?? "not used")} layoutIssue=\(issue)"
    }
}
