import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_logger.dart';
import '../../core/signed_storage_media.dart';
import '../../shared.dart';
import 'live_photo_models.dart';

/// Plays a posted clip from the disk cache, so each device downloads it once
/// (streaming re-downloaded it on every view). The cache is keyed by the
/// stored URL; signing happens inside the cache manager. Streams only if
/// caching fails.
Future<VideoPlayerController> remoteLiveClipController(
  String clipUrl, {
  BaseCacheManager? cacheManager,
}) async {
  try {
    final manager =
        cacheManager ?? sideQuestCacheManagerFor(clipUrl) ?? DefaultCacheManager();
    final file = await manager.getSingleFile(clipUrl);
    return VideoPlayerController.file(file);
  } catch (e) {
    AppLogger.debug('Live clip cache failed, streaming instead: $e');
    return VideoPlayerController.networkUrl(
      Uri.parse(await SignedStorageUrls.resolve(clipUrl)),
    );
  }
}

class LivePhotoFeedMedia extends StatefulWidget {
  final String stillUrl;
  final LivePhotoPostAttachment attachment;
  final String? localStillPath;
  final String? localClipPath;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final Widget? errorWidget;
  final Widget? placeholder;
  final bool preloadVideo;

  const LivePhotoFeedMedia({
    super.key,
    required this.stillUrl,
    required this.attachment,
    this.localStillPath,
    this.localClipPath,
    this.onTap,
    this.width,
    this.height,
    this.borderRadius = BorderRadius.zero,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.low,
    this.errorWidget,
    this.placeholder,
    this.preloadVideo = false,
  });

  @override
  State<LivePhotoFeedMedia> createState() => _LivePhotoFeedMediaState();
}

class _LivePhotoFeedMediaState extends State<LivePhotoFeedMedia> {
  static final ValueNotifier<Object?> _activePlaybackOwner =
      ValueNotifier<Object?>(null);

  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;
  bool _showVideo = false;
  bool _isInitializing = false;
  final Object _playbackOwner = Object();
  Timer? _idleDisposeTimer;
  // User has tapped the sound icon to request audio playback on the next
  // long-press. Stays sticky for this widget instance so a tap on a
  // previously-muted live photo doesn't have to be repeated each replay.
  bool _audioRequested = false;

  @override
  void initState() {
    super.initState();
    _activePlaybackOwner.addListener(_handleActivePlaybackChanged);
    if (widget.preloadVideo && _hasPlayableClip) {
      _ensureVideoController();
    }
  }

