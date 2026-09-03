# frozen_string_literal: true

require 'json'
require_relative '../domain/provider'

module Io
  # IO-1: загрузчик снимка провайдеров из providers.json.
  #
  # null в любом лимите остаётся nil — Domain::Provider трактует это как
  # «ограничения нет». spacepayments грузится тем же кодом, что и остальные:
  # спецкейсов для self-провайдера здесь нет.
  module ProvidersLoader
    # Порядок полей — как в Domain::Provider. Поля, которых нет в снапшоте
    # организаторов (volume_share_pct, requests_per_minute_limit,
    # daily_turnover_min/max), просто не находятся в raw-хеше и становятся nil.
    FIELDS = %i[
      payment_system status traffic_percentage priority
      limit_amount_min limit_amount_max
      daily_amount_limit daily_approved_amount
      in_progress_count_limit in_progress_count
      in_progress_amount_limit in_progress_amount
      available_requisites conversion_24h avg_latency_sec
      banks exclude_banks
      provider_margin_pct merchant_margin_pct allow_negative_agreement
      volume_share_pct requests_per_minute_limit
      daily_turnover_min daily_turnover_max
    ].freeze

    def self.load(path)
      snapshot = parse(path)
      snapshot.fetch('providers').map { |raw| build_provider(raw) }
    end

    def self.parse(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise "Файл провайдеров не найден: #{path}"
    rescue JSON::ParserError => e
      raise "Битый JSON в файле провайдеров #{path}: #{e.message}"
    end

    def self.build_provider(raw)
      Domain::Provider.new(**FIELDS.to_h { |field| [field, raw[field.to_s]] })
    end
  end
end
