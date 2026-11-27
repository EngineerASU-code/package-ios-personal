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
widget = project.targets.find { |target| target.name == 'CompanionWidget' }
provider_tests = project.new_target(:unit_test_bundle, 'WidgetProviderTests', :ios, '17.0')
provider_tests.add_dependency(app)
provider_tests.add_file_references(widget.source_build_phase.files_references)
provider_tests.add_file_references([project.main_group.new_file('Scripts/stage5/WidgetProviderTests.swift')])
provider_tests.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_NAME' => provider_tests.name,
    'SWIFT_VERSION' => '5.0',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'local.mycompanion.providertests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) STAGE5_WIDGET_TESTS',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/MyCompanion.app/MyCompanion',
    'BUNDLE_LOADER' => '$(TEST_HOST)'
  )
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests)
scheme.add_test_target(provider_tests)
scheme.save_as(project.path, 'Stage5', true)
