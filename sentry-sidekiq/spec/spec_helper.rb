require "bundler/setup"
require "pry"
require "debug" if RUBY_VERSION.to_f >= 2.6

# this enables sidekiq's server mode
require "sidekiq/cli"
# require "support/test_sidekiq_app/app"

require "sentry-ruby"

require 'simplecov'

SimpleCov.start do
  project_name "sentry-sidekiq"
  root File.join(__FILE__, "../../../")
  coverage_dir File.join(__FILE__, "../../coverage")
end

if ENV["CI"]
  require 'simplecov-cobertura'
  SimpleCov.formatter = SimpleCov::Formatter::CoberturaFormatter
end

require "sentry-sidekiq"

DUMMY_DSN = 'http://12345:67890@sentry.localdomain/sentry/42'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before :each do
    # Make sure we reset the env in case something leaks in
    ENV.delete('SENTRY_DSN')
    ENV.delete('SENTRY_CURRENT_ENV')
    ENV.delete('SENTRY_ENVIRONMENT')
    ENV.delete('SENTRY_RELEASE')
    ENV.delete('sidekiq_ENV')
    ENV.delete('RACK_ENV')
  end

  config.before :all do
    Sidekiq.logger = Logger.new(nil)
  end
end

def build_exception
  1 / 0
rescue ZeroDivisionError => e
  e
end

def build_exception_with_cause(cause = "exception a")
  begin
    raise cause
  rescue
    raise "exception b"
  end
rescue RuntimeError => e
  e
end

def build_exception_with_two_causes
  begin
    begin
      raise "exception a"
    rescue
      raise "exception b"
    end
  rescue
    raise "exception c"
  end
rescue RuntimeError => e
  e
end

def build_exception_with_recursive_cause
  backtrace = []

  exception = double("Exception")
  allow(exception).to receive(:cause).and_return(exception)
  allow(exception).to receive(:message).and_return("example")
  allow(exception).to receive(:backtrace).and_return(backtrace)
  exception
end

class HappyWorker
  include Sidekiq::Worker

  def perform
    crumb = Sentry::Breadcrumb.new(message: "I'm happy!")
    Sentry.add_breadcrumb(crumb)
    Sentry.set_tags mood: 'happy'
  end
end

class SadWorker
  include Sidekiq::Worker

  def perform
    crumb = Sentry::Breadcrumb.new(message: "I'm sad!")
    Sentry.add_breadcrumb(crumb)
    Sentry.set_tags :mood => 'sad'

    raise "I'm sad!"
  end
end

class VerySadWorker
  include Sidekiq::Worker

  def perform
    crumb = Sentry::Breadcrumb.new(message: "I'm very sad!")
    Sentry.add_breadcrumb(crumb)
    Sentry.set_tags :mood => 'very sad'

    raise "I'm very sad!"
  end
end

class ReportingWorker
  include Sidekiq::Worker

  def perform
    Sentry.capture_message("I have something to say!")
  end
end

class RetryWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1

  def perform
    1/0
  end
end

class ZeroRetryWorker
  include Sidekiq::Worker

  sidekiq_options retry: 0

  def perform
    1/0
  end
end

class TagsWorker
  include Sidekiq::Worker

  sidekiq_options tags: ["marvel", "dc"]

  def perform; end
end

def execute_worker(processor, klass, **options)
  klass_options = klass.sidekiq_options_hash || {}

  # for Ruby < 2.6
  klass_options.each do |k, v|
    options[k.to_sym] = v
  end

  msg = Sidekiq.dump_json(jid: "123123", class: klass, args: [], **options)
  work = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', msg)
  process_work(processor, work)
end

def process_work(processor, work)
  processor.send(:process, work)
rescue StandardError
  # do nothing
end

def perform_basic_setup
  Sentry.init do |config|
    config.dsn = DUMMY_DSN
    config.logger = ::Logger.new(nil)
    config.background_worker_threads = 0
    config.transport.transport_class = Sentry::DummyTransport
    yield config if block_given?
  end
end
