require 'sinatra'
require 'sord'
require 'open3'
require 'stringio'

TEMP_ROOT = '/tmp/sord-server'
APP_GEMFILE = File.expand_path(File.join(__dir__, '..', 'Gemfile'))

FileUtils.mkdir_p(TEMP_ROOT)

# Temporarily redirects $stdout and $stderr to a StringIO, runs the block, and
# then returns that string. The old $stdout and $stderr values are restored.
def capture_out
  old_stdout = $stdout
  old_stderr = $stderr

  stdout_stderr_string = StringIO.new
  $stdout = stdout_stderr_string
  $stderr = stdout_stderr_string

  yield

  stdout_stderr_string.string
ensure
  $stdout = old_stdout
  $stderr = old_stderr
end

# Returns a random string of alphanumeric characters of the given length.
# @return [String]
def random_alphanum(length=32)
  pool = ('a'..'z').to_a + ('0'..'9').to_a
  length.times.map { pool.sample }.join
end

# Creates a new temporary directory with a unique name and returns it.
# @return [String]
def create_temp_dir
  # Keep generating paths until we get one which doesn't exist
  path = File.join(TEMP_ROOT, random_alphanum) \
    until !path.nil? && !File.exists?(path)

  # Create the path
  FileUtils.mkdir_p(path)

  path
end

SordOutput = Struct.new('SordOutput', :success, :generator, :yard_log, :sord_log)

# Saves the given Ruby code to a temporary file, then runs YARD and Sord on it.
# Returns the Sord generator used.
# @param [String] code
# @param [Hash] options
# @return [SordOutput]
def run_sord(code, options)
  # Save it into a file in a new temporary directory
  temp_dir = create_temp_dir
  temp_rb_file = File.join(temp_dir, 'main.rb')
  File.write(temp_rb_file, code)

  # Prepare logs
  yard_log = "YARD did not run."
  sord_log = "Sord did not run."

  # Run YARD
  Dir.chdir(temp_dir) do
    yard_log, status = Open3.capture2e(
      { "BUNDLE_GEMFILE" => APP_GEMFILE },
      "bundle", "exec", "yard", "doc", temp_rb_file,
    )
    return SordOutput.new(false, nil, yard_log, sord_log) if !status.success?
  end

  # Run Sord
  sord_generator = Sord::Generator.new(options)
  sord_log = capture_out do
    Dir.chdir(temp_dir) do
      sord_generator.run
    end
  end

  # Return output object
  SordOutput.new(
    true,
    sord_generator,
    yard_log,
    sord_log,
  )
ensure
  # Clean up temporary directory
  FileUtils.rm_rf(temp_dir)
end

# Used when some kind of early error occurs before YARD or Sord try to run, for
# example a validation error. Halts the handler with a 400 error and a custom
# error message as part of a JSON response.
def early_error(message)
  content_type(:json)
  halt(400, {
    success: false,
    error: message,
  }.to_json)
end

post '/run' do
  # Get options and Ruby code from request
  request_json = JSON.parse(request.body.read, symbolize_names: true)
  ruby_code = request_json[:code] or early_error("Missing 'code'")
  options = request_json[:options] or early_error("Missing 'options'")

  # TODO: rate/length limit?

  # Run Sord on it and get the outputs
  sord_output = run_sord(ruby_code, options)
  parlour = sord_output.generator&.instance_variable_get(:@parlour)
  output_code = case options[:mode].to_sym
  when :rbi
    parlour&.rbi
  when :rbs
    parlour&.rbs
  else
    halt(500, "Unknown mode #{options[:mode]}")
  end

  # Build response
  status_code(sord_output.success ? 200 : 400)
  content_type(:json)
  {
    info: {
      version: Sord::VERSION,
    },
    code: output_code,
    yard_log: sord_output.yard_log,
    sord_log: sord_output.sord_log,
  }.to_json
end
