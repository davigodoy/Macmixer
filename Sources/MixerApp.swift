import AppKit
import ServiceManagement
import SwiftUI

@main
struct MixerApp: App {
    @NSApplicationDelegateAdaptor(MixerAppDelegate.self) private var appDelegate
    @StateObject private var model = MixerModel.shared
    @StateObject private var loginItem = LoginItemModel()

    var body: some Scene {
        #if MIXER_UI_TEST
        WindowGroup("Mixer") {
            MixerPopover(model: model, loginItem: loginItem)
        }
        .windowResizability(.contentSize)
        #else
        MenuBarExtra {
            MixerPopover(model: model, loginItem: loginItem)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .accessibilityLabel("Mixer")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isRegistered: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    var message: String? {
        if let errorMessage { return errorMessage }
        switch status {
        case .requiresApproval:
            return "Aprove em Ajustes do Sistema → Geral → Itens de Início."
        case .notFound:
            return "O macOS não encontrou este app de início."
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Não foi possível atualizar o início automático."
        }
        refresh()
    }
}

final class MixerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MixerModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MixerModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MixerPopover: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var loginItem: LoginItemModel

    private var producingApps: [AudioApp] { model.apps.filter { $0.isProducingAudio } }
    private var retainedAudioApps: [AudioApp] { model.apps.filter { $0.hasAudioClient && !$0.isProducingAudio } }
    private var otherOpenApps: [AudioApp] { model.apps.filter { !$0.hasAudioClient } }

    private var listViewportHeight: CGFloat {
        let sectionHeader: CGFloat = 24
        func rowsHeight(_ apps: [AudioApp]) -> CGFloat {
            apps.reduce(0) { height, app in
                height + 128 + CGFloat(app.sourceMetadata?.browserBundleID == nil || (app.sourceMetadata?.titles.count ?? 0) <= 1 ? 0 : (app.sourceMetadata?.titles.count ?? 0)) * 23
            }
        }
        var height: CGFloat = producingApps.isEmpty ? 92 : sectionHeader + rowsHeight(producingApps)
        if !retainedAudioApps.isEmpty {
            height += sectionHeader + rowsHeight(retainedAudioApps)
        }
        if !otherOpenApps.isEmpty {
            height += 42
            if model.otherAppsExpanded {
                height += rowsHeight(otherOpenApps)
            }
        }
        return min(398, max(116, height))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mixer")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    model.refreshNow(forceRetry: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Atualizar apps")
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 12)

            if let message = model.permissionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if model.shouldRequestAccessibilityPermission {
                HStack(spacing: 8) {
                    Text("Permita o acesso para mostrar as abas com áudio.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Permitir abas") {
                        model.openAccessibilitySettings()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if !producingApps.isEmpty {
                        sectionTitle("Fontes de áudio (\(producingApps.count))")
                        rows(producingApps)
                    } else {
                        VStack(spacing: 7) {
                            Image(systemName: "waveform")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Nenhum app reproduzindo áudio.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .padding(.horizontal, 28)
                    }

                    if !retainedAudioApps.isEmpty {
                        sectionTitle("Clientes de áudio recentes")
                        rows(retainedAudioApps)
                    }

                    if !otherOpenApps.isEmpty {
                        DisclosureGroup(isExpanded: $model.otherAppsExpanded) {
                            rows(otherOpenApps)
                        } label: {
                            Text("Outros apps abertos (\(otherOpenApps.count))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                    }
                }
            }
            .frame(height: listViewportHeight)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            model.recordPopoverLayout(viewportHeight: Double(geometry.size.height), event: "appear")
                        }
                        .onChange(of: geometry.size.height) { _, height in
                            model.recordPopoverLayout(viewportHeight: Double(height), event: "resize")
                        }
                }
            }
            .onChange(of: model.apps.count) { _, _ in
                model.recordPopoverLayout(viewportHeight: Double(listViewportHeight), event: "apps-change")
            }
            .onChange(of: model.otherAppsExpanded) { _, _ in
                model.recordPopoverLayout(viewportHeight: Double(listViewportHeight), event: "disclosure-change")
            }

            Divider()

            HStack {
                Toggle("Iniciar com o sistema", isOn: Binding(
                    get: { loginItem.isRegistered },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                Button {
                    model.copyDiagnostics()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copiar diagnóstico")
                Spacer(minLength: 8)
                Button("Sair") {
                    NSApp.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            if let message = loginItem.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 356)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func rows(_ apps: [AudioApp]) -> some View {
        ForEach(apps) { app in
            AppAudioRow(app: app, model: model)
            if app.id != apps.last?.id {
                Divider().padding(.leading, 18)
            }
        }
    }

}

private struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 13
    var weight: NSFont.Weight = .medium

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private var font: Font { .system(size: fontSize, weight: weight == .regular ? .regular : .medium) }

    private var measuredWidth: CGFloat {
        (text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: weight)]
        ).width
    }

    var body: some View {
        GeometryReader { geometry in
            let overflows = measuredWidth > geometry.size.width + 1
            Group {
                if overflows && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !overflows || reduceMotion)) { context in
                        let distance = max(0, measuredWidth - geometry.size.width)
                        let travelDuration = Double(distance / 24)
                        let phase = max(0, context.date.timeIntervalSince(startedAt))
                            .truncatingRemainder(dividingBy: travelDuration + 4)
                        let offset = phase < 2 ? 0 : min(distance, CGFloat(phase - 2) * 24)
                        Text(text).font(font).fixedSize()
                        .offset(x: -offset)
                        .frame(width: geometry.size.width, height: 18, alignment: .leading)
                        .clipped()
                    }
                } else {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: geometry.size.width, height: 18, alignment: .leading)
                }
            }
            .clipped()
        }
        .frame(height: 18)
        .onAppear { startedAt = Date() }
        .onChange(of: text) { _, _ in startedAt = Date() }
        .help(text)
        .accessibilityLabel(text)
    }
}

