import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runner_pose/runner_analysis.dart';
import 'package:runner_pose/src/runner_analysis_messages.g.dart';

class FakeRunnerAnalysisPlatform implements RunnerAnalysisPlatform {
  final events = StreamController<LocalAnalysisEvent>.broadcast();
  LocalAnalysisRequest? receivedRequest;
  var cancelCalls = 0;
  var disposeCalls = 0;

  @override
  Stream<LocalAnalysisEvent> analyze(LocalAnalysisRequest request) {
    receivedRequest = request;
    return events.stream;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('analyze forwards file paths and exposes native stage events', () async {
    final platform = FakeRunnerAnalysisPlatform();
    final analysis = RunnerAnalysis(platform: platform);
    const request = LocalAnalysisRequest(
      requestId: '11111111-1111-4111-8111-111111111111',
      outputDirectoryPath: '/tmp/results',
      videos: [
        LocalAnalysisVideo(
          cameraIndex: 0,
          path: '/tmp/input.mov',
          fps: 60,
          width: 1920,
          height: 1080,
          rotationDegrees: 0,
        ),
      ],
    );

    final received = <LocalAnalysisEvent>[];
    final subscription = analysis.analyze(request).listen(received.add);
    platform.events.add(const LocalAnalysisEvent(
      stage: LocalAnalysisStage.pose2d,
      status: LocalAnalysisEventStatus.started,
      sequence: 2,
    ));
    platform.events.add(const LocalAnalysisEvent(
      stage: LocalAnalysisStage.completed,
      status: LocalAnalysisEventStatus.completed,
      sequence: 6,
      bundlePath: '/tmp/results/run-id',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(platform.receivedRequest, same(request));
    expect(platform.receivedRequest!.videos.single.path, '/tmp/input.mov');
    expect(received.map((event) => event.stage), [
      LocalAnalysisStage.pose2d,
      LocalAnalysisStage.completed,
    ]);
    expect(received.last.bundlePath, '/tmp/results/run-id');

    await subscription.cancel();
    await analysis.dispose();
  });

  test('cancel and dispose are forwarded to the native platform', () async {
    final platform = FakeRunnerAnalysisPlatform();
    final analysis = RunnerAnalysis(platform: platform);

    await analysis.cancel();
    await analysis.dispose();

    expect(platform.cancelCalls, 1);
    expect(platform.disposeCalls, 1);
  });

  test('Pigeon transport sends paths and converts a completed callback',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    RunnerAnalysisRequestMessage? nativeRequest;
    final startChannel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.runner_pose.RunnerAnalysisHostApi.startAnalysis',
      RunnerAnalysisHostApi.pigeonChannelCodec,
      binaryMessenger: messenger,
    );
    messenger.setMockDecodedMessageHandler<Object?>(startChannel,
        (message) async {
      nativeRequest =
          (message! as List<Object?>).single! as RunnerAnalysisRequestMessage;
      return <Object?>[null];
    });
    addTearDown(() =>
        messenger.setMockDecodedMessageHandler<Object?>(startChannel, null));
    final disposeChannel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.runner_pose.RunnerAnalysisHostApi.dispose',
      RunnerAnalysisHostApi.pigeonChannelCodec,
      binaryMessenger: messenger,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      disposeChannel,
      (_) async => <Object?>[null],
    );
    addTearDown(() =>
        messenger.setMockDecodedMessageHandler<Object?>(disposeChannel, null));

    final platform = PigeonRunnerAnalysisPlatform(binaryMessenger: messenger);
    final events = platform.analyze(const LocalAnalysisRequest(
      requestId: '11111111-1111-4111-8111-111111111111',
      analysisKind: 'long_jump',
      comparisonGroupId: 'compare-1',
      includeOverlays: true,
      kinematicsPolicy: LocalAnalysisKinematicsPolicy(
        speedMode: LocalAnalysisSpeedMode.homography,
        butterworthCutoffHz: 4,
        flatInterpolationEpsilonM: 0.002,
        laneWidthM: 1.25,
      ),
      outputDirectoryPath: '/tmp/results',
      videos: [
        LocalAnalysisVideo(
          cameraIndex: 0,
          path: '/tmp/input.mov',
          fps: 59.94,
          width: 1920,
          height: 1080,
          rotationDegrees: 90,
          calibration: LocalAnalysisCalibration(
            startLine: [
              LocalAnalysisPoint(100, 700),
              LocalAnalysisPoint(100, 900)
            ],
            endLine: [
              LocalAnalysisPoint(1800, 700),
              LocalAnalysisPoint(1800, 900)
            ],
            distanceM: 20,
            homographyImagePoints: [
              LocalAnalysisPoint(100, 700),
              LocalAnalysisPoint(100, 900),
              LocalAnalysisPoint(1800, 700),
              LocalAnalysisPoint(1800, 900),
            ],
            homographyWorldPointsM: [
              LocalAnalysisPoint(0, 0),
              LocalAnalysisPoint(0, 1.22),
              LocalAnalysisPoint(20, 0),
              LocalAnalysisPoint(20, 1.22),
            ],
            roiX: [100, 1800],
            roiY: [700, 900],
          ),
        ),
      ],
    ));
    final completed = expectLater(
      events,
      emitsInOrder([
        isA<LocalAnalysisEvent>()
            .having(
                (event) => event.stage, 'stage', LocalAnalysisStage.completed)
            .having((event) => event.bundlePath, 'bundlePath',
                '/tmp/results/run-id'),
        emitsDone,
      ]),
    );
    await Future<void>.delayed(Duration.zero);

    expect(nativeRequest!.comparisonGroupId, 'compare-1');
    expect(nativeRequest!.analysisKind, 'long_jump');
    expect(nativeRequest!.includeOverlays, isTrue);
    expect(nativeRequest!.kinematicsPolicy.speedMode, 'homography');
    expect(nativeRequest!.kinematicsPolicy.butterworthCutoffHz, 4);
    expect(nativeRequest!.kinematicsPolicy.flatInterpolationEpsilonM, 0.002);
    expect(nativeRequest!.kinematicsPolicy.laneWidthM, 1.25);
    expect(nativeRequest!.videos.single!.path, '/tmp/input.mov');
    expect(nativeRequest!.videos.single!.rotationDegrees, 90);
    expect(nativeRequest!.videos.single!.calibration!.distanceM, 20);
    expect(
      nativeRequest!.videos.single!.calibration!.homographyImagePoints,
      hasLength(4),
    );
    expect(nativeRequest!.videos.single!.calibration!.roiX, [100, 1800]);
    expect(nativeRequest!.videos.single!.calibration!.roiY, [700, 900]);
    expect(
      nativeRequest!.videos.single!.calibration!.imagePointsNormalized,
      isFalse,
    );

    final callbackData =
        RunnerAnalysisFlutterApi.pigeonChannelCodec.encodeMessage(<Object?>[
      RunnerAnalysisEventMessage(
        stage: RunnerAnalysisStageMessage.completed,
        status: RunnerAnalysisEventStatusMessage.completed,
        sequence: 6,
        bundlePath: '/tmp/results/run-id',
      ),
    ]);
    await messenger.handlePlatformMessage(
      'dev.flutter.pigeon.runner_pose.RunnerAnalysisFlutterApi.onEvent',
      callbackData,
      (_) {},
    );

    await completed;
    await platform.dispose();
  });
}
