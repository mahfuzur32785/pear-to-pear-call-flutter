import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

void main() => runApp(const MaterialApp(home: MeetingPage()));

class MeetingPage extends StatefulWidget {
  const MeetingPage({super.key});
  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> {
  late IO.Socket socket;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String? selfId;
  final roomId = 'testroom';

  bool micEnabled = true;
  bool camEnabled = true;
  bool usingFrontCamera = true;
  bool screenSharing = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    await requestPermissions();
    await _initRenderers();
    await _getUserMedia();
    _connectToSocket();
  }

  Future<void> requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
    ].request();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> _getUserMedia() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': true,
        'audio': true,
      });
      print("🎥 Local stream obtained: ${_localStream?.id}");
      _localRenderer.srcObject = _localStream;
      setState(() {});
      print("✅ Local video renderer set.");
    } catch (e) {
      print("⚠️ Error getting user media: $e");
    }
  }

  void _connectToSocket() {
    socket = IO.io(
      'http://192.168.0.40:5000', // Your signaling server IP
      IO.OptionBuilder().setTransports(['websocket']).build(),
    );

    socket.onConnect((_) {
      print("✅ Connected to signaling server");
      socket.emit('join', {'room': roomId});
      selfId = socket.id;
      print("My socket id: $selfId");
    });

    socket.on('user-joined', (data) async {
      String newUserId = data['id'];
      print("👤 User joined: $newUserId");
      if (newUserId != selfId) {
        await _createOffer(newUserId);
      }
    });

    socket.on('signal', (data) async {
      print("📡 Signal data received: $data");

      String? from = data['from'];
      String? type = data['type'];

      if (type == null) {
        print("⚠️ Signal missing type: $data");
        return;
      }

      if (type == 'offer' && from != null && data['sdp'] != null) {
        await _createAnswer(from, data['sdp']);
      } else if (type == 'answer' && from != null && data['sdp'] != null) {
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(data['sdp'], type),
        );
        print("✅ Answer set as remote description");
      } else if (type == 'candidate' && data['candidate'] != null) {
        await _peerConnection?.addCandidate(
          RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']),
        );
        print("✅ ICE candidate added");
      } else {
        print("⚠️ Unknown or incomplete signal data: $data");
      }
    });

    socket.onDisconnect((_) {
      print("❌ Disconnected from signaling server");
      _peerConnection?.close();
      _peerConnection = null;
    });

    socket.onConnectError((error) {
      print("⚠️ Connection error: $error");
    });
  }

  Future<void> _createPeerConnection(String remoteId) async {
    print("🔧 Creating RTCPeerConnection for $remoteId");
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    });

    _peerConnection?.onIceCandidate = (candidate) {
      if (candidate == null) return;
      print("🧊 ICE candidate generated, sending to $remoteId");
      socket.emit('signal', {
        'to': remoteId,
        'from': selfId,
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection?.onTrack = (event) {
      print("📺 Remote track received: ${event.track.kind}");
      _remoteRenderer.srcObject = event.streams.first;
      setState(() {});
    };

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });
      print("🎤 Local tracks added to peer connection");
    } else {
      print("⚠️ Local stream is null, cannot add tracks");
    }
  }

  Future<void> _createOffer(String remoteId) async {
    await _createPeerConnection(remoteId);

    var offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _peerConnection!.setLocalDescription(offer);

    socket.emit('signal', {
      'to': remoteId,
      'from': selfId,
      'type': 'offer',
      'sdp': offer.sdp,
    });
    print("📤 Offer sent to $remoteId");
  }

  Future<void> _createAnswer(String remoteId, String sdp) async {
    await _createPeerConnection(remoteId);

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );

    var answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _peerConnection!.setLocalDescription(answer);

    socket.emit('signal', {
      'to': remoteId,
      'from': selfId,
      'type': 'answer',
      'sdp': answer.sdp,
    });
    print("📤 Answer sent to $remoteId");
  }

  void _toggleMic() {
    if (_localStream == null) return;
    micEnabled = !micEnabled;
    _localStream!.getAudioTracks().forEach((track) {
      track.enabled = micEnabled;
    });
    setState(() {});
  }

  void _toggleVideo() {
    if (_localStream == null) return;
    camEnabled = !camEnabled;
    _localStream!.getVideoTracks().forEach((track) {
      track.enabled = camEnabled;
    });
    setState(() {});
  }

  Future<void> _switchCamera() async {
    if (_localStream == null) return;
    var videoTrack = _localStream!
        .getVideoTracks()
        .firstWhere((track) => track.kind == 'video');
    if (videoTrack == null) return;

    await Helper.switchCamera(videoTrack);
    usingFrontCamera = !usingFrontCamera;
    setState(() {});
  }

  // Add this method inside _MeetingPageState:
  void _endCall() async {
    try {
      await _peerConnection?.close();
      _peerConnection = null;

      await _localStream?.dispose();
      _localStream = null;

      await _localStream?.dispose();
      _localStream = null;

      Platform.isIOS
          ? socket.dispose()
          : socket.disconnect();

      setState(() {
        micEnabled = false;
        camEnabled = false;
        screenSharing = false;
        isRenderVideoChanged = false;
        selfId = null;
      });
    } catch (e) {
      print("⚠️ Error ending call: $e");
    }
  }

  Future<void> _disposeStream(MediaStream? stream) async {
    if (stream == null) return;
    try {
      await stream.dispose();
    } catch (_) {}
  }

  Future<void> _toggleScreenShare() async {
    if (_peerConnection == null) return;

    if (screenSharing) {
      // Revert to camera
      await _disposeStream(_localStream);
      _localStream = null;

      await _getUserMedia();

      var senders = await _peerConnection!.getSenders();
      var sender = senders.firstWhere(
            (s) => s.track?.kind == 'video',
        // orElse: () => null,
      );

      if (sender == null) {
        print("No video sender found on revert");
        return;
      }

      var videoTrack = _localStream!.getVideoTracks().first;
      await sender.replaceTrack(videoTrack);

      _localRenderer.srcObject = _localStream;
      screenSharing = false;
      setState(() {});

    } else {
      try {
        print("Requesting screen capture...");
        final screenStream = await navigator.mediaDevices.getDisplayMedia({
          'video': true,
          'audio': false,
        });
        print("Screen capture stream obtained");

        await _disposeStream(_localStream);
        _localStream = screenStream;

        var senders = await _peerConnection!.getSenders();
        var sender = senders.firstWhere(
              (s) => s.track?.kind == 'video',
          // orElse: () => null,
        );

        if (sender == null) {
          print("No video sender found for screen share");
          return;
        }

        var screenVideoTrack = _localStream!.getVideoTracks().first;
        await sender.replaceTrack(screenVideoTrack);

        _localRenderer.srcObject = _localStream;
        screenSharing = true;
        setState(() {});

      } catch (e, st) {
        print("⚠️ Screen share error: $e");
        print(st);
      }
    }
  }


  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    socket.disconnect();
    _peerConnection?.close();
    super.dispose();
  }

  double localPreviewX = 20;
  double localPreviewY = 20;

  final double previewWidth = 120;
  final double previewHeight = 150;

  bool isRenderVideoChanged = false;

  @override
  Widget build(BuildContext context) {

    final screenSize = MediaQuery.of(context).size;
    // Calculate max allowed positions so the preview stays fully visible
    final maxX = screenSize.width - previewWidth - 15;
    final maxY = screenSize.height - previewHeight - 160; // minus app bar height


    return Scaffold(
      appBar: AppBar(title: const Text("Flutter WebRTC Meeting")),
      body: Container(
        color: Colors.grey,
        child: Column(
          children: [
            Expanded(
              child: Stack(children: [
                RTCVideoView(
                  isRenderVideoChanged ? _localRenderer : _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
                Positioned(
                  left: localPreviewX.clamp(15, maxX),
                  top: localPreviewY.clamp(15, maxY),
                  child: GestureDetector(
                    onTap: () {
                      print('object');
                      isRenderVideoChanged = !isRenderVideoChanged;
                      setState(() {

                      });
                    },
                    onPanUpdate: (details) {
                      setState(() {
                        localPreviewX += details.delta.dx;
                        localPreviewY += details.delta.dy;

                        // Clamp inside the visible screen area
                        localPreviewX = localPreviewX.clamp(0, maxX);
                        localPreviewY = localPreviewY.clamp(0, maxY);
                      });
                    },
                    child: SizedBox(
                      width: previewWidth,
                      height: previewHeight,
                      child: RTCVideoView(
                        isRenderVideoChanged ? _remoteRenderer : _localRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: Icon(
                      micEnabled ? Icons.mic : Icons.mic_off,
                      color: Colors.white,
                    ),
                    onPressed: _toggleMic,
                  ),
                  IconButton(
                    icon: Icon(
                      camEnabled ? Icons.videocam : Icons.videocam_off,
                      color: Colors.white,
                    ),
                    onPressed: _toggleVideo,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.switch_camera,
                      color: Colors.white,
                    ),
                    onPressed: _switchCamera,
                  ),
                  IconButton(
                    icon: Icon(
                      screenSharing ? Icons.stop_screen_share : Icons.screen_share,
                      color: Colors.white,
                    ),
                    onPressed: () async {
                      try {
                        final screenStream = await navigator.mediaDevices.getDisplayMedia({
                          'video': false,
                          'audio': false,
                        });
                        print("Screen capture started: ${screenStream.getTracks().length} tracks");

                        // Dispose stream after 5 seconds for test
                        // await Future.delayed(Duration(seconds: 5));
                        // await screenStream.dispose();
                        print("Screen share stopped");
                      } catch (e) {
                        print("Screen share error: $e");
                      }
                    },

                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onPressed: _endCall,
                    child: Text("End Call", style: TextStyle(
                      color: Colors.white
                    ),),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
