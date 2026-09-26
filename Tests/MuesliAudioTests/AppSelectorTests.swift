import CoreAudio
import Foundation
import Testing
@testable import MuesliAudio

private func proc(_ name: String, bundle: String? = nil, pid: pid_t = 1000, id: AudioObjectID = 1) -> AudioProcess {
    AudioProcess(objectID: id, pid: pid, bundleID: bundle, name: name, isProducingAudio: true)
}

@Suite("AppSelector")
struct AppSelectorTests {
    @Test("parses comma-separated names and trims them")
    func parsing() {
        #expect(AppSelector(commaSeparated: " zoom , Google Chrome,, ").terms == ["zoom", "Google Chrome"])
        #expect(AppSelector(commaSeparated: " , ").isEmpty)
        #expect(AppSelector([]).isEmpty)
    }

    @Test("matches by exact name or bundle id, ignoring case")
    func exact() {
        let s = AppSelector(["zoom.us", "com.apple.FaceTime"])
        #expect(s.matches(name: "zoom.us", bundleID: "us.zoom.xos"))
        #expect(s.matches(name: "ZOOM.US", bundleID: nil))
        #expect(s.matches(name: "FaceTime", bundleID: "com.apple.facetime"))
        #expect(!s.matches(name: "Music", bundleID: "com.apple.Music"))
    }

    @Test("a bundle id also covers its helpers, but not lookalikes")
    func helpers() {
        let s = AppSelector(["com.google.Chrome"])
        #expect(s.matches(name: "Google Chrome Helper", bundleID: "com.google.Chrome.helper"))
        #expect(s.matches(name: "Google Chrome Helper (Renderer)", bundleID: "com.google.Chrome.helper.Renderer"))
        #expect(!s.matches(name: "Chromecast", bundleID: "com.google.Chromecast"))
    }

    @Test("partial names work for long enough terms, so 'chrome' finds every Chrome process")
    func substring() {
        let s = AppSelector(["chrome"])
        #expect(s.matches(name: "Google Chrome", bundleID: nil))
        #expect(s.matches(name: "Google Chrome Helper", bundleID: nil))
        #expect(!s.matches(name: "Firefox", bundleID: nil))
    }

    @Test("very short terms only match exactly, so a typo can't capture half the system")
    func shortTerms() {
        let s = AppSelector(["ch"])
        #expect(!s.matches(name: "Google Chrome", bundleID: nil))
        #expect(!s.matches(name: "Mail Graphics and Media", bundleID: nil))
        #expect(s.matches(name: "ch", bundleID: nil))
    }

    @Test("a WebKit process is matched through the app it works for")
    func webKit() {
        // Safari's audio comes from a per-app WebKit process named after the app.
        let s = AppSelector(["safari"])
        #expect(s.matches(name: "Safari Graphics and Media", bundleID: "com.apple.WebKit.GPU"))
        #expect(!s.matches(name: "Mail Graphics and Media", bundleID: "com.apple.WebKit.GPU"))
    }

    @Test("resolve picks direct matches and leaves the rest")
    func resolveDirect() {
        let processes = [
            proc("Zoom", bundle: "us.zoom.xos", pid: 900_001, id: 1),
            proc("Spotify", bundle: "com.spotify.client", pid: 900_002, id: 2),
            proc("Spotify Helper", bundle: "com.spotify.client.helper", pid: 900_003, id: 3),
        ]
        let picked = AppSelector(["us.zoom.xos"]).resolve(in: processes)
        #expect(picked.map(\.objectID) == [1])
        let spotify = AppSelector(["com.spotify.client"]).resolve(in: processes)
        #expect(spotify.map(\.objectID) == [2, 3])
        #expect(AppSelector([]).resolve(in: processes).isEmpty)
    }

    @Test("a helper with an unrelated name is found through its parent process")
    func resolveByParent() throws {
        // A real child of this process, so the parent lookup is exercised for real.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        let me = getpid()
        let processes = [
            proc("muesli-test-host-xyz", bundle: nil, pid: me, id: 10),
            proc("audio-helper-unrelated", bundle: "org.example.unrelated", pid: child.processIdentifier, id: 11),
            proc("bystander", bundle: nil, pid: 1, id: 12), // launchd: not a descendant
        ]
        let picked = AppSelector(["muesli-test-host-xyz"]).resolve(in: processes)
        #expect(picked.map(\.objectID).sorted() == [10, 11])
    }

    @Test("the process list never includes this process")
    func excludesSelf() {
        #expect(!AudioProcesses.list().contains { $0.pid == getpid() })
    }

    @Test("helpers are summarized under their app")
    func summary() {
        let names = SystemAudioCapture.summarize([
            proc("Google Chrome Helper", id: 1), proc("Google Chrome Helper", id: 2), proc("Google Chrome Helper", id: 3),
            proc("Zoom", id: 4),
        ])
        #expect(names == ["Google Chrome Helper (3 processes)", "Zoom"])
    }
}
