# encoding: utf-8
require "minitest_helper"
require "bundler"
require "etc"

# rubocop:disable Metrics/LineLength

class Airbrussh::FormatterTest < Minitest::Test
  include RakeTaskDefinition

  def setup
    @output = StringIO.new
    @log_file = StringIO.new
    @user = "test_user"

    # Hack to allow SSHKit's local backend to work on Windows
    Etc.stubs(:getpwuid => stub(:name => @user))

    # Force SSHKit to use ANSI color (CI $stdout may not be a TTY)
    @sshkit_color_orig = ENV["SSHKIT_COLOR"]
    ENV["SSHKIT_COLOR"] = "1"
  end

  def teardown
    Airbrussh::Rake::Context.current_task_name = nil
    SSHKit.reset_configuration!
    ENV["SSHKIT_COLOR"] = @sshkit_color_orig
  end

  def configure
    airbrussh_config = Airbrussh::Configuration.new
    airbrussh_config.log_file = @log_file
    airbrussh_config.color = false

    sshkit_config = SSHKit.config
    # clear SSHKit's command map so it doesn't prefix every cmd with /usr/bin/env
    sshkit_config.command_map = Hash.new do |hash, command|
      hash[command] = command.to_s
    end

    yield(airbrussh_config, sshkit_config)
    sshkit_config.output = formatter_class.new(@output, airbrussh_config)
  end

  def test_formats_execute_with_color
    configure do |airbrussh_config, sshkit_config|
      sshkit_config.output_verbosity = ::Logger::DEBUG
      airbrussh_config.command_output = true
      airbrussh_config.color = true
    end

    on_local do
      execute(:echo, "foo")
    end

    assert_output_lines(
      "      01 \e[0;33;49mecho foo\e[0m\n",
      "      01 foo\n",
      /    \e\[0;32;49m✔ 01 #{@user}@localhost\e\[0m \e\[0;90;49m\d.\d+s\e\[0m\n/
    )

    assert_log_file_lines(
      command_running("echo foo"),
      command_started_debug("echo foo"),
      command_std_stream(:stdout, "foo"),
      command_success
    )
  end

  def test_formats_execute_without_color
    configure do |airbrussh_config|
      airbrussh_config.command_output = true
    end

    on_local do
      execute(:echo, "foo")
    end

    assert_output_lines(
      "      01 echo foo\n",
      "      01 foo\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/
    )

    assert_log_file_lines(
      command_running("echo foo"), command_success
    )
  end

  def test_formats_without_command_output
    configure do |airbrussh_config|
      airbrussh_config.command_output = false
    end

    on_local do
      execute(:ls, "-l")
    end

    assert_output_lines(
      "      01 ls -l\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/
    )
  end

  def test_formats_failing_execute_with_color
    configure do |airbrussh_config, sshkit_config|
      sshkit_config.output_verbosity = ::Logger::DEBUG
      airbrussh_config.command_output = true
      airbrussh_config.color = true
    end

    error = nil
    on_local do
      begin
        execute(:echo, "hi")
        execute(:ls, "_file_does_not_exist")
        # rubocop:disable Lint/HandleExceptions
      rescue SSHKit::Command::Failed => error
        # rubocop:enable Lint/HandleExceptions
      end
    end

    refute_nil error

    expected_output = [
      "      01 \e[0;33;49mecho hi\e[0m\n",
      "      01 hi\n",
      /    \e\[0;32;49m✔ 01 #{@user}@localhost\e\[0m \e\[0;90;49m\d.\d+s\e\[0m\n/,
      "      02 \e[0;33;49mls _file_does_not_exist\e[0m\n"
    ]

    error_message = "ls: (cannot access )?_file_does_not_exist: No such file or directory"

    # Don't know why this log line doesn't show up in SSHKit 1.6.1
    expected_output << /      02 #{error_message}\n/ if sshkit_after?("1.6.1")

    assert_output_lines(*expected_output)

    expected_log_output = [
      command_running("echo hi"),
      command_started_debug("echo hi"),
      command_std_stream(:stdout, "hi"),
      command_success,

      command_running("ls _file_does_not_exist"),
      command_started_debug("ls _file_does_not_exist")
    ]

    if sshkit_after?("1.6.1")
      expected_log_output << command_std_stream(:stderr, error_message)
      expected_log_output << "\e[0m" unless sshkit_master?
    end

    assert_log_file_lines(*expected_log_output)
  end

  def test_formats_capture_with_color
    configure do |airbrussh_config|
      airbrussh_config.command_output = true
      airbrussh_config.color = true
    end

    on_local do
      capture(:ls, "-1", "airbrussh.gemspec", :verbosity => SSHKit::Logger::INFO)
    end

    assert_output_lines(
      "      01 \e[0;33;49mls -1 airbrussh.gemspec\e[0m\n",
      "      01 airbrussh.gemspec\n",
      /    \e\[0;32;49m✔ 01 #{@user}@localhost\e\[0m \e\[0;90;49m\d.\d+s\e\[0m\n/
    )

    assert_log_file_lines(
      command_running("ls -1 airbrussh.gemspec"), command_success
    )
  end

  def test_formats_capture_without_color
    configure do |airbrussh_config|
      airbrussh_config.command_output = true
    end

    on_local do
      capture(:ls, "-1", "airbrussh.gemspec", :verbosity => SSHKit::Logger::INFO)
    end

    assert_output_lines(
      "      01 ls -1 airbrussh.gemspec\n",
      "      01 airbrussh.gemspec\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/
    )

    assert_log_file_lines(
      command_running("ls -1 airbrussh.gemspec"), command_success
    )
  end

  def test_does_not_output_test_commands
    configure do |airbrussh_config, sshkit_config|
      airbrussh_config.command_output = true
      sshkit_config.output_verbosity = Logger::DEBUG
    end

    on_local do
      test("echo hi")
    end

    assert_output_lines

    assert_log_file_lines(
      command_running("echo hi", "DEBUG"),
      command_started_debug("echo hi"),
      command_std_stream(:stdout, "hi"),
      command_success_debug
    )
  end

  def test_handles_rake_tasks
    configure do |airbrussh_config|
      airbrussh_config.monkey_patch_rake = true
      airbrussh_config.command_output = true
    end

    on_local("special_rake_task") do
      execute(:echo, "command 1")
      info("Starting command 2")
      execute(:echo, "command 2")
    end
    on_local("special_rake_task_2") do
      error("New task starting")
    end
    on_local("special_rake_task_3") do
      execute(:echo, "command 3")
      execute(:echo, "command 4")
      warn("All done")
    end

    assert_output_lines(
      "00:00 special_rake_task\n",
      "      01 echo command 1\n",
      "      01 command 1\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/,
      "      Starting command 2\n",
      "      02 echo command 2\n",
      "      02 command 2\n",
      /    ✔ 02 #{@user}@localhost \d.\d+s\n/,
      "00:00 special_rake_task_2\n",
      "      New task starting\n",
      "00:00 special_rake_task_3\n",
      "      01 echo command 3\n",
      "      01 command 3\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/,
      "      02 echo command 4\n",
      "      02 command 4\n",
      /    ✔ 02 #{@user}@localhost \d.\d+s\n/,
      "      All done\n"
    )

    assert_log_file_lines(
      command_running("echo command 1"), command_success,
      /#{blue('INFO')} Starting command 2\n/,
      command_running("echo command 2"), command_success,
      /#{red('ERROR')} New task starting\n/,
      command_running("echo command 3"), command_success,
      command_running("echo command 4"), command_success,
      /#{yellow('WARN')} All done\n/
    )
  end

  def test_log_message_levels
    configure do |_airbrussh_config, sshkit_config|
      sshkit_config.output_verbosity = Logger::DEBUG
    end

    on_local do
      %w(log fatal error warn info debug).each do |level|
        send(level, "Test")
      end
    end

    assert_output_lines(
      "      Test\n",
      "      Test\n",
      "      Test\n",
      "      Test\n",
      "      Test\n"
    )

    assert_log_file_lines(
      /#{blue('INFO')} Test\n/,
      /#{red('FATAL')} Test\n/,
      /#{red('ERROR')} Test\n/,
      /#{yellow('WARN')} Test\n/,
      /#{blue('INFO')} Test\n/,
      /#{black('DEBUG')} Test\n/
    )
  end

  def test_interleaved_debug_and_info_commands
    configure do |airbrussh_config|
      airbrussh_config.monkey_patch_rake = true
      airbrussh_config.command_output = true
    end

    on_local("interleaving_test") do
      test("echo hi")
      # test methods are logged at debug level by default
      execute(:echo, "command 1")
      test("echo hello")
      debug("Debug line should not be output")
      info("Info line should be output")
      execute(:echo, "command 2")
      execute(:echo, "command 3", :verbosity => :debug)
      execute(:echo, "command 4")
    end

    assert_output_lines(
      "00:00 interleaving_test\n",
      "      01 echo command 1\n",
      "      01 command 1\n",
      /    ✔ 01 #{@user}@localhost \d.\d+s\n/,
      "      Info line should be output\n",
      "      02 echo command 2\n",
      "      02 command 2\n",
      /    ✔ 02 #{@user}@localhost \d.\d+s\n/,
      "      03 echo command 4\n",
      "      03 command 4\n",
      /    ✔ 03 #{@user}@localhost \d.\d+s\n/
    )
  end

  private

  def on_local(task_name=nil, &block)
    define_and_execute_rake_task(task_name) do
      local_backend = SSHKit::Backend::Local.new(&block)
      # Note: The Local backend default log changed to include the user name around version 1.7.1
      # Therefore we inject a user in order to make the logging consistent in old versions (i.e. 1.6.1)
      unless sshkit_after?("1.6.1")
        local_backend.instance_variable_get(:@host).stubs(:user => @user)
      end

      local_backend.run
    end
  end

  def assert_output_lines(*expected_output)
    expected_output = [
      "Using airbrussh format.\n",
      /Verbose output is being written to .*\n/
    ] + expected_output
    assert_string_io_lines(expected_output, @output)
  end

  def assert_string_io_lines(expected_output, string_io)
    lines = string_io.string.lines.to_a
    assert_equal expected_output.size, lines.size, lines.map(&:inspect).join(",\n")
    lines.each.with_index do |line, i|
      assert_case_equal(expected_output[i], line)
    end
  end

  def assert_log_file_lines(*command_lines)
    preamble_lines = [
      /#{blue('INFO')} ---------------------------------------------------------------------------\n/,
      /#{blue('INFO')} START [\d\-]+ [\d\:]+ [\+\-]\d+ cap\n/,
      /#{blue('INFO')} ---------------------------------------------------------------------------\n/
    ]

    assert_string_io_lines(preamble_lines + command_lines, @log_file)
  end

  def command_running(command, level="INFO")
    level_tag_color = (level == "INFO") ? :blue : :black
    /#{send(level_tag_color, level)} \[#{green('\w+')}\] Running #{bold_yellow("#{command}")} as #{blue(@user)}@#{blue('localhost')}\n/
  end

  def command_started_debug(command)
    /#{black('DEBUG')} \[#{green('\w+')}\] Command: #{blue(command)}/
  end

  def command_std_stream(stream, output)
    # Note ansii character end code is omitted in 1.7.1 due to newline
    # This is probably a bug in SSHKit
    color = stream == :stdout ? :green : :red
    if sshkit_master?
      formatted_output = send(color, "\\t#{output}") + "\n"
    else
      formatted_output = send(color, "\\t#{output}\\n").chomp('\\e\\[0m')
    end
    /#{black('DEBUG')} \[#{green('\w+')}\] #{formatted_output}/
  end

  def command_success
    /#{blue('INFO')} \[#{green('\w+')}\] Finished in 0.\d+ seconds with exit status 0 \(#{bold_green("successful")}\).\n/
  end

  def command_success_debug
    /#{black('DEBUG')} \[#{green('\w+')}\] Finished in 0.\d+ seconds with exit status 0 \(#{bold_green("successful")}\).\n/
  end

  def command_failed(exit_status)
    /#{black('DEBUG')} \[#{green('\w+')}\] Finished in 0.\d+ seconds with exit status #{exit_status} \(#{bold_red("failed")}\)/
  end

  {
    :black => "0;30;49",
    :red => "0;31;49",
    :green => "0;32;49",
    :yellow => "0;33;49",
    :blue => "0;34;49",
    :bold_red => "1;31;49",
    :bold_green => "1;32;49",
    :bold_yellow => "1;33;49"
  }.each do |color, code|
    define_method(color) do |string|
      "\\e\\[#{code}m#{string}\\e\\[0m"
    end
  end

  def sshkit_after?(version)
    Gem.loaded_specs["sshkit"].version > Gem::Version.new(version)
  end

  def sshkit_master?
    gem_source = Gem.loaded_specs["sshkit"].source
    gem_source.is_a?(Bundler::Source::Git) && gem_source.branch == "master"
  end

  def formatter_class
    Airbrussh::Formatter
  end

  module Minitest::Assertions
    # rubocop:disable Style/CaseEquality
    def assert_case_equal(matcher, obj, msg=nil)
      message = message(msg) { "Expected #{mu_pp matcher} to === #{mu_pp obj}" }
      assert matcher === obj, message
    end
    # rubocop:enable Style/CaseEquality
  end
end
