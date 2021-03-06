module Ruboto
  module Util
    module Update
      ###########################################################################
      #
      # Updating components
      #
      def update_test(force = nil)
        root = Dir.getwd
        if force || !Dir.exists?("#{root}/test")
          name = verify_strings.root.elements['string'].text
          puts "\nGenerating Android test project #{name} in #{root}..."
          system "android create test-project -m #{root} -n #{name}Test -p #{root}/test"
          FileUtils.rm_rf File.join(root, 'test', 'src', verify_package.split('.'))
          puts "Done"
        else
          puts "Test project already exists.  Use --force to overwrite."
        end

        Dir.chdir File.join(root, 'test') do
          test_manifest = REXML::Document.new(File.read('AndroidManifest.xml')).root
          test_manifest.elements['instrumentation'].attributes['android:name'] = 'org.ruboto.test.InstrumentationTestRunner'
          File.open("AndroidManifest.xml", 'w') {|f| test_manifest.document.write(f, 4)}
          File.open('build.properties', 'a'){|f| f.puts 'test.runner=org.ruboto.test.InstrumentationTestRunner'}
          ant_setup_line = /^(\s*<setup\s*\/>\n)/
          run_tests_override = <<-EOF
          <macrodef name="run-tests-helper">
          <attribute name="emma.enabled" default="false"/>
          <element name="extra-instrument-args" optional="yes"/>
          <sequential>
          <echo>Running tests ...</echo>
          <exec executable="${adb}" failonerror="true" outputproperty="tests.output">
          <arg line="${adb.device.arg}"/>
          <arg value="shell"/>
          <arg value="am"/>
          <arg value="instrument"/>
          <arg value="-w"/>
          <arg value="-e"/>
          <arg value="coverage"/>
          <arg value="@{emma.enabled}"/>
          <extra-instrument-args/>
          <arg value="${manifest.package}/${test.runner}"/>
          </exec>
          <echo message="${tests.output}"/>
          <fail message="Tests failed!!!">
          <condition>
            <or>
              <contains string="${tests.output}" substring="INSTRUMENTATION_FAILED"/>
              <contains string="${tests.output}" substring="FAILURES"/>
            </or>
          </condition>
          </fail>
          </sequential>
          </macrodef>

