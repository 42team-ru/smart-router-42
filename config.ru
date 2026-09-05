# frozen_string_literal: true

# Rack-entrypoint HTTP-сервиса. Поднимается через `bin/serve` (или напрямую
# `bundle exec rackup`). Конфиг: config/service.yml + config/routing.yml.

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'config/loader'
require 'config/service_config'
require 'api/app'
require 'api/gateway'
require 'api/decisions_repo'

service_config = Config::ServiceConfigLoader.load(
  ENV.fetch('SERVICE_CONFIG', './config/service.yml')
)
routing_config = Config::Loader.load(
  ENV.fetch('ROUTING_CONFIG', './config/routing.yml')
)

repo = Api::DecisionsRepo.new(
  path: service_config.db_path,
  retention_seconds: service_config.retention_seconds
)

gateway = Api::Gateway.new(
  service_config: service_config,
  routing_config: routing_config,
  repo: repo
)

Api::App.configure_with(gateway: gateway, service_config: service_config)

run Api::App
