# frozen_string_literal: true

require 'tempfile'
require 'config/loader'

# Ключ pending_resolution (переключатель второго прохода bin/route,
# Execution::PendingResolutionPass). Форма и допустимые значения -- как у
# offline_analytics в spec/config/loader_offline_analytics_spec.rb: дефолт
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

  describe 'ключ pending_resolution' do
    it 'подставляет пустой hash, если ключа нет вовсе' do
      config = load_yaml("strategy: count_share\nfallback_provider: spacepayments\n")

      expect(config.pending_resolution).to eq({})
    end

    it 'сохраняет заданный enabled: false как есть' do
      config = load_yaml(<<~YAML)
        strategy: count_share
        fallback_provider: spacepayments
        pending_resolution:
          enabled: false
      YAML

      expect(config.pending_resolution).to eq('enabled' => false)
    end

    it 'сохраняет заданный enabled: true как есть' do
      config = load_yaml(<<~YAML)
        strategy: count_share
        fallback_provider: spacepayments
        pending_resolution:
          enabled: true
      YAML

      expect(config.pending_resolution).to eq('enabled' => true)
    end

    it 'pending_resolution не отображение → SchemaError' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          pending_resolution: [1, 2]
        YAML
      end.to raise_error(Config::SchemaError, /pending_resolution/)
    end

    it 'неизвестный подключ → SchemaError с перечислением допустимых' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          pending_resolution:
            enable: false
        YAML
      end.to raise_error(Config::SchemaError, /pending_resolution.*enable.*enabled/)
    end

    it 'enabled строкой → SchemaError (опечатка не должна тихо включать/выключать проход)' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          pending_resolution:
            enabled: "false"
        YAML
      end.to raise_error(Config::SchemaError, /pending_resolution\.enabled/)
    end

    it 'дефолтный config/routing.yml несёт явный enabled: true' do
      config = described_class.load(File.expand_path('../../config/routing.yml', __dir__))

      expect(config.pending_resolution).to eq('enabled' => true)
    end
  end
end
