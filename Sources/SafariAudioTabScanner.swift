import ApplicationServices
import Foundation

struct BrowserTabReference: Equatable, Sendable {
    let id: String
    let title: String
    let audible: Bool
}

struct SafariAXNode: Equatable {
    let role: String
    var controlID: String? = nil
    let identifier: String?
    let title: String?
    let description: String?
    let value: String?
    let isSelected: Bool
    let children: [SafariAXNode]

    init(
        role: String,
        identifier: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        isSelected: Bool = false,
        children: [SafariAXNode] = []
    ) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
        self.value = value
        self.isSelected = isSelected
        self.children = children
    }
}

struct SafariTabAudioExtraction: Equatable {
    var allTabs: [BrowserTabReference] = []
    let titles: [String]
    let tabBarCount: Int
    let tabCount: Int
    let visitedNodeCount: Int
    let wasTruncated: Bool
    let attributeErrorCount: Int
    let structureSummary: [String]
}

struct SafariTabAudioSnapshot: Equatable {
    let accessibilityTrusted: Bool
    let safariRunning: Bool
    let extraction: SafariTabAudioExtraction

    static func unavailable(trusted: Bool, safariRunning: Bool) -> SafariTabAudioSnapshot {
        SafariTabAudioSnapshot(
            accessibilityTrusted: trusted,
            safariRunning: safariRunning,
            extraction: SafariTabAudioExtraction(
                titles: [],
                tabBarCount: 0,
                tabCount: 0,
                visitedNodeCount: 0,
                wasTruncated: false,
                attributeErrorCount: 0,
                structureSummary: []
            )
        )
    }
}

enum BrowserTabKind { case safari, chromium }

/// Reads only tab-bar chrome; page content is never inspected.
final class SafariAudioTabScanner {
    private let maximumNodes = 320
    private let maximumDepth = 10
    private let maximumWindows = 12
    private let maximumChildrenPerElement = 80
    private let maximumScanDuration = 1.0
    private let messageTimeout: Float = 0.08
    private var attributeErrorCount = 0
    private var kind: BrowserTabKind = .safari
    private var arrayReadSummary: [String] = []
    private var visitedElements: [AXUIElement] = []
    private var tabElements: [String: AXUIElement] = [:]
    private var tabWindows: [String: AXUIElement] = [:]
    private var currentWindow: AXUIElement?

    func scan(safariPID: pid_t?) -> SafariTabAudioSnapshot {
        scan(browserPID: safariPID, kind: .safari)
    }

