Pod::Spec.new do |s|
  s.name = 'RunnerPoseKit'
  s.version = '0.1.0'
  s.summary = 'On-device runner pose extraction.'
  s.homepage = 'https://github.com/j37724614-lab/runner-pose-ondevice'
  s.license = { :type => 'Proprietary' }
  s.author = { 'runner-analysis' => 'n26142393@gs.ncku.edu.tw' }
  s.source = { :path => '.' }
  s.source_files = 'Sources/RunnerPoseKit/**/*.swift'
  s.resource_bundles = {
    'RunnerPoseKitResources' => ['Sources/RunnerPoseKit/Resources/**/*']
  }
  s.dependency 'UltralyticsYOLO', '>= 8.3.0', '< 9.0.0'
  s.ios.deployment_target = '16.0'
  s.swift_version = '5.9'
end
