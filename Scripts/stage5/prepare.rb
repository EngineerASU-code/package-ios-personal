# Generate the simulator-only test target inside the disposable runner checkout.
require 'xcodeproj'
project = Xcodeproj::Project.open('MyCompanion.xcodeproj')
app = project.targets.find { |target| target.name == 'MyCompanion' }
tests = project.new_target(:ui_test_bundle, 'WidgetUITests', :ios, '17.0')
tests.add_dependency(app)
tests.add_file_references([project.main_group.new_file('Scripts/stage5/WidgetUITests.swift')])
tests.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_NAME' => tests.name, 'TEST_TARGET_NAME' => app.name, 'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'local.mycompanion.uitests', 'SWIFT_VERSION' => '5.0')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests)
scheme.save_as(project.path, 'Stage5', true)