    func scan(browserPID: pid_t?, kind: BrowserTabKind) -> SafariTabAudioSnapshot {
        self.kind = kind
        attributeErrorCount = 0
        arrayReadSummary = []
        visitedElements = []
        tabElements = [:]
        tabWindows = [:]
        let trusted = AXIsProcessTrusted()
        guard let browserPID else {
            return .unavailable(trusted: trusted, safariRunning: false)
        }
        guard trusted else {
            return .unavailable(trusted: false, safariRunning: true)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + maximumScanDuration
        let application = AXUIElementCreateApplication(browserPID)
        _ = AXUIElementSetMessagingTimeout(application, messageTimeout)

        var windowElements = copyElements(application, attribute: "AXWindows", deadline: deadline)
        if windowElements.isEmpty && kind == .chromium {
            // Chromium exposes its AX tree when an assistive client requests it.
            let activation = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            arrayReadSummary.append("enhancedAX=\(activation.rawValue)")
            windowElements = copyElements(application, attribute: "AXWindows", deadline: deadline)
        }
        if windowElements.isEmpty {
            for attribute in ["AXFocusedWindow", "AXMainWindow"] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
                if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    windowElements = [unsafeBitCast(value, to: AXUIElement.self)]
                    break
                }
                arrayReadSummary.append("\(attribute)=\(status.rawValue)")
            }
        }
        let fallbackChildren = windowElements.isEmpty ? copyElements(application, attribute: "AXChildren", deadline: deadline) : []
        arrayReadSummary.insert("pid=\(browserPID):role=\(copyString(application, attribute: "AXRole", deadline: deadline) ?? "none")", at: 0)
        let windows = (windowElements.isEmpty ? fallbackChildren : windowElements).prefix(maximumWindows)
        var budget = maximumNodes
        var truncated = false
        let windowNodes = windows.compactMap { window in
            currentWindow = window
            return readNode(
                window,
                context: .normal,
                depth: 0,
                deadline: deadline,
                budget: &budget,
                truncated: &truncated
            )
        }
        let root = SafariAXNode(role: "AXApplication", children: windowNodes)
        let extraction = extractSafariAudibleTabs(
            from: root,
            maximumNodes: maximumNodes,
            maximumDepth: maximumDepth,
            kind: kind
        )
        return SafariTabAudioSnapshot(
            accessibilityTrusted: true,
            safariRunning: true,
            extraction: SafariTabAudioExtraction(
                allTabs: extraction.allTabs,
                titles: extraction.titles,
                tabBarCount: extraction.tabBarCount,
                tabCount: extraction.tabCount,
                visitedNodeCount: max(extraction.visitedNodeCount, maximumNodes - budget),
                wasTruncated: truncated || extraction.wasTruncated,
                attributeErrorCount: min(99, attributeErrorCount),
                structureSummary: ["windows=\(windowNodes.count)"] + arrayReadSummary + extraction.structureSummary
            )
        )
    }

    static func requestAccessibilityTrustPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private enum Context {
        case normal
        case tabBar
        case tab
        case tabIndicator
    }

    private func readNode(
        _ element: AXUIElement,
        context: Context,
        depth: Int,
        deadline: TimeInterval,
        budget: inout Int,
        truncated: inout Bool
    ) -> SafariAXNode? {
        guard budget > 0, depth <= maximumDepth, ProcessInfo.processInfo.systemUptime < deadline else {
            truncated = true
            return nil
        }
        guard !visitedElements.contains(where: { CFEqual($0, element) }) else { return nil }
        visitedElements.append(element)
        budget -= 1

        let rawRole = copyString(element, attribute: "AXRole", deadline: deadline) ?? ""
        let role = canonicalBrowserAXRole(rawRole,
            description: rawRole.contains("Opaque") ? copyString(element, attribute: "AXRoleDescription", deadline: deadline) : nil)
        if role == "AXWebArea" || role == "AXWebView" || role == "AXMenuBar" || role == "AXMenu" {
            return SafariAXNode(role: role)
        }
        let identifier = copyString(element, attribute: "AXIdentifier", deadline: deadline)

        let isIdentifierMatchedBar = context == .normal && isSafariTabBarIdentifier(identifier)
        let possibleBarDescription: String?
        if context == .normal && !isIdentifierMatchedBar && (role == "AXGroup" || role == "AXTabGroup") {
            possibleBarDescription = copyString(element, attribute: "AXDescription", deadline: deadline)
        } else {
            possibleBarDescription = nil
        }
        let isTabBar = isIdentifierMatchedBar || (context == .normal && (isSafariTabBarDescription(possibleBarDescription) || (kind == .chromium && role == "AXTabGroup")))
        let nextContext: Context = isTabBar ? .tabBar : context
        let isTab = context == .tabBar && isSafariTab(role: role, identifier: identifier)
        let elementContext: Context = isTab ? .tab : nextContext

        let title: String?
        let description: String?
        let value: String?
        let selected: Bool
        switch elementContext {
        case .tab:
            title = copyString(element, attribute: "AXTitle", deadline: deadline)
            description = copyString(element, attribute: "AXDescription", deadline: deadline)
            value = copyString(element, attribute: "AXValue", deadline: deadline)
            selected = copyBoolean(element, attribute: "AXSelected", deadline: deadline)
        case .tabBar where isTabBar:
            title = nil
            description = possibleBarDescription
            value = nil
            selected = false
        case .tabIndicator:
            title = copyString(element, attribute: "AXTitle", deadline: deadline)
            description = copyString(element, attribute: "AXDescription", deadline: deadline)
            value = role == "AXStaticText" ? copyString(element, attribute: "AXValue", deadline: deadline) : nil
            selected = false
        default:
            title = nil
            description = nil
            value = nil
            selected = false
        }

        let children: [SafariAXNode]
        switch elementContext {
        case .tabIndicator:
            // Safari may wrap the audio button/title in a small group. Never enter a page.
            children = (role == "AXGroup" || role.contains("Opaque")) ? readChildren(element, context: .tabIndicator, depth: depth + 1, deadline: deadline, budget: &budget, truncated: &truncated) : []
        case .tab:
            children = readChildren(
                element,
                context: .tabIndicator,
                depth: depth + 1,
                deadline: deadline,
                budget: &budget,
                truncated: &truncated
            )
        case .tabBar:
            let childNodes = readChildren(
                element,
                context: .tabBar,
                depth: depth + 1,
                deadline: deadline,
                budget: &budget,
                truncated: &truncated
            )
                if childNodes.isEmpty {
                children = readChildren(
                    element,
                    attribute: "AXTabs",
                    context: .tabBar,
                    depth: depth + 1,
                    deadline: deadline,
                    budget: &budget,
                    truncated: &truncated
                )
            } else {
                children = childNodes
            }
        case .normal:
            children = readChildren(
                element,
                context: .normal,
                depth: depth + 1,
                deadline: deadline,
                budget: &budget,
                truncated: &truncated
            )
        }

        var node = SafariAXNode(
            role: role,
            identifier: identifier,
            title: title,
            description: description,
            value: value,
            isSelected: selected,
            children: children
        )
        if isTab {
            let id = String(CFHash(element))
            node.controlID = id
            tabElements[id] = element
            tabWindows[id] = currentWindow
        }
        return node
    }

    private func readChildren(
        _ element: AXUIElement,
        attribute: String = "AXChildren",
        context: Context,
        depth: Int,
        deadline: TimeInterval,
        budget: inout Int,
        truncated: inout Bool
    ) -> [SafariAXNode] {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            truncated = true
            return []
        }
        let elements = copyElements(element, attribute: attribute, deadline: deadline)
            .prefix(maximumChildrenPerElement)
        return elements.compactMap { child in
            readNode(
                child,
                context: context,
                depth: depth,
                deadline: deadline,
                budget: &budget,
                truncated: &truncated
            )
        }
    }

    private func copyElements(_ element: AXUIElement, attribute: String, deadline: TimeInterval) -> [AXUIElement] {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
        _ = AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        recordAttributeStatus(status)
        if arrayReadSummary.count < 6 {
            arrayReadSummary.append("\(attribute):status=\(status.rawValue):type=\(value.map { CFGetTypeID($0) } ?? 0)")
        }
        guard status == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let child = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(child, to: AXUIElement.self)
        }
    }

    private func copyString(_ element: AXUIElement, attribute: String, deadline: TimeInterval) -> String? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        recordAttributeStatus(status)
        guard status == .success, let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private func copyBoolean(_ element: AXUIElement, attribute: String, deadline: TimeInterval) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        _ = AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        recordAttributeStatus(status)
        guard status == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func recordAttributeStatus(_ status: AXError) {
        guard status != .success,
              status != .noValue,
              status != .attributeUnsupported,
              attributeErrorCount < 99 else { return }
        attributeErrorCount += 1
    }
}

