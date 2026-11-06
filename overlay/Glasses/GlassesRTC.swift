// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import UIKit
import CoreVideo
import WebRTC

/// Video only. No microphone, camera, or device identifiers are sent.
@MainActor final class GlassesRTC: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    var onCandidate: (([String: Any]) -> Void)?
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var candidates: [RTCIceCandidate] = []
    private var answered = false
    private(set) var closed = false

    func offer() async throws -> String {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw failure("Unable to create video connection")
        }
        peer = pc
        let src = Self.factory.videoSource()
        source = src
        capturer = RTCVideoCapturer(delegate: src)
        let track = Self.factory.videoTrack(with: src, trackId: "iphone-screen")
        pc.add(track, streamIds: ["iphone"])
        guard let dc = pc.dataChannel(forLabel: "input", configuration: RTCDataChannelConfiguration()) else {
            throw failure("Unable to create control channel")
        }
        channel = dc
        dc.delegate = self
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? self.failure("Video offer failed")) }
            }
        }
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return description.sdp
    }

    func answer(_ sdp: String) async throws {
        guard let peer, !closed, !answered else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        guard !closed else { return }
        answered = true
        for candidate in candidates { peer.add(candidate) { _ in } }
        candidates.removeAll()
    }

    func candidate(_ object: [String: Any]) {
        guard !closed, let candidate = object["candidate"] as? String, candidate.count <= 4096,
              let index = object["sdpMLineIndex"] as? Int, (0...8).contains(index) else { return }
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(index), sdpMid: object["sdpMid"] as? String)
        if answered { peer?.add(ice) { _ in } }
        else if candidates.count < 64 { candidates.append(ice) }
    }

    func send(_ object: [String: Any]) {
        guard !closed, channel?.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        _ = channel?.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// Screenshot decode and resize run on the same serial queue as device calls.
    nonisolated static func pixelBuffer(_ bytes: Data) -> CVPixelBuffer? {
        guard let image = UIImage(data: bytes)?.cgImage else { return nil }
        let scale = min(1, 960 / Double(max(image.width, image.height)))
        let width = max(2, Int(Double(image.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(image.height) * scale) / 2 * 2)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    func frame(_ buffer: CVPixelBuffer) {
        guard !closed, let source, let capturer else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 4)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                  timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
        source.capturer(capturer, didCapture: frame)
        send(["type": "screen", "width": width, "height": height,
              "region": ["x": 0, "y": 0, "width": 1, "height": 1], "app": "iPhone"])
    }

    func close() {
        guard !closed else { return }
        closed = true
        channel?.delegate = nil
        channel?.close()
        peer?.delegate = nil
        peer?.close()
        channel = nil; peer = nil; capturer = nil; source = nil
        candidates.removeAll()
    }
    nonisolated private func failure(_ message: String) -> NSError {
        NSError(domain: "GlassesRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension GlassesRTC: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onFailure?("Video connection failed") }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.onCandidate?(["type": "iceCandidate", "candidate": candidate.sdp,
                               "sdpMid": candidate.sdpMid ?? "0", "sdpMLineIndex": Int(candidate.sdpMLineIndex)])
        }
    }
}
extension GlassesRTC: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            if dataChannel.readyState == .open { self.onOpen?() }
            if dataChannel.readyState == .closed { self.onFailure?("Glasses disconnected") }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 8192 else { return }
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onMessage?(buffer.data) }
    }
}