  @override
  void didUpdateWidget(covariant LivePhotoFeedMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.clipUrl != widget.attachment.clipUrl ||
        oldWidget.localClipPath != widget.localClipPath ||
        oldWidget.localStillPath != widget.localStillPath) {
      _disposeController();
      if (widget.preloadVideo && _hasPlayableClip) {
        _ensureVideoController();
      }
    }
  }

  bool get _hasPlayableClip =>
      (widget.localClipPath?.trim().isNotEmpty ?? false) ||
      (widget.attachment.isLivePhoto &&
          (widget.attachment.clipUrl?.trim().isNotEmpty ?? false));

  Future<void> _ensureVideoController() {
    if (!_hasPlayableClip) return Future<void>.value();
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    if (_initializeFuture != null) return _initializeFuture!;

    final localClipPath = widget.localClipPath?.trim() ?? '';
    _isInitializing = true;
    _initializeFuture = () async {
          final controller = localClipPath.isNotEmpty
              ? VideoPlayerController.file(File(localClipPath))
              : await remoteLiveClipController(widget.attachment.clipUrl!);
          _controller = controller;
          await controller.initialize();
          return controller;
        }()
        .then((controller) async {
          await controller.setLooping(true);
          // Mute unless the post has audible audio AND the viewer tapped the
          // sound icon. Live Photos default to silent so feed scrolling
          // doesn't burst sound at the user unannounced.
          final shouldPlayAudio =
              _audioRequested && !widget.attachment.liveMuted;
          await controller.setVolume(shouldPlayAudio ? 1.0 : 0.0);
          if (mounted) {
            setState(() {
              _isInitializing = false;
            });
          }
          // Warmed up by a touch that turned into a scroll: free the player
          // again instead of keeping it until the card is disposed.
          if (!_showVideo) _scheduleIdleDispose();
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() {
              _isInitializing = false;
              _showVideo = false;
            });
          }
        });

    return _initializeFuture!;
  }

  Future<void> _playLiveClip() async {
    if (!_hasPlayableClip) return;
    await _ensureVideoController();
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _activePlaybackOwner.value = _playbackOwner;
    await controller.seekTo(Duration.zero);
    await controller.play();
    if (!mounted) return;
    setState(() => _showVideo = true);
  }

  Future<void> _stopLiveClip({bool releaseOwnership = true}) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    await controller.seekTo(Duration.zero);
    if (releaseOwnership && _activePlaybackOwner.value == _playbackOwner) {
      _activePlaybackOwner.value = null;
    }
    if (!mounted) return;
    setState(() => _showVideo = false);
    _scheduleIdleDispose();
  }

  /// Release native video resources after a short idle period to reduce memory
  /// pressure while keeping the controller warm for quick replays.
  void _scheduleIdleDispose() {
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = Timer(const Duration(seconds: 12), () {
      if (!_showVideo) {
        _disposeController();
      }
    });
  }

  void _toggleAudio() {
    final next = !_audioRequested;
    setState(() => _audioRequested = next);
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      controller.setVolume(next && !widget.attachment.liveMuted ? 1.0 : 0.0);
    }
  }

  void _handleActivePlaybackChanged() {
    if (!mounted) return;
    if (_showVideo && _activePlaybackOwner.value != _playbackOwner) {
      unawaited(_stopLiveClip(releaseOwnership: false));
    }
  }

  @override
  void dispose() {
    _activePlaybackOwner.removeListener(_handleActivePlaybackChanged);
    if (_activePlaybackOwner.value == _playbackOwner) {
      _activePlaybackOwner.value = null;
    }
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    final controller = _controller;
    _controller = null;
    _initializeFuture = null;
    _showVideo = false;
    _isInitializing = false;
    controller?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localStillPath = widget.localStillPath?.trim() ?? '';
    // Sync existence check avoids Flutter throwing PathNotFoundException
    // inside Image.file when the local cache file was cleared (e.g. after a
    // re-install or low-storage cache purge on Android). The errorBuilder
    // would still catch it visually, but the throw makes the debugger pause
    // every frame in debug mode.
    final hasLocalFile =
        localStillPath.isNotEmpty && File(localStillPath).existsSync();
    final child = Stack(
      fit: StackFit.expand,
      children: [
        if (hasLocalFile)
          Image.file(
            File(localStillPath),
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            alignment: widget.alignment,
            filterQuality: widget.filterQuality,
            errorBuilder: (context, error, stackTrace) =>
                widget.errorWidget ??
                Container(
                  color: const Color(0xFF171717),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    color: Color(0xFF8A8A8A),
                    size: 24,
                  ),
                ),
          )
        else
          sideQuestNetworkImage(
            imageUrl: widget.stillUrl,
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            cacheWidth: widget.cacheWidth,
            cacheHeight: widget.cacheHeight,
            alignment: widget.alignment,
            filterQuality: widget.filterQuality,
            errorWidget: widget.errorWidget,
            placeholder: widget.placeholder,
          ),
        if (_showVideo &&
            _controller != null &&
            _controller!.value.isInitialized)
          FittedBox(
            fit: widget.fit,
            alignment: widget.alignment,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          ),
        if (_hasPlayableClip)
          Positioned(
            top: 10,
            left: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.52),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Text(
                    _isInitializing ? 'Live...' : 'Live',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.attachment.liveMuted ? null : _toggleAudio,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.52),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Icon(
                      widget.attachment.liveMuted
                          ? Icons.volume_off_rounded
                          : (_audioRequested
                                ? Icons.volume_up_rounded
                                : Icons.volume_mute_rounded),
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: _hasPlayableClip
          ? (_) => unawaited(_ensureVideoController())
          : null,
      // No warm-up on onLongPressDown: it fires on every touch, including
      // the start of each scroll. onTapDown only fires after the finger
      // rests ~100 ms, which still leaves time before the long press.
      onLongPressStart: _hasPlayableClip ? (_) => _playLiveClip() : null,
      onLongPressEnd: _hasPlayableClip ? (_) => _stopLiveClip() : null,
      onLongPressCancel: _hasPlayableClip ? _stopLiveClip : null,
      child: ClipRRect(borderRadius: widget.borderRadius, child: child),
    );
  }
}
