# frozen_string_literal: true

require 'yaml'
require_relative 'errors'
require_relative 'schema_validator'
require_relative 'routing_config'

module Config
  # CFG-1: config/routing.yml + загрузчик, валидация схемы.
  #
  # Не подключается в bin/route/Planner — это CFG-2 (Вова). Loader только
  # парсит YAML, проверяет форму (SchemaValidator) и отдаёт иммутабельный
  # Config::RoutingConfig. Останавливается на первом найденном нарушении —
  # один SchemaError на вызов, как остальные загрузчики в lib/io/.
  module Loader
    def self.load(path)
      raw = read_yaml!(path)
      SchemaValidator.validate!(raw)
      build_config(raw)
    end

    def self.read_yaml!(path)
      YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    rescue Errno::ENOENT
      raise SchemaError, "Файл конфига не найден: #{path}"
    rescue Psych::SyntaxError => e
      raise SchemaError, "Битый YAML в файле конфига #{path}: #{e.message}"
    rescue Psych::DisallowedClass => e
      raise SchemaError, "Недопустимый тип данных в конфиге #{path}: #{e.message}"
    end

    def self.build_config(raw)
      RoutingConfig.new(
        strategy: raw['strategy'],
        layers: raw['layers'] || [],
        allocator: raw['allocator'] || {},
        outcomes: raw['outcomes'] || {},
        amount_ranges: raw['amount_ranges'] || [],
        obligations: raw['obligations'] || {},
        rate_limits: raw['rate_limits'] || {},
        fallback_provider: raw['fallback_provider']
      )
    end

    private_class_method :read_yaml!, :build_config
  end
end
