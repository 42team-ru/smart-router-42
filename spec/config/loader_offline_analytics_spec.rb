# frozen_string_literal: true

require 'tempfile'
require 'config/loader'

# Ключ offline_analytics (порог размера очереди для оракула + сравнения
# конфигураций в bin/route, пакет 4). Форма и допустимые значения -- как у
# cascade/outcomes.smoothing в spec/config/loader_new_keys_spec.rb: дефолт
# подставляется на стороне сборки (bin/route), не здесь -- здесь только схема.
# rubocop:disable-next RSpec/ExampleLength -- YAML в примерах часть контракта.
RSpec.describe Config::Loader do
  def load_yaml(contents)
    Tempfile.create(['routing', '.yml']) do |file|
      file.write(contents)
      file.flush
      return Config::Loader.load(file.path)
    end
  end

  describe 'ключ offline_analytics' do
    it 'подставляет пустой hash, если ключа нет вовсе' do
      config = load_yaml("strategy: count_share\nfallback_provider: spacepayments\n")

      expect(config.offline_analytics).to eq({})
    end

    it 'сохраняет заданный max_operations как есть' do
      config = load_yaml(<<~YAML)
        strategy: count_share
        fallback_provider: spacepayments
        offline_analytics:
          max_operations: 500
      YAML

      expect(config.offline_analytics).to eq('max_operations' => 500)
    end

    it 'offline_analytics не отображение → SchemaError' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          offline_analytics: [1, 2]
        YAML
      end.to raise_error(Config::SchemaError, /offline_analytics/)
    end

    it 'неизвестный подключ → SchemaError с перечислением допустимых' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          offline_analytics:
            max_ops: 500
        YAML
      end.to raise_error(Config::SchemaError, /offline_analytics.*max_ops.*max_operations/)
    end

    it 'max_operations строкой → SchemaError' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          offline_analytics:
            max_operations: "500"
        YAML
      end.to raise_error(Config::SchemaError, /offline_analytics\.max_operations/)
    end

    it 'max_operations: 0 → SchemaError (ноль как отрицательное число)' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          offline_analytics:
            max_operations: 0
        YAML
      end.to raise_error(Config::SchemaError, /offline_analytics\.max_operations/)
    end

    it 'max_operations отрицательным числом → SchemaError' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          offline_analytics:
            max_operations: -1
        YAML
      end.to raise_error(Config::SchemaError, /offline_analytics\.max_operations/)
    end

    it 'дефолтный config/routing.yml несёт явный порог 10000' do
      config = described_class.load(File.expand_path('../../config/routing.yml', __dir__))

      expect(config.offline_analytics).to eq('max_operations' => 10_000)
    end
  end
end
