Pod::Spec.new do |s|
  s.name             = 'runner_pose'
  s.version          = '0.1.0'
  s.summary          = 'On-device runner pose (HRNet-W48 wholebody-23).'
  s.description       = 'Flutter plugin wrapping RunnerPoseKit. 規劃書 §05 P5 / §11.'
  s.homepage         = 'https://github.com/j37724614-lab/runner-pose-ondevice'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'runner-analysis' => 'n26142393@gs.ncku.edu.tw' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'

  # RunnerPoseKit is consumed as a local Swift package. On integration, either:
  #  (a) add ../../.. as a local SwiftPM dependency of the host app, or
  #  (b) vendor RunnerPoseKit sources here.
  # See ios/Classes/RunnerPosePlugin.swift.
  s.swift_version = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
