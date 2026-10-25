import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../shared.dart';
import 'live_photo_models.dart';
import 'live_photo_feature_flag.dart';
import 'live_photo_preview.dart';
import 'live_photo_repository.dart';

class LivePhotoCaptureScreen extends StatefulWidget {
  final LivePhotoRepository repository;
  final LivePhotoSessionConfig config;

  const LivePhotoCaptureScreen({
    super.key,
    required this.repository,
    this.config = const LivePhotoSessionConfig(),
  });

  @override
  State<LivePhotoCaptureScreen> createState() => _LivePhotoCaptureScreenState();
}

class _LivePhotoCaptureScreenState extends State<LivePhotoCaptureScreen> {
  LivePhotoSessionHandle? _session;
  StreamSubscription<LivePhotoSessionEvent>? _eventSubscription;
  LivePhotoSessionState _state = LivePhotoSessionState.initializing;
  String? _statusMessage;
  bool _requestInFlight = false;

  static const _flashCycle = <String>['off', 'auto', 'on'];
  String _flashMode = 'off';
  late LivePhotoSessionConfig _activeConfig;
  bool _switchingCamera = false;

  @override
  void initState() {
    super.initState();
    _activeConfig = widget.config;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!sideQuestLivePhotoCaptureEnabled) {
      if (!mounted) return;
      setState(() {
        _state = LivePhotoSessionState.error;
        _statusMessage = t(
          'Live Photo ist in diesem Build deaktiviert.',
          'Live photo capture is currently disabled for this build.',
        );
      });
      return;
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      if (!mounted) return;
      setState(() {
        _state = LivePhotoSessionState.error;
        _statusMessage = t(
          'Live Photos sind auf dieser Plattform nicht verfügbar.',
          'Live photos are not available on this platform.',
        );
      });
      return;
    }

    try {
      final granted = await widget.repository.ensurePermissions();
      if (!granted) {
        throw const LivePhotoPlatformException(
          code: LivePhotoErrorCode.permissionDenied,
          message: 'Camera permission is required for live photo capture.',
        );
      }

      final handle = await widget.repository.initializeSession(
        config: _activeConfig,
      );
      _eventSubscription = widget.repository
          .sessionEvents(handle.sessionId)
          .listen(_handleSessionEvent);
      await widget.repository.startSession(handle.sessionId);
      // Re-apply current flash mode to the new session — switching camera
      // creates a fresh native session that defaults to flash off.
      if (_flashMode != 'off') {
        unawaited(
          widget.repository.setFlashMode(handle.sessionId, _flashMode),
        );
      }
      if (!mounted) return;
      setState(() {
        _session = handle;
        _state = LivePhotoSessionState.ready;
        _statusMessage = t(
          'Live-Vorschau wird vorbereitet.',
          'Buffering pre-capture video.',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = LivePhotoSessionState.error;
        _statusMessage = error.toString();
      });
    }
  }

  void _handleSessionEvent(LivePhotoSessionEvent event) {
    if (!mounted) return;
    setState(() {
      _state = event.state;
      _statusMessage = event.message ?? _statusMessage;
    });
  }