<target name="run-tests-quick"
description="Runs tests with previously installed packages">
<run-tests-helper />
</target>
          
          EOF
          ant_script = File.read('build.xml').gsub(ant_setup_line, "\\1#{run_tests_override}")
          File.open('build.xml', 'w'){|f| f << ant_script}
        end
      end

      def update_jruby(force=nil)
        jruby_core = Dir.glob("libs/jruby-core-*.jar")[0]
        jruby_stdlib = Dir.glob("libs/jruby-stdlib-*.jar")[0]
        new_jruby_version = JRubyJars::core_jar_path.split('/')[-1][11..-5]

        unless force
          abort "cannot find existing jruby jars in libs. Make sure you're in the root directory of your app" if
          (not jruby_core or not jruby_stdlib)

          current_jruby_version = jruby_core ? jruby_core[16..-5] : "None"
          abort "both jruby versions are #{new_jruby_version}. Nothing to update. Make sure you 'gem update jruby-jars' if there is a new version" if
          current_jruby_version == new_jruby_version

          puts "Current jruby version: #{current_jruby_version}"
          puts "New jruby version: #{new_jruby_version}"
        end

        copier = AssetCopier.new Ruboto::ASSETS, File.expand_path(".")
        log_action("Removing #{jruby_core}") {File.delete jruby_core} if jruby_core
        log_action("Removing #{jruby_stdlib}") {File.delete jruby_stdlib} if jruby_stdlib
        log_action("Copying #{JRubyJars::core_jar_path} to libs") {copier.copy_from_absolute_path JRubyJars::core_jar_path, "libs"}
        log_action("Copying #{JRubyJars::stdlib_jar_path} to libs") {copier.copy_from_absolute_path JRubyJars::stdlib_jar_path, "libs"}

        reconfigure_jruby_libs

        puts "JRuby version is now: #{new_jruby_version}"
      end

      def update_assets(force = nil)
        puts "\nCopying files:"
        copier = Ruboto::Util::AssetCopier.new Ruboto::ASSETS, '.'

        %w{Rakefile .gitignore assets res test}.each do |f|
          log_action(f) {copier.copy f}
        end
      end

      def update_classes(force = nil)
        copier = Ruboto::Util::AssetCopier.new Ruboto::ASSETS, '.'
        log_action("Ruboto java classes"){copier.copy "src/org/ruboto/*.java", "src/org/ruboto"}
        log_action("Ruboto java test classes"){copier.copy "src/org/ruboto/test/*.java", "test/src/org/ruboto/test"}
      end

      def update_manifest(min_sdk, target, force = false)
        log_action("\nAdding activities (RubotoActivity and RubotoDialog) and SDK versions to the manifest") do
          if sdk_element = verify_manifest.elements['uses-sdk']
            min_sdk ||= sdk_element.attributes["android:minSdkVersion"]
            target ||= sdk_element.attributes["android:targetSdkVersion"]
          end
          if min_sdk.to_i >= 11
            verify_manifest.elements['application'].attributes['android:hardwareAccelerated'] ||= 'true'
          end
          app_element = verify_manifest.elements['application']
          if app_element.elements["activity[@android:name='org.ruboto.RubotoActivity']"]
            puts 'found activity tag'
          else
            app_element.add_element 'activity', {"android:name" => "org.ruboto.RubotoActivity"}
          end
          app_element = verify_manifest.elements['application']
          if app_element.elements["activity[@android:name='org.ruboto.RubotoDialog']"]
            puts 'found dialog tag'
          else
            app_element.add_element 'activity', {"android:name" => "org.ruboto.RubotoDialog", "android:theme" => "@android:style/Theme.Dialog"}
          end
          if sdk_element
            sdk_element.attributes["android:minSdkVersion"] = min_sdk
            sdk_element.attributes["android:targetSdkVersion"] = target
          else
            verify_manifest.add_element 'uses-sdk', {"android:minSdkVersion" => min_sdk, "android:targetSdkVersion" => target}
          end
          save_manifest
        end
      end

      def update_core_classes(force = false)
        generate_core_classes(:class => "all", :method_base => "on", :method_include => "", :method_exclude => "", :force => force, :implements => "")
      end

      def update_ruboto(force=nil)
        verify_manifest

        from = File.expand_path(Ruboto::GEM_ROOT + "/assets/assets/scripts/ruboto.rb")
        to = File.expand_path("./assets/scripts/ruboto.rb")

        from_text = File.read(from)
        to_text = File.read(to) if File.exists?(to)

        unless force
          puts "New version: #{from_text[/\$RUBOTO_VERSION = (\d+)/, 1]}"
          puts "Old version: #{to_text ? to_text[/\$RUBOTO_VERSION = (\d+)/, 1] : 'none'}"

          abort "The ruboto.rb version has not changed. Use --force to force update." if
          from_text[/\$RUBOTO_VERSION = (\d+)/, 1] == to_text[/\$RUBOTO_VERSION = (\d+)/, 1]
        end

        log_action("Copying ruboto.rb and setting the package name") do
          File.open(to, 'w') {|f| f << from_text}
        end
      end

      #
      # reconfigure_jruby_libs:
      #   - removes unneeded code from jruby-core
      #   - moves ruby stdlib to the root of the ruby-stdlib jar
      #

      def reconfigure_jruby_libs
        jruby_core = JRubyJars::core_jar_path.split('/')[-1]
        log_action("Removing unneeded classes from #{jruby_core}") do
          Dir.mkdir "libs/tmp"
          Dir.chdir "libs/tmp"
          FileUtils.move "../#{jruby_core}", "."
          `jar -xf #{jruby_core}`
          File.delete jruby_core
          ['cext', 'jni', 'org/jruby/ant', 'org/jruby/compiler/ir', 'org/jruby/demo', 'org/jruby/embed/bsf',
            'org/jruby/embed/jsr223', 'org/jruby/ext/ffi','org/jruby/javasupport/bsf'
          ].each {|i| FileUtils.remove_dir i, true}
          `jar -cf ../#{jruby_core} .`
          Dir.chdir "../.."
          FileUtils.remove_dir "libs/tmp", true
        end

        jruby_stdlib = JRubyJars::stdlib_jar_path.split('/')[-1]
        log_action("Reformatting #{jruby_stdlib}") do
          Dir.mkdir "libs/tmp"
          Dir.chdir "libs/tmp"
          FileUtils.move "../#{jruby_stdlib}", "."
          `jar -xf #{jruby_stdlib}`
          File.delete jruby_stdlib
          FileUtils.move "META-INF/jruby.home/lib/ruby/1.8", ".."
          Dir["META-INF/jruby.home/lib/ruby/site_ruby/1.8/*"].each do |f|
            next if File.basename(f) =~ /^..?$/
            FileUtils.move f, "../1.8/" + File.basename(f)
          end
          Dir.chdir "../1.8"
          FileUtils.remove_dir "../tmp", true
          `jar -cf ../#{jruby_stdlib} .`
          Dir.chdir "../.."
          FileUtils.remove_dir "libs/1.8", true
        end
      end
    end
  end
end