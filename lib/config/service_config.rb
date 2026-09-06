# frozen_string_literal: true

require 'yaml'
require_relative 'errors'

module Config
  # Настройки HTTP-сервиса (порт, SQLite, retention). Отдельно от
  # RoutingConfig: domain vs operational. Читает bin/serve на старте.
  ServiceConfig = Data.define(
    :port, :db_path, :retention_hours, :swagger_path, :openapi_path, :history_path,
    :dashboard_path
  ) do
    def retention_seconds
      retention_hours * 3600
    end
  end

  module ServiceConfigLoader
    DEFAULTS = {
      'port' => 4567,
      'db_path' => './data/decisions.db',
      'retention_hours' => 24,
      'swagger_path' => './public/swagger',
      'openapi_path' => './docs/openapi.yaml',
      'history_path' => './reference/data/operations_history.csv',
      'dashboard_path' => './dashboard'
    }.freeze

    def self.load(path)
      raw = read_yaml!(path)
      section = raw.fetch('service', {}) || {}
      merged = DEFAULTS.merge(section)
      build(merged)
    end

    def self.build(merged)
      ServiceConfig.new(
        port: Integer(merged.fetch('port')),
        db_path: merged.fetch('db_path'),
        retention_hours: Integer(merged.fetch('retention_hours')),
        swagger_path: merged.fetch('swagger_path'),
        openapi_path: merged.fetch('openapi_path'),
        history_path: merged.fetch('history_path'),
        dashboard_path: merged.fetch('dashboard_path')
      )
    end

    def self.read_yaml!(path)
      YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    rescue Errno::ENOENT
      raise SchemaError, "Файл сервиса не найден: #{path}"
    rescue Psych::SyntaxError => e
      raise SchemaError, "Битый YAML в файле сервиса #{path}: #{e.message}"
    end
  end
end
