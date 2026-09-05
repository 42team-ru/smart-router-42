# frozen_string_literal: true

require 'yaml'
require_relative 'errors'
require_relative 'schema_validator'
require_relative 'routing_config'

module Config
  # config/routing.yml + загрузчик, валидация схемы.
  #
  # Не подключается в bin/route/Planner — это Routing::Assembly. Loader только
  # парсит YAML, проверяет форму (SchemaValidator) и отдаёт иммутабельный
  # Config::RoutingConfig. Останавливается на первом найденном нарушении —
  # один SchemaError на вызов, как остальные загрузчики в lib/io/.
  module Loader
    OPTIONAL_DEFAULTS = {
      layers: [], goals: {}, strategy_selection: {}, outcomes: {},
      amount_ranges: [], obligations: {}, rate_limits: {}, cascade: {}, comparison: [],
      history_path: DEFAULT_HISTORY_PATH
    }.freeze

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
        fallback_provider: raw['fallback_provider'], **optional_values(raw)
      )
    end

    def self.optional_values(raw)
      OPTIONAL_DEFAULTS.to_h { |key, default| [key, raw[key.to_s] || default.dup] }
    end

    private_class_method :read_yaml!, :build_config, :optional_values
  end
end
