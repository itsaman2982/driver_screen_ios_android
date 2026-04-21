import AVFoundation
import WebRTC
import Flutter

class DualCameraWebRTCManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, RTCPeerConnectionDelegate {
    
    static let shared = DualCameraWebRTCManager()
    
    private var multiCamSession: AVCaptureMultiCamSession?
    
    // Front camera properties
    private var frontDeviceInput: AVCaptureDeviceInput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var frontVideoSource: RTCVideoSource?
    
    // Back camera properties
    private var backDeviceInput: AVCaptureDeviceInput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var backVideoSource: RTCVideoSource?
    
    // WebRTC connection management
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnections: [String: RTCPeerConnection] = [:]
    
    private let videoQueue = DispatchQueue(label: "com.driverscreen.videoQueue", qos: .userInteractive)
    
    var methodChannel: FlutterMethodChannel?
    
    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.peerConnectionFactory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }
    
    func startCameras() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam is not supported on this device")
            return
        }
        
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        
        // Front Camera
        if let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let frontInput = try? AVCaptureDeviceInput(device: frontDevice) {
            
            if session.canAddInput(frontInput) {
                session.addInputWithNoConnections(frontInput)
                self.frontDeviceInput = frontInput
                
                let frontOutput = AVCaptureVideoDataOutput()
                frontOutput.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(frontOutput) {
                    session.addOutputWithNoConnections(frontOutput)
                    self.frontVideoOutput = frontOutput
                    
                    if let port = frontInput.ports.first(where: { $0.mediaType == .video }),
                       let connection = AVCaptureConnection(inputPorts: [port], output: frontOutput) {
                        if session.canAddConnection(connection) {
                            session.addConnection(connection)
                        }
                    }
                }
                
                do {
                    try frontDevice.lockForConfiguration()
                    frontDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 10)
                    frontDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
                    frontDevice.unlockForConfiguration()
                } catch {
                    print("Failed to lock front device for config: \(error)")
                }
            }
        }
        
        // Back Camera (USB/Environment)
        if let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let backInput = try? AVCaptureDeviceInput(device: backDevice) {
            
            if session.canAddInput(backInput) {
                session.addInputWithNoConnections(backInput)
                self.backDeviceInput = backInput
                
                let backOutput = AVCaptureVideoDataOutput()
                backOutput.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(backOutput) {
                    session.addOutputWithNoConnections(backOutput)
                    self.backVideoOutput = backOutput
                    
                    if let port = backInput.ports.first(where: { $0.mediaType == .video }),
                       let connection = AVCaptureConnection(inputPorts: [port], output: backOutput) {
                        if session.canAddConnection(connection) {
                            session.addConnection(connection)
                        }
                    }
                }
                
                do {
                    try backDevice.lockForConfiguration()
                    backDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 10)
                    backDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
                    backDevice.unlockForConfiguration()
                } catch {
                    print("Failed to lock back device for config: \(error)")
                }
            }
        }
        
        session.commitConfiguration()
        session.startRunning()
        self.multiCamSession = session
        
        self.frontVideoSource = peerConnectionFactory.videoSource()
        self.backVideoSource = peerConnectionFactory.videoSource()
    }
    
    func stopCameras() {
        self.multiCamSession?.stopRunning()
        self.multiCamSession = nil
        for pc in peerConnections.values {
            pc.close()
        }
        peerConnections.removeAll()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let timestampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
            
            // Fix orientation: usually 90 for portrait
            let videoFrame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: RTCVideoRotation._90, timeStampNs: timestampNs)
            
            if output == self.frontVideoOutput {
                self.frontVideoSource?.capturer(self, didCapture: videoFrame)
            } else if output == self.backVideoOutput {
                self.backVideoSource?.capturer(self, didCapture: videoFrame)
            }
        }
    }
    
    func createPeerConnection(connectionId: String, type: String, completion: @escaping (RTCSessionDescription?) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        
        // We use a custom delegate wrapper to pass connectionId
        let delegateWrapper = PeerConnectionDelegateWrapper(connectionId: connectionId, manager: self)
        
        guard let peerConnection = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: delegateWrapper) else {
            completion(nil)
            return
        }
        
        // Keep a reference to the wrapper by attaching it to peer connection dynamically or store it
        // Actually, we can just use self as delegate and store a mapping of RTCPeerConnection to connectionId
        peerConnection.delegate = self
        self.peerConnections[connectionId] = peerConnection
        
        let trackId = "\(type)_track_\(connectionId)"
        let streamId = "stream_\(type)_\(connectionId)"
        
        let source = (type == "tablet_front_road") ? frontVideoSource : backVideoSource
        
        if let source = source {
            let track = peerConnectionFactory.videoTrack(with: source, trackId: trackId)
            let initParams = RTCRtpTransceiverInit()
            initParams.direction = .sendOnly
            initParams.streamIds = [streamId]
            
            if let transceiver = peerConnection.addTransceiver(with: track, init: initParams) {
                let parameters = transceiver.sender.parameters
                if let encoding = parameters.encodings.first {
                    encoding.maxBitrateBps = NSNumber(value: 500_000)
                }
                transceiver.sender.parameters = parameters
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let _ = self else { return }
            peerConnection.offer(for: constraints) { (sdp, error) in
                if let sdp = sdp {
                    peerConnection.setLocalDescription(sdp) { error in
                        completion(sdp)
                    }
                } else {
                    completion(nil)
                }
            }
        }
    }
    
    func setRemoteDescription(connectionId: String, sdp: String, type: String) {
        guard let pc = peerConnections[connectionId] else { return }
        let sdpType: RTCSdpType = type == "offer" ? .offer : .answer
        let rtcSdp = RTCSessionDescription(type: sdpType, sdp: sdp)
        pc.setRemoteDescription(rtcSdp, completionHandler: { error in
            if let err = error {
                print("Set remote description error: \(err)")
            }
        })
    }
    
    func addIceCandidate(connectionId: String, candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        guard let pc = peerConnections[connectionId] else { return }
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        pc.add(ice)
    }
    
    // MARK: - RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Find connectionId
        guard let connectionId = peerConnections.first(where: { $0.value == peerConnection })?.key else { return }
        
        DispatchQueue.main.async {
            self.methodChannel?.invokeMethod("onIceCandidate", arguments: [
                "connectionId": connectionId,
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid,
                "sdpMLineIndex": candidate.sdpMLineIndex
            ])
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

class PeerConnectionDelegateWrapper: NSObject, RTCPeerConnectionDelegate {
    let connectionId: String
    weak var manager: DualCameraWebRTCManager?
    init(connectionId: String, manager: DualCameraWebRTCManager) {
        self.connectionId = connectionId
        self.manager = manager
    }
    // Implement requirements by forwarding to manager
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        manager?.peerConnection(peerConnection, didGenerate: candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension DualCameraWebRTCManager: RTCVideoCapturerDelegate {
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {}
}
