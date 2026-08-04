unless ENV['NO_COVERAGE']
  require 'simplecov'
  # ignore the test directory
  SimpleCov.start do
    add_filter '/test/'
    add_filter '/vendor/'
    add_filter '/config/'
    add_filter '/lib/import/'
    add_filter '/lib/export/'
  end
end

ENV['RAILS_ENV'] ||= 'test'
require File.expand_path('../../config/environment', __FILE__)
require 'rails/test_help'

require 'ndr_dev_support/integration_testing'

require 'pry'
require 'capybara/email'
require 'create_records_helper'
require 'selenium_error_patch'

require_relative 'download_helpers'

# Supporting multiple threads allows assets to be served faster:
Capybara.server = :puma, { Silent: true, Threads: '0:4' }

# When running in parallel, there can be occassional chokes, so this accounts for that.
# This shouldn't slow down tests that are well-written.
Capybara.default_max_wait_time = 10.seconds

Capybara.disable_animation = true

# Devise support for functional / integration test
module ActionDispatch
  class IntegrationTest
    # Ensure functional & integration tests play nicely with devise:
    include Devise::Test::IntegrationHelpers

    # Allow capybara to interact with emails
    include Capybara::Email::DSL
    include ActionMailer::TestHelper

    # Support for testing file downloads
    include DownloadHelpers

    setup do
      clear_headless_session!
      clear_emails
    end

    # Configure ActionMailer url helpers with test server details:
    setup do
      @capybara_server ||= Capybara.current_session.server
      config = { host: @capybara_server.host, port: @capybara_server.port, protocol: 'http://' }
      ActionMailer::Base.default_url_options.merge!(config)
    end

    setup do
      # Trigger a just-in-time recompile, before any integration tests start running,
      # and fail due to waiting. Returns immediately on subsequent calls.
      Webpacker.compile
    end

    teardown { Capybara.reset_sessions! }

    # Ensure that tests do not leave extra windows open, polluting other tests.
    teardown do
      raise "Error: test left extra windows open: windows.count = #{windows.count}" if windows.count > 1
    end

    # Run tests with TESTS_RAISE_IF_AJAX=1 to identify potentially brittle integration tests.
    # This also enables verbose console logging of the capybara methods called.
    if /\A(1|y(es)?|t(rue)?)\z/i.match?(ENV.fetch('TESTS_RAISE_IF_AJAX', nil))
      %i[accept_confirm assert_no_text assert_text click_button choose click_link click_on
         dismiss_confirm fill_in find find_button find_by_id find_new has_link? select visit
         within within_fieldset].each do |method_name|
        define_method(method_name) do |*args, **kwargs, &block|
          puts format('Before %<method_name>s(%<args>s)',
                      method_name: method_name,
                      args: (args.collect(&:inspect) +
                             [("**#{kwargs.inspect}" unless kwargs.empty?)].compact).join(', '))
          if ajax_active?
            wait_for_ajax # Allow AJAX to complete before teardown error handling happens
            raise "Error: Should wait_for_ajax before calling #{method_name}"
          end
          super(*args, **kwargs, &block)
        end
      end
    end

    def ajax_active?
      page.evaluate_script("(typeof jQuery !== 'undefined') && (jQuery.active > 0)")
    rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError
      false # AJAX might be active, but we can't tell when a modal is open
    end

    # Manually wait for AJAX requests in integration tests, for clarity.
    def wait_for_ajax
      started_waiting_at = Time.current

      while ajax_active?
        break if (Time.current - started_waiting_at) > Capybara.default_max_wait_time

        sleep 0.01
      end
    end

    # Prevent capybara assert_... methods from erroneously triggering
    # 'Test is missing assertions' warnings in Rails 7.2
    %i[assert_current_path assert_no_selector assert_no_text assert_selector assert_text].each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        result = super(*args, **kwargs, &block)
        assert true, 'Assertion passed'
        result
      end
    end

    # In the integration test environment, rather than trying to share a connection
    # (and thus transaction) between the test process and the tested process, use
    # the database_cleaner gem. This avoids non-deterministic failures seen with
    # the former approach, and should probably be moved upstream into ndr_dev_support.
    # self.use_transactional_tests = false
    # setup { DatabaseCleaner.start }
    # teardown { DatabaseCleaner.clean }

    def fill_in_team_data
      fill_in 'team_name', with: 'Test Team'
      select 'Directorate 1', from: 'team_directorate_id'
      select 'Division 1 from directorate 1', from: 'team_division_id'

      fill_in 'team_notes', with: 'Some interesting notes about this project'
    end

    # Use to pre-fill http_basic credentials:
    def use_basic_auth(user)
      otpw = user.yubikey ? user.yubikey + 'ginlcnfebblntbitntgctrvgihirrlfc' : ''

      # Simulate HTTP_BASIC credentials being supplied:
      ApplicationController.any_instance.stubs(
        http_basic_username: user.username,
        http_basic_otpw:     otpw
      )
    end
  end