  Future<void> _capture() async {
    final sessionId = _session?.sessionId;
    if (sessionId == null || _requestInFlight) return;

    setState(() {
      _requestInFlight = true;
      _state = LivePhotoSessionState.capturing;
      _statusMessage = t(
        'Live Photo wird aufgenommen…',
        'Capturing live photo...',
      );
    });

    try {
      final result = await widget.repository.capture(sessionId);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _requestInFlight = false;
        _state = LivePhotoSessionState.error;
        _statusMessage = error.toString();
      });
    }
  }

  Future<void> _cycleFlash() async {
    final sessionId = _session?.sessionId;
    if (sessionId == null || _requestInFlight) return;
    final nextIdx = (_flashCycle.indexOf(_flashMode) + 1) % _flashCycle.length;
    final next = _flashCycle[nextIdx];
    setState(() => _flashMode = next);
    try {
      await widget.repository.setFlashMode(sessionId, next);
    } catch (_) {
      // Best-effort: native rejection just means the toggle won't apply, the
      // UI state is harmless on its own.
    }
  }

  Future<void> _switchCamera() async {
    if (_switchingCamera || _requestInFlight) return;
    setState(() {
      _switchingCamera = true;
      _activeConfig = LivePhotoSessionConfig(
        lensFacing: _activeConfig.lensFacing == 'front' ? 'back' : 'front',
        preCaptureDurationMs: _activeConfig.preCaptureDurationMs,
        targetClipDurationMs: _activeConfig.targetClipDurationMs,
        sessionTimeoutMs: _activeConfig.sessionTimeoutMs,
        preferredQuality: _activeConfig.preferredQuality,
        muteVideo: _activeConfig.muteVideo,
        preferZeroShutterLag: _activeConfig.preferZeroShutterLag,
      );
    });
    // Tear down the current session, then re-run the same init path so the
    // preview view picks up the new sessionId via setState below.
    final oldSessionId = _session?.sessionId;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    if (oldSessionId != null) {
      unawaited(widget.repository.stopSession(oldSessionId));
      unawaited(widget.repository.disposeSession(oldSessionId));
    }
    if (mounted) {
      setState(() {
        _session = null;
        _state = LivePhotoSessionState.initializing;
      });
    }
    await _initialize();
    if (mounted) setState(() => _switchingCamera = false);
  }

  @override
  void dispose() {
    final sessionId = _session?.sessionId;
    if (sessionId != null) {
      unawaited(widget.repository.stopSession(sessionId));
      unawaited(widget.repository.disposeSession(sessionId));
    }
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canCapture =
        !_requestInFlight &&
        _session != null &&
        (_state == LivePhotoSessionState.ready ||
            _state == LivePhotoSessionState.buffering);

    return Scaffold(
      backgroundColor: const Color(0xFF07090D),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _requestInFlight
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'SideQuest',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t('Blitz', 'Flash'),
                    onPressed: (_session != null && !_requestInFlight)
                        ? _cycleFlash
                        : null,
                    icon: Icon(
                      _flashMode == 'on'
                          ? Icons.flash_on
                          : _flashMode == 'auto'
                          ? Icons.flash_auto
                          : Icons.flash_off,
                      color: _flashMode == 'off'
                          ? Colors.white70
                          : const Color(0xFFFFD54F),
                    ),
                  ),
                  IconButton(
                    tooltip: t('Kamera wechseln', 'Switch camera'),
                    onPressed:
                        (_session != null &&
                            !_requestInFlight &&
                            !_switchingCamera)
                        ? _switchCamera
                        : null,
                    icon: const Icon(
                      Icons.cameraswitch_outlined,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111418),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_session == null)
                        const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        )
                      else
                        LivePhotoPreview(sessionId: _session!.sessionId),
                      if (_requestInFlight)
                        Container(
                          color: Colors.black.withValues(alpha: 0.42),
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 42,
                                height: 42,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                t(
                                  'Dein Live Photo wird erstellt…',
                                  'Creating your live photo...',
                                ),
                                style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                t(
                                  'Halte gedrückt um in Vorschau und Feed abzuspielen.',
                                  'Hold to replay in preview and feed.',
                                ),
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                children: [
                  Text(
                    _statusMessage ??
                        t(
                          'Live Photo Kamera wird vorbereitet…',
                          'Preparing live photo camera...',
                        ),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: canCapture ? _capture : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      icon: _requestInFlight
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.camera_alt_rounded),
                      label: Text(
                        _requestInFlight
                            ? t('Verarbeite…', 'Processing...')
                            : t('Foto aufnehmen', 'Take photo'),
                        style: GoogleFonts.inter(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    t(
                      'Foto und Live-Moment werden automatisch zusammen aufgenommen.',
                      'A still photo and its live moment are captured together automatically.',
                    ),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.35,
                    ),
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