func extractSafariAudibleTabs(
    from root: SafariAXNode,
    maximumNodes: Int = 320,
    maximumDepth: Int = 10,
    kind: BrowserTabKind = .safari
) -> SafariTabAudioExtraction {
    var remaining = max(0, maximumNodes)
    var visited = 0
    var tabBarCount = 0
    var tabCount = 0
    var truncated = false
    var titles: [String] = []
    var allTabs: [BrowserTabReference] = []
    var structureSummary: [String] = []

    func consumeNode(depth: Int) -> Bool {
        guard remaining > 0, depth <= maximumDepth else {
            truncated = true
            return false
        }
        remaining -= 1
        visited += 1
        return true
    }

    func visit(_ node: SafariAXNode, depth: Int) {
        guard consumeNode(depth: depth) else { return }
        guard node.role != "AXWebArea" && node.role != "AXWebView" else { return }

        let structuralRole = ["AXGroup", "AXTabGroup", "AXRadioButton"].contains(node.role)
        let hasTabBarIdentifier = node.identifier?.localizedCaseInsensitiveContains("TabBar") == true
        if structureSummary.count < 24 && (structuralRole || hasTabBarIdentifier) {
            let role = node.role.isEmpty ? "?" : String(node.role.prefix(32))
            let identifier = hasTabBarIdentifier ? (accessibilityIdentifierStem(node.identifier) ?? "-") : "-"
            structureSummary.append("\(role)#\(identifier)")
        }

        if isSafariTabBarIdentifier(node.identifier) || isSafariTabBarDescription(node.description) || (kind == .chromium && node.role == "AXTabGroup") {
            tabBarCount += 1
            var tabs: [SafariAXNode] = []
            func collectTabs(_ candidate: SafariAXNode, depth: Int) {
                guard consumeNode(depth: depth) else { return }
                guard candidate.role != "AXWebArea" && candidate.role != "AXWebView" else { return }
                if isSafariTab(role: candidate.role, identifier: candidate.identifier) {
                    tabs.append(candidate)
                    return
                }
                for child in candidate.children {
                    collectTabs(child, depth: depth + 1)
                    if remaining == 0 { break }
                }
            }
            for child in node.children {
                collectTabs(child, depth: depth + 1)
                if remaining == 0 { break }
            }
            for tab in tabs {
                tabCount += 1
                var hasAudioButton = kind == .chromium && chromiumTabHasAudio(tab)
                func inspectIndicator(_ indicator: SafariAXNode, depth: Int) {
                    guard consumeNode(depth: depth), indicator.role != "AXWebArea", indicator.role != "AXWebView" else { return }
                    if isUnmutedAudioButton(indicator) { hasAudioButton = true }
                    for child in indicator.children { inspectIndicator(child, depth: depth + 1) }
                }
                for indicator in tab.children { inspectIndicator(indicator, depth: depth + 2) }
                guard let rawTitle = safariTabTitle(tab),
                      let title = kind == .chromium ? chromiumTabTitle(rawTitle) : cleanedBrowserTabTitle(rawTitle) else { continue }
                if let id = tab.controlID { allTabs.append(BrowserTabReference(id: id, title: title, audible: hasAudioButton)) }
                if hasAudioButton { titles.append(title) }
            }
            return
        }

        for child in node.children {
            visit(child, depth: depth + 1)
            if remaining == 0 { break }
        }
    }

    visit(root, depth: 0)
    return SafariTabAudioExtraction(
        allTabs: allTabs,
        titles: titles,
        tabBarCount: tabBarCount,
        tabCount: tabCount,
        visitedNodeCount: visited,
        wasTruncated: truncated,
        attributeErrorCount: 0,
        structureSummary: structureSummary
    )
}

