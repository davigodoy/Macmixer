import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct SafariAudioTabScannerTests {
    static func main() {
        testPortugueseAudioMarker()
        var pausedTab = tab("Paused video", selected: true)
        pausedTab.controlID = "tab-paused"
        var liveTab = tab("Live video", button: muteButton("Mute Tab"))
        liveTab.controlID = "tab-live"
        let controllable = extractSafariAudibleTabs(from: window(pausedTab, liveTab))
        expect(controllable.allTabs.map(\.id) == ["tab-paused", "tab-live"], "Stable tab references retain paused and live players")
        expect(controllable.allTabs.map(\.audible) == [false, true], "Paused references cannot be labeled audible")
        testEnglishAudioMarker()
        testMultipleAudibleTabs()
        testTitleFallbacksAndDuplicateNames()
        testDoesNotUseActiveTabOrMutedTabs()
        testDoesNotInspectWebContent()
        testRoleIndependentTabBarRecognition()
        testNodeDepthAndIndicatorBounds()
        testNestedIndicatorsAndChromium()
        print("Safari accessibility tab fixtures passed")
    }

    private static func testPortugueseAudioMarker() {
        let result = extractSafariAudibleTabs(from: window(tab("(2) Aula ao vivo", button: muteButton("Silenciar aba", description: "volume alto"))))
        expect(result.titles == ["(2) Aula ao vivo"], "Portuguese Safari mute action identifies the tab title")
        expect(result.tabBarCount == 1 && result.tabCount == 1, "tab bar and tab counts are recorded")
    }

    private static func testEnglishAudioMarker() {
        let result = extractSafariAudibleTabs(from: window(tab("News stream", button: muteButton("Mute Tab", description: "High volume"))))
        expect(result.titles == ["News stream"], "English Safari mute action identifies the tab title")
    }

    private static func testMultipleAudibleTabs() {
        let tree = window(
            tab("First stream", button: muteButton("Silenciar aba")),
            tab("Second stream", button: muteButton("Mute Tab")),
            tab("Silent tab")
        )
        let result = extractSafariAudibleTabs(from: tree)
        expect(result.titles == ["First stream", "Second stream"], "all audible tab titles are kept in tab order")
        expect(result.tabCount == 3, "silent tabs remain countable but are not labeled audible")
    }

    private static func testTitleFallbacksAndDuplicateNames() {
        let titleValue = SafariAXNode(
            role: "AXStaticText",
            identifier: "UnifiedTabBarButton._titleTextField",
            value: "Video title from AXValue"
        )
        let valueFallback = tab(nil, description: "aba", button: muteButton("Mute Tab"), extraChild: titleValue)
        let descriptionFallback = tab(nil, description: "Useful description title", button: muteButton("Silenciar aba"))
        let duplicateA = tab("Same title", button: muteButton("Mute Tab"))
        let duplicateB = tab("Same title", button: muteButton("Mute Tab"))
        let titleWins = tab("AXTitle wins", description: "Description fallback", button: muteButton("Mute Tab"), extraChild: titleValue)
        let result = extractSafariAudibleTabs(from: window(valueFallback, descriptionFallback, duplicateA, duplicateB, titleWins))
        expect(result.titles == ["Video title from AXValue", "Useful description title", "Same title", "Same title", "AXTitle wins"], "title fallback order preserves separate tabs with identical titles")
    }

    private static func testDoesNotUseActiveTabOrMutedTabs() {
        let activeButSilent = tab("Active, no audio", selected: true)
        let inactiveAndAudible = tab("Background audio", selected: false, button: muteButton("Silenciar aba"))
        let mutedPortuguese = tab("Muted Portuguese", button: muteButton("Ativar áudio da aba", description: "volume silenciado"))
        let mutedEnglish = tab("Muted English", button: muteButton("Unmute Tab", description: "Muted"))
        let result = extractSafariAudibleTabs(from: window(activeButSilent, inactiveAndAudible, mutedPortuguese, mutedEnglish))
        expect(result.titles == ["Background audio"], "audio marker wins over active-tab state and muted tabs are excluded")
    }

    private static func testDoesNotInspectWebContent() {
        let fakePageTree = tab("Page content must be ignored", button: muteButton("Mute Tab"))
        let webArea = SafariAXNode(role: "AXWebArea", children: [tabBar([fakePageTree])])
        let root = SafariAXNode(role: "AXApplication", children: [webArea])
        let result = extractSafariAudibleTabs(from: root)
        expect(result.titles.isEmpty && result.tabBarCount == 0, "Web area descendants are never treated as Safari chrome")
    }

    private static func testRoleIndependentTabBarRecognition() {
        let idBasedTab = SafariAXNode(
            role: "AXUnknown",
            identifier: "TabBarTab?isNarrow=false",
            title: "Tab from ID",
            children: [muteButton("Mute Tab")]
        )
        let idBasedBar = SafariAXNode(role: "AXGroup", identifier: "TabBar?isSeparate=false", children: [idBasedTab])
        let idResult = extractSafariAudibleTabs(from: SafariAXNode(role: "AXApplication", children: [idBasedBar]))
        expect(idResult.titles == ["Tab from ID"] && idResult.tabBarCount == 1, "TabBar IDs identify the bar and tabs without a specific AXRole")
        expect(idResult.structureSummary.contains("AXGroup#tabbar"), "diagnostics retain only the bar role and identifier stem")
        expect(!idResult.structureSummary.joined(separator: ",").contains("Tab from ID"), "diagnostics never include tab titles")

        let roleFallbackTab = SafariAXNode(role: "AXRadioButton", title: "Description fallback", children: [muteButton("Silenciar aba")])
        let descriptionBar = SafariAXNode(
            role: "AXGroup",
            description: "Barra de abas, 10 abas, 2 fixadas",
            children: [SafariAXNode(role: "AXGroup", children: [roleFallbackTab])]
        )
        let descriptionResult = extractSafariAudibleTabs(from: SafariAXNode(role: "AXApplication", children: [descriptionBar]))
        expect(descriptionResult.titles == ["Description fallback"] && descriptionResult.tabCount == 1, "localized bar description and nested radio tabs are a bounded fallback")

        let tabIdentifierMustNotMatchBar = SafariAXNode(role: "AXGroup", identifier: "TabBarTab?isNarrow=false", children: [idBasedTab])
        let falsePositive = extractSafariAudibleTabs(from: SafariAXNode(role: "AXApplication", children: [tabIdentifierMustNotMatchBar]))
        expect(falsePositive.titles.isEmpty && falsePositive.tabBarCount == 0, "a TabBarTab identifier cannot be mistaken for a tab bar")
    }

    private static func testNodeDepthAndIndicatorBounds() {
        var nested = tabBar([tab("Bounded title", button: muteButton("Mute Tab"))])
        for index in 0..<8 {
            nested = SafariAXNode(role: "AXGroup", identifier: "wrapper-\(index)", children: [nested])
        }
        let root = SafariAXNode(role: "AXApplication", children: [nested])
        let nodeLimited = extractSafariAudibleTabs(from: root, maximumNodes: 4, maximumDepth: 12)
        expect(nodeLimited.titles.isEmpty && nodeLimited.wasTruncated, "node budget bounds traversal")
        let depthLimited = extractSafariAudibleTabs(from: root, maximumNodes: 100, maximumDepth: 3)
        expect(depthLimited.titles.isEmpty && depthLimited.wasTruncated, "depth budget bounds traversal")
        let oneIndicatorOverBudget = extractSafariAudibleTabs(
            from: window(tab("Indicator boundary", button: muteButton("Mute Tab"))),
            maximumNodes: 3,
            maximumDepth: 8
        )
        expect(oneIndicatorOverBudget.titles.isEmpty && oneIndicatorOverBudget.wasTruncated, "indicator inspection consumes the node budget")
    }


    private static func testNestedIndicatorsAndChromium() {
        expect(chromiumTabTitle("Uso da memória em Mixer — Aba de teste com áudio: parte do grupo 🔊 Mixer - Reprodução de áudio: 46,5 MB") == "Mixer — Aba de teste com áudio", "real Chrome memory and group decoration is removed")
        expect(chromiumTabTitle("Memory usage for Background video - Audio playing: 42 MB") == "Background video", "English memory decoration is removed")
        expect(chromiumTabTitle("A video about memory usage: 42 MB") == "A video about memory usage: 42 MB", "actual titles without a Chrome wrapper are preserved")
        expect(canonicalBrowserAXRole("AXOpaqueProviderGroup", description: "grupo de abas") == "AXTabGroup", "opaque tab bar role is normalized")
        expect(canonicalBrowserAXRole("AXOpaqueProviderElement", description: "Conteúdo HTML") == "AXWebArea", "opaque page content remains excluded")
        let titleField = SafariAXNode(role: "AXStaticText", identifier: "UnifiedTabBarButton._titleTextField", value: "Wrapped title")
        let wrapped = SafariAXNode(role: "AXGroup", children: [titleField, muteButton("Silenciar aba")])
        let safariTab = SafariAXNode(role: "AXRadioButton", identifier: "TabBarTab", children: [wrapped])
        expect(extractSafariAudibleTabs(from: window(safariTab)).titles == ["Wrapped title"], "wrapped title and audio indicators remain readable")
        let tabs = SafariAXNode(role: "AXTabGroup", children: [
            SafariAXNode(role: "AXRadioButton", title: "Background test", description: "Audio playing"),
            SafariAXNode(role: "AXRadioButton", title: "Silent active", isSelected: true),
            SafariAXNode(role: "AXRadioButton", title: "Muted test", description: "Audio playing, Audio muted"),
            SafariAXNode(role: "AXRadioButton", title: "Vídeo", description: "Reprodução de áudio")
        ])
        let root = SafariAXNode(role: "AXApplication", children: [tabs])
        expect(extractSafariAudibleTabs(from: root, kind: .chromium).titles == ["Background test", "Vídeo"], "Chromium requires audio markers and ignores silent and muted tabs")
        let fake = SafariAXNode(role: "AXWebArea", children: [tabs])
        expect(extractSafariAudibleTabs(from: fake, kind: .chromium).titles.isEmpty, "Chromium page content is excluded")
    }

    private static func window(_ tabs: SafariAXNode...) -> SafariAXNode {
        SafariAXNode(role: "AXApplication", children: [tabBar(tabs)])
    }

    private static func tabBar(_ tabs: [SafariAXNode]) -> SafariAXNode {
        SafariAXNode(role: "AXTabGroup", identifier: "TabBar?isSeparate=false", children: tabs)
    }

    private static func tab(_ title: String?, selected: Bool = false, description: String? = nil, button: SafariAXNode? = nil, extraChild: SafariAXNode? = nil) -> SafariAXNode {
        SafariAXNode(
            role: "AXRadioButton",
            identifier: "TabBarTab?isNarrow=false",
            title: title,
            description: description,
            isSelected: selected,
            children: [extraChild, button].compactMap { $0 }
        )
    }

    private static func muteButton(_ title: String, description: String? = nil) -> SafariAXNode {
        SafariAXNode(role: "AXButton", title: title, description: description)
    }
}
