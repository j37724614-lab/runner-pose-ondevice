import 'dart:async';

import 'package:flutter/services.dart';
import 'package:runner_pose/src/runner_analysis_messages.g.dart';

enum LocalAnalysisStage {
  validating,
  prescan,
  tracking,
  pose2d,
  pose3d,
  speed,
  gait,
  export,
  sync,
  completed,
  failed,
}

enum LocalAnalysisEventStatus { started, progress, completed, skipped, failed }

enum LocalAnalysisSpeedMode { auto, pixel, homography }

class LocalAnalysisPoint {
  const LocalAnalysisPoint(this.x, this.y);

  final double x;
  final double y;
}

class LocalAnalysisCalibration {
  const LocalAnalysisCalibration({
    this.startLine,
    this.endLine,
    this.distanceM,
    this.homographyImagePoints,
    this.homographyWorldPointsM,
    this.roiX,
    this.roiY,
    this.imagePointsNormalized = false,
  });

  final List<LocalAnalysisPoint>? startLine;
  final List<LocalAnalysisPoint>? endLine;
  final double? distanceM;
  final List<LocalAnalysisPoint>? homographyImagePoints;
  final List<LocalAnalysisPoint>? homographyWorldPointsM;
  final List<double>? roiX;
  final List<double>? roiY;

  /// True when image points and ROI are 0...1 fractions of the video frame.
  /// The native side scales them by the oriented dimensions it reads from the
  /// file, so callers do not need to know the video size.
  final bool imagePointsNormalized;
}

class LocalAnalysisKinematicsPolicy {
  const LocalAnalysisKinematicsPolicy({
    this.speedMode = LocalAnalysisSpeedMode.auto,
    this.butterworthCutoffHz = 3.5,
    this.flatInterpolationEpsilonM = 0.001,
    this.laneWidthM = 1.22,
  });

  final LocalAnalysisSpeedMode speedMode;
  final double butterworthCutoffHz;
  final double flatInterpolationEpsilonM;
  final double laneWidthM;
}

class LocalAnalysisVideo {
  const LocalAnalysisVideo({
    required this.cameraIndex,
    required this.path,
    required this.fps,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    this.calibration,
  });

  final int cameraIndex;
  final String path;
  final double fps;
  final int width;
  final int height;
  final int rotationDegrees;
  final LocalAnalysisCalibration? calibration;
}

class LocalAnalysisRequest {
  const LocalAnalysisRequest({
    this.schemaVersion = '1.0.0',
    required this.requestId,
    this.analysisKind = 'running',
    this.comparisonGroupId,
    this.includeOverlays = false,
    this.kinematicsPolicy = const LocalAnalysisKinematicsPolicy(),
    required this.outputDirectoryPath,
    required this.videos,
  });

  final String schemaVersion;
  final String requestId;
  final String analysisKind;
  final String? comparisonGroupId;
  final bool includeOverlays;
  final LocalAnalysisKinematicsPolicy kinematicsPolicy;
  final String outputDirectoryPath;
  final List<LocalAnalysisVideo> videos;
}

class LocalAnalysisFailure {
  const LocalAnalysisFailure({
    required this.code,
    required this.message,
    required this.retriable,
  });

  final String code;
  final String message;
  final bool retriable;
}

class LocalAnalysisEvent {
  const LocalAnalysisEvent({
    required this.stage,
    required this.status,
    required this.sequence,
    this.progress,
    this.message,
    this.bundlePath,
    this.failure,
  });

  final LocalAnalysisStage stage;
  final LocalAnalysisEventStatus status;
  final int sequence;
  final double? progress;
  final String? message;
  final String? bundlePath;
  final LocalAnalysisFailure? failure;
}

abstract interface class RunnerAnalysisPlatform {
  Stream<LocalAnalysisEvent> analyze(LocalAnalysisRequest request);
  Future<void> cancel();
  Future<void> dispose();
}

class RunnerAnalysis {
  RunnerAnalysis({RunnerAnalysisPlatform? platform})
      : _platform = platform ?? PigeonRunnerAnalysisPlatform();

  final RunnerAnalysisPlatform _platform;

  Stream<LocalAnalysisEvent> analyze(LocalAnalysisRequest request) =>
      _platform.analyze(request);

  Future<void> cancel() => _platform.cancel();

  Future<void> dispose() => _platform.dispose();
}

/// First video frame (rotation applied) as JPEG bytes, for anchor picking
/// before Local analysis. Matches the frame Server uses for its thumbnail.
Future<Uint8List> extractFirstFrame(String videoPath,
        {BinaryMessenger? binaryMessenger}) =>
    RunnerAnalysisHostApi(binaryMessenger: binaryMessenger)
        .extractFirstFrame(videoPath);

