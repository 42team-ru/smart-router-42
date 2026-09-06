# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'time'
require_relative 'gateway'
require_relative 'errors'
require_relative 'validators'

module Api
  # Sinatra-приложение — тонкая обёртка над Gateway. Тут только: разбор JSON,
  # маппинг ошибок в HTTP-статусы (из docs/openapi.yaml), статика swagger и
  # консоли (dashboard/), выдача openapi.yaml. Никакой доменной логики.
  # rubocop:disable-next Metrics/ClassLength -- 18 путей + error-hook, дробить только через новый Rack-mount.
  class App < Sinatra::Base
    set :logging, false
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false
    set :protection, false

    # Статика консоли (dashboard/) раздаётся вручную, а не public_folder:
    # public_folder уже занят Swagger UI, а второй Rack::Static ради четырёх
    # файлов дороже, чем эта таблица.
    DASHBOARD_MIME = {
      '.html' => 'text/html', '.css' => 'text/css',
      '.js' => 'application/javascript', '.json' => 'application/json',
      '.svg' => 'image/svg+xml', '.png' => 'image/png',
      '.ico' => 'image/x-icon', '.woff2' => 'font/woff2'
    }.freeze

    class << self
      attr_accessor :gateway_instance, :service_settings
    end

    def self.configure_with(gateway:, service_config:)
      self.gateway_instance = gateway
      self.service_settings = service_config
      set :public_folder, File.expand_path(service_config.swagger_path)
    end

    helpers do
      def gateway = self.class.gateway_instance
      def service_settings = self.class.service_settings

      def json_body
        request.body.rewind
        raw = request.body.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise Errors::ValidationFailed, "Invalid JSON: #{e.message}"
      end

      def json_response(payload, status_code = 200)
        content_type :json
        status status_code
        JSON.generate(payload)
      end

      # Путь склеивается из splat, поэтому проверяем, что итог остался внутри
      # каталога консоли: ../../etc/passwd не должен уехать за пределы root.
      def dashboard_file(relative)
        root = File.expand_path(service_settings.dashboard_path)
        path = File.expand_path(File.join(root, relative))
        halt 404, 'Dashboard file not found' unless path.start_with?("#{root}/") && File.file?(path)

        content_type DASHBOARD_MIME.fetch(File.extname(path), 'application/octet-stream')
        File.read(path)
      end

      def report_filter
        {
          since: parse_ts(params['since']),
          until: parse_ts(params['until']),
          merchant: params['merchant'],
          gate: params['gate'],
          provider: params['provider']
        }.compact
      end

      def parse_ts(iso)
        return nil if iso.nil? || iso.empty?

        Time.parse(iso).to_i
      rescue ArgumentError
        raise Errors::ValidationFailed, "Invalid ISO 8601 timestamp: #{iso.inspect}"
      end

      def int_param(name, default:, min: nil, max: nil)
        raw = params[name]
        return default if raw.nil? || raw.empty?

        value = Integer(raw)
        value = min if min && value < min
        value = max if max && value > max
        value
      rescue ArgumentError
        raise Errors::ValidationFailed, "Invalid integer for #{name}: #{raw.inspect}"
      end
    end

    error Errors::ApiError do
      err = env['sinatra.error']
      json_response(err.to_body, err.http_status)
    end

    error StandardError do
      err = env['sinatra.error']
      json_response(
        { 'error' => 'internal_error', 'message' => err.message },
        500
      )
    end

    # ---------- Context ----------

    get '/snapshot' do
      json_response(gateway.current_snapshot)
    end

    post '/snapshot' do
      payload = json_body
      Validators.snapshot!(payload)
      json_response(gateway.load_snapshot(payload))
    end

    get '/config' do
      json_response(gateway.current_config)
    end

    post '/config' do
      payload = json_body
      Validators.config!(payload)
      json_response(gateway.apply_config(payload))
    end

    post '/bootstrap' do
      payload = json_body
      Validators.bootstrap!(payload)
      json_response(gateway.bootstrap(payload))
    end

    post '/reset' do
      json_response(gateway.reset)
    end

    # ---------- Routing ----------

    post '/operations' do
      payload = json_body
      op = Validators.operation!(payload)
      json_response(gateway.route(op))
    end

    post '/operations/batch' do
      payload = json_body
      operations = Validators.operations_batch!(payload)
      json_response(gateway.route_batch(operations))
    end

    # ---------- Analytics ----------

    get '/report' do
      json_response(gateway.report(report_filter))
    end

    get '/decisions' do
      limit = int_param('limit', default: 100, min: 1, max: 500)
      offset = int_param('offset', default: 0, min: 0)
      json_response(gateway.list_decisions(
                      filter: report_filter, limit: limit, offset: offset
                    ))
    end

    get '/state' do
      json_response(gateway.state_snapshot)
    end

    get '/analytics/overview' do
      buckets = int_param('buckets', default: AnalyticsBuilder::DEFAULT_BUCKETS, min: 2, max: 96)
      json_response(gateway.analytics_overview(filter: report_filter, buckets: buckets))
    end

    get '/analytics/decisions' do
      limit = int_param('limit', default: 100, min: 1, max: 500)
      offset = int_param('offset', default: 0, min: 0)
      json_response(gateway.analytics_decisions(
                      filter: report_filter, limit: limit, offset: offset
                    ))
    end

    # ---------- Infrastructure ----------

    get '/health' do
      json_response(gateway.health)
    end

    get '/capabilities' do
      json_response(gateway.capabilities)
    end

    get '/openapi.yaml' do
      path = File.expand_path(service_settings.openapi_path)
      halt 404, 'openapi.yaml not found' unless File.exist?(path)

      content_type 'application/yaml'
      File.read(path)
    end

    get '/console' do
      redirect '/console/'
    end

    get '/console/' do
      dashboard_file('index.html')
    end

    get '/console/*' do
      dashboard_file(params['splat'].first)
    end

    get '/swagger' do
      redirect '/swagger/'
    end

    get '/swagger/' do
      path = File.join(settings.public_folder, 'index.html')
      halt 404, 'Swagger UI not installed (run `make install-swagger-ui`)' unless File.exist?(path)

      content_type 'text/html'
      File.read(path)
    end
  end
end
