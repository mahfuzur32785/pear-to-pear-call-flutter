import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class GroupMeetingPage extends StatefulWidget {
  const GroupMeetingPage({super.key});
  @override
  State<GroupMeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<GroupMeetingPage> {
  late IO.Socket socket;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {}; // remote users' renderers
  final Map<String, RTCPeerConnection> _peerConnections = {}; // peer connections per user
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
    await _localRenderer.initialize();
    await _getUserMedia();
    _connectToSocket();
  }

  Future<void> requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
    ].request();
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
      'http://192.168.0.40:5000',
      IO.OptionBuilder().setTransports(['websocket']).build(),
    );

    socket.onConnect((_) {
      print("✅ Connected to signaling server");
      socket.emit('join', {'room': roomId});
      selfId = socket.id;
      print("My socket id: $selfId");
    });

    // When joining, get list of existing users in the room
    socket.on('existing-users', (data) async {
      List<dynamic> users = data['users'];
      print("👥 Existing users in room: $users");
      for (var userId in users) {
        if (userId != selfId) {
          await _createOffer(userId);
        }
      }
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

      if (type == null || from == null) {
        print("⚠️ Signal missing type or from: $data");
        return;
      }

      final pc = _peerConnections[from];
      if (pc == null) {
        print("⚠️ PeerConnection for $from not found.");
        return;
      }

      if (type == 'offer' && data['sdp'] != null) {
        print("📨 Received offer from $from");
        await _createAnswer(from, data['sdp']);
      }
      else if (type == 'answer' && data['sdp'] != null) {
        // Avoid setting remote description if already set
        var state = await pc.getSignalingState();
        if (state == RTCSignalingState.RTCSignalingStateStable || state == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await pc.setRemoteDescription(
            RTCSessionDescription(data['sdp'], type),
          );
          print("✅ Answer set as remote description for $from");
        } else {
          print("⚠️ Skipped setting remote description (current signaling state: $state)");
        }
      }
      else if (type == 'candidate' && data['candidate'] != null) {
        try {
          // Add candidate only if remote description is set
          await pc.addCandidate(
            RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']),
          );
          print("✅ ICE candidate added for $from");
        } catch (e) {
          print("❌ Error adding ICE candidate for $from: $e");
        }
      }
      else {
        print("⚠️ Unknown or incomplete signal data: $data");
      }
    });

    socket.on('user-left', (data) {
      String userId = data['id'];
      print("👋 User left: $userId");
      _closeConnection(userId);
    });

    socket.onDisconnect((_) {
      print("❌ Disconnected from signaling server");
      _closeAllConnections();
    });

    socket.onConnectError((error) {
      print("⚠️ Connection error: $error");
    });
  }

  Future<RTCPeerConnection> _createPeerConnection(String remoteId) async {
    print("🔧 Creating RTCPeerConnection for $remoteId");
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    };

    RTCPeerConnection pc = await createPeerConnection(config);

    pc.onIceCandidate = (candidate) {
      if (candidate == null) return;
      print("🧊 ICE candidate generated for $remoteId");
      socket.emit('signal', {
        'to': remoteId,
        'from': selfId,
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) {
      print("📺 Remote track received from $remoteId, kind: ${event.track.kind}");
      if (!_remoteRenderers.containsKey(remoteId)) {
        final renderer = RTCVideoRenderer();
        renderer.initialize().then((_) {
          setState(() {
            _remoteRenderers[remoteId] = renderer;
            renderer.srcObject = event.streams.first;
          });
        });
      } else {
        _remoteRenderers[remoteId]?.srcObject = event.streams.first;
        setState(() {});
      }
    };

    // Add local stream tracks to peer connection
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
      print("🎤 Local tracks added to peer connection $remoteId");
    } else {
      print("⚠️ Local stream is null, cannot add tracks");
    }

    _peerConnections[remoteId] = pc;
    return pc;
  }

  Future<void> _createOffer(String remoteId) async {
    RTCPeerConnection pc = await _createPeerConnection(remoteId);
    RTCSessionDescription offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(offer);

    socket.emit('signal', {
      'to': remoteId,
      'from': selfId,
      'type': 'offer',
      'sdp': offer.sdp,
    });
    print("📤 Offer sent to $remoteId");
  }

  Future<void> _createAnswer(String remoteId, String sdp) async {
    RTCPeerConnection pc = await _createPeerConnection(remoteId);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    RTCSessionDescription answer = await pc.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(answer);

    socket.emit('signal', {
      'to': remoteId,
      'from': selfId,
      'type': 'answer',
      'sdp': answer.sdp,
    });
    print("📤 Answer sent to $remoteId");
  }

  void _closeConnection(String remoteId) {
    print("Closing connection with $remoteId");
    _peerConnections[remoteId]?.close();
    _peerConnections.remove(remoteId);

    _remoteRenderers[remoteId]?.dispose();
    _remoteRenderers.remove(remoteId);

    setState(() {});
  }

  void _closeAllConnections() {
    print("Closing all connections");
    for (var pc in _peerConnections.values) {
      pc.close();
    }
    _peerConnections.clear();

    for (var renderer in _remoteRenderers.values) {
      renderer.dispose();
    }
    _remoteRenderers.clear();

    setState(() {});
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
    var videoTrack = _localStream!.getVideoTracks().firstWhere((track) => track.kind == 'video');
    await Helper.switchCamera(videoTrack);
    usingFrontCamera = !usingFrontCamera;
    setState(() {});
  }

  void _endCall() async {
    try {
      await _localStream?.dispose();
      _localStream = null;

      _closeAllConnections();

      Platform.isIOS ? socket.dispose() : socket.disconnect();

      setState(() {
        micEnabled = false;
        camEnabled = false;
        screenSharing = false;
        selfId = null;
      });
    } catch (e) {
      print("⚠️ Error ending call: $e");
    }
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _closeAllConnections();
    Platform.isIOS ? socket.dispose() : socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Flutter WebRTC Group Call")),
      body: Container(
        color: Colors.grey,
        child: Column(
          children: [
            // Local video preview
            SizedBox(
              height: 150,
              child: RTCVideoView(_localRenderer, mirror: usingFrontCamera),
            ),
            const SizedBox(height: 8),

            // Remote videos grid
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, // adjust for more columns if needed
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _remoteRenderers.length,
                itemBuilder: (context, index) {
                  String userId = _remoteRenderers.keys.elementAt(index);
                  RTCVideoRenderer renderer = _remoteRenderers[userId]!;
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      border: Border.all(color: Colors.blueAccent),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  );
                },
              ),
            ),

            // Controls
            Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: Icon(micEnabled ? Icons.mic : Icons.mic_off, color: Colors.white),
                    onPressed: _toggleMic,
                  ),
                  IconButton(
                    icon: Icon(camEnabled ? Icons.videocam : Icons.videocam_off, color: Colors.white),
                    onPressed: _toggleVideo,
                  ),
                  IconButton(
                    icon: Icon(Icons.switch_camera, color: Colors.white),
                    onPressed: _switchCamera,
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onPressed: _endCall,
                    child: const Text("End Call", style: TextStyle(color: Colors.white)),
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
