// Shared NSXPC interfaces used by Baton and its privileged capture helper.

import Foundation

let batonMicrophoneMachService = "com.baton.miccapture"

@objc protocol RemoteMicrophoneCaptureClientProtocol {
    func receiveOpusPacket(_ packet: Data, sequence: UInt16)
    func remoteMicrophoneButtonStateDidChange(_ pressed: Bool)
    func microphoneActivationWriteDidComplete()
    func captureDiagnostic(_ message: String)
    func captureDidStop(_ error: String?)
}

@objc protocol RemoteMicrophoneCaptureServiceProtocol {
    func startCapture(reply: @escaping (Bool, String?) -> Void)
    func stopCapture(reply: @escaping () -> Void)
    func ping(reply: @escaping (String) -> Void)
}
