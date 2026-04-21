import AVFoundation
import WebRTC
import Flutter

class DualCameraWebRTCManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
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
        
        // 1. Hardware Setup (AVCaptureMultiCamSession)
        // CRITICAL: Do not force custom activeFormat resolutions, let system pick default formats
        
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
                
                // CRITICAL: Lock configuration and set explicitly to 10 FPS
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
        
        // Back Camera
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
                
                // CRITICAL: Lock configuration and set explicitly to 10 FPS
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
        
        // Initialize WebRTC sources
        self.frontVideoSource = peerConnectionFactory.videoSource()
        self.backVideoSource = peerConnectionFactory.videoSource()
    }
    
    // 2. Frame Capture & Memory Management
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // CRITICAL: Wrap the entire frame processing logic inside an autoreleasepool { ... }
        // Prevents filling up RAM after ~2 mins and crashing
        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
            // Convert CMSampleBuffer to RTCCVPixelBuffer
            let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            
            // CRITICAL: Generate timestamps using the monotonic system clock
            let timestampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
            
            // You may need to handle rotation properly based on device orientation
            let videoFrame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: RTCVideoRotation._90, timeStampNs: timestampNs)
            
            // Pass frame to respective WebRTC source
            if output == self.frontVideoOutput {
                self.frontVideoSource?.capturer(self, didCapture: videoFrame)
            } else if output == self.backVideoOutput {
                self.backVideoSource?.capturer(self, didCapture: videoFrame)
            }
        }
    }
    
    // 3. WebRTC Stream Routing & Transceivers
    func createPeerConnection(connectionId: String, configuration: RTCConfiguration, delegate: RTCPeerConnectionDelegate, completion: @escaping (RTCSessionDescription?) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = peerConnectionFactory.peerConnection(with: configuration, constraints: constraints, delegate: delegate) else {
            completion(nil)
            return
        }
        
        self.peerConnections[connectionId] = peerConnection
        
        // CRITICAL: Unique Track IDs and Stream IDs
        let frontTrackId = "front_track_\(connectionId)"
        let frontStreamId = "stream_front_\(connectionId)"
        if let source = frontVideoSource {
            let frontTrack = peerConnectionFactory.videoTrack(with: source, trackId: frontTrackId)
            let initParams = RTCRtpTransceiverInit()
            initParams.direction = .sendOnly
            initParams.streamIds = [frontStreamId]
            
            if let transceiver = peerConnection.addTransceiver(with: frontTrack, init: initParams) {
                // 4. Bitrate Capping
                let parameters = transceiver.sender.parameters
                if let encoding = parameters.encodings.first {
                    encoding.maxBitrateBps = NSNumber(value: 500_000) // 500 kbps
                }
                transceiver.sender.parameters = parameters
            }
        }
        
        let backTrackId = "back_track_\(connectionId)"
        let backStreamId = "stream_back_\(connectionId)"
        if let source = backVideoSource {
            let backTrack = peerConnectionFactory.videoTrack(with: source, trackId: backTrackId)
            let initParams = RTCRtpTransceiverInit()
            initParams.direction = .sendOnly
            initParams.streamIds = [backStreamId]
            
            if let transceiver = peerConnection.addTransceiver(with: backTrack, init: initParams) {
                // 4. Bitrate Capping
                let parameters = transceiver.sender.parameters
                if let encoding = parameters.encodings.first {
                    encoding.maxBitrateBps = NSNumber(value: 500_000) // 500 kbps
                }
                transceiver.sender.parameters = parameters
            }
        }
        
        // 5. Signaling Race Conditions (The "Jugaad" Delay)
        // CRITICAL: Wrap offer generation in asyncAfter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let _ = self else { return } // ensures self hasn't been deallocated
            
            peerConnection.offer(for: constraints) { (sdp, error) in
                // CRITICAL: Safely unwrap sdp to prevent fatal Runtime crashes
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
}

// Ensure RTCVideoCapturer implementation to suppress warnings if needed
extension DualCameraWebRTCManager: RTCVideoCapturerDelegate {
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        // Implementation provided natively by passing 'self'
    }
}