private struct AppAudioRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel

    private var settings: AppAudioSettings { model.settings(for: app.id) }
    private var sourceName: String {
        guard let source = app.sourceMetadata else { return app.name }
        return source.browserBundleID == nil ? source.summary : source.label
    }
    private var sourceIcon: NSImage {
        if let bundleID = app.sourceMetadata?.browserBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return app.icon
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(nsImage: sourceIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 23, height: 23)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    if let source = app.sourceMetadata {
                        if source.browserBundleID != nil {
                            MarqueeText(text: source.titles.count == 1 ? source.summary : source.label, fontSize: source.titles.count == 1 ? 12 : 13)
                                .frame(maxWidth: .infinity)
                            if source.isCached {
                                Text("Última informação recebida")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            MarqueeText(text: source.summary, fontSize: 12)
                                .frame(maxWidth: .infinity)
                            Text("\(app.name) · \(source.label)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        MarqueeText(text: app.name)
                            .frame(maxWidth: .infinity)
                        if app.isProducingAudio {
                            Text(model.shouldRequestAccessibilityPermission && (app.id.hasPrefix("pid-") || app.id.contains("Chrome") || app.id.contains("Safari")) ? "Título da fonte depende de Acessibilidade" : "Título da fonte indisponível")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Sem áudio agora")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                Button {
                    model.setMuted(!settings.isMuted, for: app.id)
                } label: {
                    Image(systemName: settings.isMuted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 13))
                        .foregroundStyle(settings.isMuted ? .secondary : .primary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.isMuted ? "Ativar som" : "Silenciar")
                .accessibilityLabel("\(settings.isMuted ? "Ativar som" : "Silenciar") de \(sourceName)")
            }

            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { Double(settings.volume) },
                    set: { model.setVolume(Int($0.rounded()), for: app.id) }
                ), in: 0...100)
                .controlSize(.small)
                .accessibilityLabel("Volume de \(sourceName)")
                .accessibilityValue("\(settings.volume) por cento")
                Text("\(settings.volume)%")
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Saída")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button {
                        model.setOutput(nil, for: app.id)
                    } label: {
                        outputMenuLabel("Saída do sistema", selected: settings.outputUID == nil)
                    }
                    Divider()
                    ForEach(model.outputs) { output in
                        Button {
                            model.setOutput(output.uid, for: app.id)
                        } label: {
                            outputMenuLabel(output.name, selected: settings.outputUID == output.uid)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.outputTitle(for: settings))
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let source = app.sourceMetadata, source.browserBundleID != nil, source.titles.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(source.titles.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            MarqueeText(text: source.titles[index], fontSize: 12)
                                .frame(maxWidth: .infinity)
                                .contextMenu {
                                    Button("Copiar nome da aba") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(source.titles[index], forType: .string)
                                    }
                                }
                        }
                    }
                }
                .padding(.leading, 23)
            }

            if let error = model.error(for: app.id) {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func outputMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