end

def bootstrap_download_helper
  DownloadHelpers.create_directory

  chrome = Capybara.drivers[:chrome]
  Capybara.register_driver(:chrome) do |app|
    chrome.call(app).tap do |driver|
      driver.browser.download_path = DownloadHelpers.directory
    end
  end

  Capybara.register_driver :chrome_headless do |app|
    Capybara::Selenium::Driver.load_selenium
    browser_options = ::Selenium::WebDriver::Chrome::Options.new.tap do |opts|
      opts.args << '--headless'
      opts.args << '--disable-gpu' if Gem.win_platform?
      opts.args << '--no-sandbox'
      # Workaround https://bugs.chromium.org/p/chromedriver/issues/detail?id=2650&q=load&sort=-id&colspec=ID%20Status%20Pri%20Owner%20Summary
      opts.args << '--disable-site-isolation-trials'
      opts.args << '--window-size=1920,1080'
      opts.args << '--enable-features=NetworkService,NetworkServiceInProcess'
    end

    # Chrome >= 77
    # cf. https://github.com/renuo/so_many_devices/blob/main/lib/so_many_devices.rb
    browser_options.add_preference(:download, prompt_for_download: false,
                                              default_directory: DownloadHelpers.directory.to_s)
    browser_options.add_preference(:browser, set_download_behavior: { behavior: 'allow' })

    Capybara::Selenium::Driver.new(app, browser: :chrome, options: browser_options)
  end
end

# Bootstrap for the single process case:
bootstrap_download_helper

module ActiveSupport
  class TestCase
    # Something about MBIS doesn't like parallel testing. Very noticeable on the CI
    # platform, occassionally also developing locally. For now, will disable parallel
    # testing unless the `PARALLEL_WORKERS` variable is explicitly set.
    parallelize(workers: :number_of_processors)

    # Re-bootstrap for the multi process case:
    parallelize_setup do
      DownloadHelpers.remove_directory
      DownloadHelpers.create_directory

      bootstrap_download_helper
    end

    parallelize_teardown do
      DownloadHelpers.remove_directory
    end

    # Required for testing when using devise
    # include Devise::Test::ControllerHelpers

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
    include CreateRecordsHelper

    def login_and_accept_terms(user)
      sign_in user
      visit terms_and_conditions_path
      assert_text user.email
      return if page.has_text?('Terms and Conditions have been accepted')

      click_on 'Accept'
      assert_text /Welcome to Data Management System|Projects Dashboard/
    end

    def within_row(text)
      within :xpath, "//table//tr[td[contains(.,\"#{text}\")]]" do
        yield
      end
    end

    require 'mocha/minitest'
  end
end

def empty_schema(output)
  schema = ::Builder::XmlMarkup.new(target: output, indent: 2)
  schema.instruct!
  schema
end

# Add Germline test helper common methods.
module GermlineImportTestHelper
  def build_raw_record(options = {})
    default_options = {
      'pseudo_id1' => '',
      'pseudo_id2' => '',
      'encrypted_demog' => '',
      'clinical.to_json' => clinical_json,
      'encrypted_rawtext_demog' => '',
      'rawtext_clinical.to_json' => rawtext_clinical_json
    }

    Import::Germline::RawRecord.new(default_options.merge!(options))
  end
