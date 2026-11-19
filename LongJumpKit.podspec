Pod::Spec.new do |s|
  s.name = 'LongJumpKit'
  s.version = '0.1.0'
  s.summary = "Port of the server's long-jump analysis (events, board, distance, sand mark)."
  s.homepage = 'https://github.com/j37724614-lab/runner-pose-ondevice'
  s.license = { :type => 'Proprietary' }
  s.author = { 'runner-analysis' => 'runner-analysis' }
  s.source = { :path => '.' }
  s.source_files = 'Sources/LongJumpKit/**/*.swift'
  s.ios.deployment_target = '16.0'
  s.swift_version = '5.9'
end
