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

class LocalAnalysisVideo {
  const LocalAnalysisVideo({
    required this.cameraIndex,
    required this.path,
    required this.fps,
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });

  final int cameraIndex;
  final String path;
  final double fps;
  final int width;
  final int height;
  final int rotationDegrees;
}

class LocalAnalysisRequest {
  const LocalAnalysisRequest({
    this.schemaVersion = '1.0.0',
    required this.requestId,
    this.comparisonGroupId,
    this.includeOverlays = false,
    required this.outputDirectoryPath,
    required this.videos,
  });

  final String schemaVersion;
  final String requestId;
  final String? comparisonGroupId;
  final bool includeOverlays;
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
      comparisonGroupId: request.comparisonGroupId,
      includeOverlays: request.includeOverlays,
      outputDirectoryPath: request.outputDirectoryPath,
      videos: request.videos
          .map<RunnerAnalysisVideoMessage?>(
              (video) => RunnerAnalysisVideoMessage(
                    cameraIndex: video.cameraIndex,
                    path: video.path,
                    fps: video.fps,
                    width: video.width,
                    height: video.height,
                    rotationDegrees: video.rotationDegrees,
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