private func safariTabTitle(_ tab: SafariAXNode) -> String? {
    func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    if let title = clean(tab.title) { return title }
    func titleField(in node: SafariAXNode, depth: Int = 0) -> SafariAXNode? {
        guard depth < 4, node.role != "AXWebArea", node.role != "AXWebView" else { return nil }
        if node.role == "AXStaticText", node.identifier?.localizedCaseInsensitiveContains("_titleTextField") == true { return node }
        return node.children.lazy.compactMap { titleField(in: $0, depth: depth + 1) }.first
    }
    let titleField = titleField(in: tab)
    if let value = clean(titleField?.value) {
        return value
    }
    guard let description = clean(tab.description) else { return nil }
    let normalized = description
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let genericDescriptions: Set<String> = ["aba", "tab", "aba selecionada", "selected tab"]
    return genericDescriptions.contains(normalized) ? nil : description
}

private func isSafariTabBarIdentifier(_ identifier: String?) -> Bool {
    accessibilityIdentifierStem(identifier) == "tabbar"
}

private func isSafariTabBarDescription(_ description: String?) -> Bool {
    guard let description else { return false }
    let normalized = description
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix("barra de abas") || normalized.hasPrefix("tab bar")
}

private func isSafariTab(role: String, identifier: String?) -> Bool {
    if let identifier {
        return accessibilityIdentifierStem(identifier) == "tabbartab"
    }
    return role == "AXRadioButton" || role == "AXTab" || role == "AXTabButton"
}