class PigeonRunnerAnalysisPlatform
    implements RunnerAnalysisPlatform, RunnerAnalysisFlutterApi {
  PigeonRunnerAnalysisPlatform({BinaryMessenger? binaryMessenger})
      : _binaryMessenger = binaryMessenger,
        _hostApi = RunnerAnalysisHostApi(binaryMessenger: binaryMessenger);

  final BinaryMessenger? _binaryMessenger;
  final RunnerAnalysisHostApi _hostApi;
  StreamController<LocalAnalysisEvent>? _events;
  var _disposed = false;
  var _callbackRegistered = false;

  @override
  Stream<LocalAnalysisEvent> analyze(LocalAnalysisRequest request) {
    if (_disposed) {
      throw StateError('RunnerAnalysis has been disposed');
    }
    if (_events != null && !_events!.isClosed) {
      throw StateError('A local analysis is already running');
    }
    if (!_callbackRegistered) {
      RunnerAnalysisFlutterApi.setUp(this, binaryMessenger: _binaryMessenger);
      _callbackRegistered = true;
    }
    final events = StreamController<LocalAnalysisEvent>.broadcast();
    _events = events;
    unawaited(_start(request, events));
    return events.stream;
  }

  Future<void> _start(
    LocalAnalysisRequest request,
    StreamController<LocalAnalysisEvent> events,
  ) async {
    try {
      await _hostApi.startAnalysis(_requestMessage(request));
    } catch (error) {
      if (!events.isClosed) {
        events.add(LocalAnalysisEvent(
          stage: LocalAnalysisStage.failed,
          status: LocalAnalysisEventStatus.failed,
          sequence: 0,
          failure: LocalAnalysisFailure(
            code: 'bridge_error',
            message: error.toString(),
            retriable: true,
          ),
        ));
        await events.close();
      }
    }
  }

  @override
  void onEvent(RunnerAnalysisEventMessage event) {
    final events = _events;
    if (events == null || events.isClosed) return;
    final converted = _event(event);
    events.add(converted);
    if (converted.stage == LocalAnalysisStage.completed ||
        converted.stage == LocalAnalysisStage.failed) {
      unawaited(events.close());
    }
  }

  @override
  Future<void> cancel() => _hostApi.cancelAnalysis();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_callbackRegistered) return;
    try {
      await _hostApi.dispose();
    } finally {
      if (_callbackRegistered) {
        RunnerAnalysisFlutterApi.setUp(null, binaryMessenger: _binaryMessenger);
        _callbackRegistered = false;
      }
      final events = _events;
      if (events != null && !events.isClosed) await events.close();
    }
  }
}

RunnerAnalysisRequestMessage _requestMessage(LocalAnalysisRequest request) =>
    RunnerAnalysisRequestMessage(
      schemaVersion: request.schemaVersion,
      requestId: request.requestId,
      analysisKind: request.analysisKind,
      comparisonGroupId: request.comparisonGroupId,
      includeOverlays: request.includeOverlays,
      outputDirectoryPath: request.outputDirectoryPath,
      kinematicsPolicy: RunnerAnalysisKinematicsPolicyMessage(
        speedMode: request.kinematicsPolicy.speedMode.name,
        butterworthCutoffHz: request.kinematicsPolicy.butterworthCutoffHz,
        flatInterpolationEpsilonM:
            request.kinematicsPolicy.flatInterpolationEpsilonM,
        laneWidthM: request.kinematicsPolicy.laneWidthM,
      ),
      videos: request.videos
          .map<RunnerAnalysisVideoMessage?>((video) =>
              RunnerAnalysisVideoMessage(
                cameraIndex: video.cameraIndex,
                path: video.path,
                fps: video.fps,
                width: video.width,
                height: video.height,
                rotationDegrees: video.rotationDegrees,
                calibration: switch (video.calibration) {
                  final calibration? => RunnerAnalysisCalibrationMessage(
                      startLine: calibration.startLine
                          ?.map<RunnerAnalysisPointMessage?>((point) =>
                              RunnerAnalysisPointMessage(
                                  x: point.x, y: point.y))
                          .toList(growable: false),
                      endLine: calibration.endLine
                          ?.map<RunnerAnalysisPointMessage?>((point) =>
                              RunnerAnalysisPointMessage(
                                  x: point.x, y: point.y))
                          .toList(growable: false),
                      distanceM: calibration.distanceM,
                      homographyImagePoints: calibration.homographyImagePoints
                          ?.map<RunnerAnalysisPointMessage?>((point) =>
                              RunnerAnalysisPointMessage(
                                  x: point.x, y: point.y))
                          .toList(growable: false),
                      homographyWorldPointsM: calibration.homographyWorldPointsM
                          ?.map<RunnerAnalysisPointMessage?>((point) =>
                              RunnerAnalysisPointMessage(
                                  x: point.x, y: point.y))
                          .toList(growable: false),
                      roiX: calibration.roiX,
                      roiY: calibration.roiY,
                      imagePointsNormalized: calibration.imagePointsNormalized,
                    ),
                  null => null,
                },
              ))
          .toList(growable: false),
    );

LocalAnalysisEvent _event(RunnerAnalysisEventMessage event) =>
    LocalAnalysisEvent(
      stage: LocalAnalysisStage.values[event.stage.index],
      status: LocalAnalysisEventStatus.values[event.status.index],
      sequence: event.sequence,
      progress: event.progress,
      message: event.message,
      bundlePath: event.bundlePath,
      failure: switch (event.failure) {
        final failure? => LocalAnalysisFailure(
            code: failure.code,
            message: failure.message,
            retriable: failure.retriable,
          ),
        null => null,
      },
    );