end

# Adds some PaperTrail based helpers and assertions.
module PaperTrailHelper
  # Allow auditing to be temporarily enabled for a test case.
  def with_versioning
    was_enabled = PaperTrail.enabled?
    was_enabled_for_controller = PaperTrail.request.enabled?
    PaperTrail.enabled = true
    PaperTrail.request.enabled = true
    begin
      yield
    ensure
      PaperTrail.enabled = was_enabled
      PaperTrail.request.enabled = was_enabled_for_controller
    end
  end

  # Asserts that PaperTrail is enabled on `object`
  def assert_auditable(object, message = nil)
    klass = object.is_a?(Class) ? object : object.class
    message ||= "PaperTrail disabled for #{klass}"
    assert PaperTrail.request.enabled_for_model?(klass), message
  end

  # Inverse of assert_auditable
  def refute_auditable(object, message = nil)
    klass = object.is_a?(Class) ? object : object.class
    message ||= "PaperTrail enabled for #{klass}"
    refute PaperTrail.request.enabled_for_model?(klass), message
  end
end

module NdrDevSupport
  module IntegrationTesting
    module DSL
      def close_modal(selector: '#modal')
        within(selector) do
          find('*[data-dismiss="modal"]').click
        end
      end
    end
  end
end

module ActionMailerHelper
  # Override :assert_enqueued_email_with to be aware of our own mailer config injection
  # (see ApplicationMailer), for convenience.
  def assert_enqueued_email_with(mailer, method, params: nil, queue: 'default', &block)
    params.merge!(url_options: ActionMailer::Base.default_url_options) if params.is_a?(Hash)

    super
  end

  # Inverse of :assert_enqueued_email_with. Not present in Rails (<= 6.1.7.3).
  def refute_enqueued_email_with(mailer, method, args: nil, queue: 'default', &block)
    args =
      if args.is_a?(Hash)
        args.merge!(url_options: ActionMailer::Base.default_url_options)
        [mailer.to_s, method.to_s, 'deliver_now', { params: args, args: [] }]
      else
        [mailer.to_s, method.to_s, 'deliver_now', { args: Array(args) }]
      end

    refute_enqueued_with(job: mailer.delivery_job, args: args, queue: queue, &block)
  end

  # Inverse of :assert_enqueued_with from ActiveJob::TestHelper. Not present in Rails (<= 6.1.7.3).
  def refute_enqueued_with(job: nil, args: nil, at: nil, queue: nil)
    expected = { job: job, args: args, at: at, queue: queue }.compact
    expected_args = prepare_args_for_assertion(expected)

    if block_given?
      original_enqueued_jobs_count = enqueued_jobs.count

      yield

      jobs = enqueued_jobs.drop(original_enqueued_jobs_count)
    else
      jobs = enqueued_jobs
    end

    matching_job = jobs.find do |enqueued_job|
      deserialized_job = deserialize_args_for_assertion(enqueued_job)

      expected_args.all? do |key, value|
        if value.respond_to?(:call)
          value.call(deserialized_job[key])
        else
          value == deserialized_job[key]
        end
      end
    end

    refute matching_job, "Enqueued job found with #{expected}"
    instantiate_job(matching_job) if matching_job
  end
end

require 'integration_test_helper'
ActionDispatch::IntegrationTest.include(IntegrationTestHelper)

ActiveSupport::TestCase.include(PaperTrailHelper)
ActiveSupport::TestCase.include(GermlineImportTestHelper)

ActionDispatch::IntegrationTest.include(PaperTrailHelper)
ActionDispatch::IntegrationTest.include(ActionMailerHelper)
ActionMailer::TestCase.include(ActionMailerHelper)

# Ensure NdrUi::Bootstrap helper methods are available in helper tests.
ActionView::TestCase.helper NdrUi::BootstrapHelper
