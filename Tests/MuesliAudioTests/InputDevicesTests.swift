import Foundation
import Testing
@testable import MuesliAudio

@Suite("Input devices")
struct InputDevicesTests {
    @Test("a microphone that isn't connected is reported by name, before asking for access")
    func missingDevice() async throws {
        let capture = MicrophoneCapture(deviceUID: "no-such-microphone")
        await #expect {
            _ = try await capture.start()
        } throws: { error in
            guard case MicrophoneCapture.CaptureError.deviceNotFound("no-such-microphone") = error else { return false }
            return true
        }
    }

    @Test("listed devices have unique UIDs, and Muesli's own tap devices aren't among them")
    func listing() {
        let devices = InputDevices.list()
        #expect(Set(devices.map(\.uid)).count == devices.count)
        #expect(!devices.contains { $0.uid.hasPrefix(SystemAudioCapture.aggregateUIDPrefix) })
        if let fallback = InputDevices.systemDefault() { #expect(devices.contains(fallback)) }
    }
}
