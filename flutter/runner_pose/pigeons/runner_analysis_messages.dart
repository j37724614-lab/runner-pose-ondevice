import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/runner_analysis_messages.g.dart',
  swiftOut: 'ios/Classes/RunnerAnalysisMessages.g.swift',
  swiftOptions: SwiftOptions(),
))
class RunnerAnalysisVideoMessage {
  RunnerAnalysisVideoMessage({
    required this.cameraIndex,
    required this.path,
    required this.fps,
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });

  int cameraIndex;
  String path;
  double fps;
  int width;
  int height;
  int rotationDegrees;
}

class RunnerAnalysisRequestMessage {
  RunnerAnalysisRequestMessage({
    required this.schemaVersion,
    required this.requestId,
    this.comparisonGroupId,
    required this.outputDirectoryPath,
    required this.videos,
  });

  String schemaVersion;
  String requestId;
  String? comparisonGroupId;
  String outputDirectoryPath;
  List<RunnerAnalysisVideoMessage?> videos;
}

enum RunnerAnalysisStageMessage {
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

enum RunnerAnalysisEventStatusMessage {
  started,
  progress,
  completed,
  skipped,
  failed,
}

class RunnerAnalysisFailureMessage {
  RunnerAnalysisFailureMessage({
    required this.code,
    required this.message,
    required this.retriable,
  });

  String code;
  String message;
  bool retriable;
}

class RunnerAnalysisEventMessage {
  RunnerAnalysisEventMessage({
    required this.stage,
    required this.status,
    required this.sequence,
    this.progress,
    this.message,
    this.bundlePath,
    this.failure,
  });

  RunnerAnalysisStageMessage stage;
  RunnerAnalysisEventStatusMessage status;
  int sequence;
  double? progress;
  String? message;
  String? bundlePath;
  RunnerAnalysisFailureMessage? failure;
}

@HostApi()
abstract class RunnerAnalysisHostApi {
  @async
  void startAnalysis(RunnerAnalysisRequestMessage request);

  @async
  void cancelAnalysis();

  @async
  void dispose();
}

@FlutterApi()
abstract class RunnerAnalysisFlutterApi {
  void onEvent(RunnerAnalysisEventMessage event);
}
