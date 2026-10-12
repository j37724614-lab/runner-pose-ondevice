import 'package:pigeon/pigeon.dart';

class RunnerAnalysisPointMessage {
  RunnerAnalysisPointMessage({required this.x, required this.y});

  double x;
  double y;
}

class RunnerAnalysisCalibrationMessage {
  RunnerAnalysisCalibrationMessage({
    this.startLine,
    this.endLine,
    this.distanceM,
    this.homographyImagePoints,
    this.homographyWorldPointsM,
    this.roiX,
    this.roiY,
    this.imagePointsNormalized,
  });

  List<RunnerAnalysisPointMessage?>? startLine;
  List<RunnerAnalysisPointMessage?>? endLine;
  double? distanceM;
  List<RunnerAnalysisPointMessage?>? homographyImagePoints;
  List<RunnerAnalysisPointMessage?>? homographyWorldPointsM;
  List<double?>? roiX;
  List<double?>? roiY;

  /// True when image points and ROI are 0...1 fractions of the oriented video
  /// frame; the native side scales them by the dimensions it reads from the file.
  bool? imagePointsNormalized;
}

class RunnerAnalysisKinematicsPolicyMessage {
  RunnerAnalysisKinematicsPolicyMessage({
    required this.speedMode,
    required this.butterworthCutoffHz,
    required this.flatInterpolationEpsilonM,
    required this.laneWidthM,
  });

  String speedMode;
  double butterworthCutoffHz;
  double flatInterpolationEpsilonM;
  double laneWidthM;
}

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
    this.calibration,
  });

  int cameraIndex;
  String path;
  double fps;
  int width;
  int height;
  int rotationDegrees;
  RunnerAnalysisCalibrationMessage? calibration;
}

class RunnerAnalysisRequestMessage {
  RunnerAnalysisRequestMessage({
    required this.schemaVersion,
    required this.requestId,
    required this.analysisKind,
    this.comparisonGroupId,
    required this.includeOverlays,
    required this.outputDirectoryPath,
    required this.kinematicsPolicy,
    required this.videos,
  });

  String schemaVersion;
  String requestId;
  String analysisKind;
  String? comparisonGroupId;
  bool includeOverlays;
  String outputDirectoryPath;
  RunnerAnalysisKinematicsPolicyMessage kinematicsPolicy;
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
