import AppKit
import SwiftUI

/// Opens the app's windows from anywhere: menu items, notification buttons.
///
/// SwiftUI's `openWindow` only works from inside a view, and a menu-bar app's
/// menu isn't alive when a notification is clicked, so windows are AppKit
/// windows hosting SwiftUI views. Each kind is opened once and brought forward
/// after that.
@MainActor
final class WindowManager {
    enum Kind: Hashable {
        case live
        case setup
        case settings
        case review(URL)
    }

    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind, model: AppModel) {
        NSApp.activate()
        if let window = windows[kind] {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let (title, view, size): (String, AnyView, NSSize) = switch kind {
        case .live: ("Live Transcript", AnyView(LiveTranscriptView(model: model)), NSSize(width: 480, height: 660))
        case .setup: ("Check Setup", AnyView(SetupView(model: model)), NSSize(width: 620, height: 560))
        case .settings: ("Muesli Settings", AnyView(SettingsView(model: model, preferences: model.preferences)), NSSize(width: 560, height: 440))
        case .review(let url): ("Review: \(url.lastPathComponent)", AnyView(ReviewView(model: model, url: url)), NSSize(width: 600, height: 640))
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        if kind == .live {
            // Stays visible over the call window.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrameAutosaveName("LiveTranscript")
        } else {
            window.center()
        }
        windows[kind] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[kind] = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }
}
