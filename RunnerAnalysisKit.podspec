Pod::Spec.new do |s|
  s.name = 'RunnerAnalysisKit'
  s.version = '0.1.0'
  s.summary = 'High-level on-device running analysis engine and result contract.'
  s.homepage = 'https://github.com/j37724614-lab/runner-pose-ondevice'
  s.license = { :type => 'Proprietary' }
  s.author = { 'runner-analysis' => 'n26142393@gs.ncku.edu.tw' }
  s.source = { :path => '.' }
  s.source_files = 'Sources/RunnerAnalysisKit/**/*.swift'
  s.dependency 'RunnerPoseKit', '= 0.1.0'
  s.ios.deployment_target = '16.0'
  s.swift_version = '5.9'
end