private func accessibilityIdentifierStem(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return String(identifier.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        .lowercased()
}

private func isUnmutedAudioButton(_ node: SafariAXNode) -> Bool {
    guard node.role == "AXButton" || node.role.contains("Opaque") else { return false }
    let label = [node.title, node.description]
        .compactMap { $0 }
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let isMuteAction = label.contains("silenciar aba") || label.contains("silenciar esta aba") || label.contains("mute tab") || label.contains("mute this tab") || label.contains("desativar som da guia")
    let isUnmuteAction = label.contains("unmute") || label.contains("ativar") || label.contains("ligar som")
    return isMuteAction && !isUnmuteAction
}


private func chromiumTabHasAudio(_ node: SafariAXNode) -> Bool {
    let label = [node.title, node.description].compactMap { $0 }.joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let muted = ["audio muted", "audio silenciado", "audio desativado", "som silenciado", "tab muted", "guia silenciada"]
    guard !muted.contains(where: label.contains) else { return false }
    return ["audio playing", "playing audio", "reproduzindo audio", "reproducao de audio", "reproduzindo som", "audio em reproducao", "tocando audio"].contains(where: label.contains)
}


// Newer macOS versions may expose browser chrome through opaque AX providers.
// Normalize semantic roles while retaining the same page-content exclusion.
func canonicalBrowserAXRole(_ role: String, description: String?) -> String {
    guard role.contains("Opaque"), let description else { return role }
    let text = description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    switch text {
    case "grupo de abas", "grupo de guias", "tab group": return "AXTabGroup"
    case "aba", "guia", "tab", "radio button", "botao de opcao": return "AXRadioButton"
    case "botao", "button": return "AXButton"
    case "texto", "text", "static text": return "AXStaticText"
    case "conteudo html", "html content", "web area": return "AXWebArea"
    case "container", "grupo", "group": return "AXGroup"
    default: return role
    }
}


func cleanedBrowserTabTitle(_ value: String) -> String? {
    let title = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : String(title.prefix(1_024))
}

/// Chrome can expose the memory tooltip as the tab's accessible title. Remove
/// only its known wrapper; never infer a source from the selected tab or URL.
func chromiumTabTitle(_ raw: String) -> String? {
    var title = raw
    let prefixes = ["Uso da memória em ", "Memory usage for ", "Memory usage of "]
    if let prefix = prefixes.first(where: { title.range(of: $0, options: [.anchored, .caseInsensitive]) != nil }) {
        title = String(title.dropFirst(prefix.count))
        title = title.replacingOccurrences(of: #":\s*[0-9.,]+\s*(?:[KMGT]?B|bytes)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        for marker in [": parte do grupo ", ": part of group ", ": part of the group "] {
            if let range = title.range(of: marker, options: .caseInsensitive) {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        for marker in [" - Reprodução de áudio", " - Áudio desativado", " - Audio playing", " - Audio muted"] {
            if title.hasSuffix(marker) { title = String(title.dropLast(marker.count)) }
        }
    }
    return cleanedBrowserTabTitle(title)
}

