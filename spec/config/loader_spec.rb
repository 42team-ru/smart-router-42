# frozen_string_literal: true

require 'config/loader'

# rubocop:disable RSpec/MultipleExpectations -- каждый пример проверяет несколько
# связанных полей одного и того же загруженного конфига, дробить их — терять контекст
RSpec.describe Config::Loader do
  describe '.load с валидным конфигом' do
    subject(:config) { described_class.load(fixture_path('config', 'valid.yml')) }

    it 'возвращает Config::RoutingConfig с полями файла' do
      expect(config).to be_a(Config::RoutingConfig)
      expect(config.strategy).to eq('count_share')
      expect(config.layers).to eq(%w[conversion load])
      expect(config.fallback_provider).to eq('spacepayments')
    end

    it 'сохраняет вложенные секции как есть' do
      expect(config.rate_limits).to eq('vipay' => 7)
      expect(config.obligations).to eq('payflow' => { 'daily_turnover_min' => 2_000_000 })
      expect(config.amount_ranges.first).to include('from' => 500, 'prefer' => 'payflow')
    end
  end

  describe '.load с минимальным конфигом' do
    subject(:config) { described_class.load(fixture_path('config', 'minimal.yml')) }

    it 'подставляет дефолты на отсутствующие опциональные ключи' do
      defaults = [config.layers, config.outcomes,
                  config.amount_ranges, config.obligations, config.rate_limits]

      expect(defaults).to eq([[], {}, [], {}, {}])
    end
  end

  describe '.load с дефолтным config/routing.yml проекта' do
    it 'грузится без ошибок' do
      path = File.join(SPEC_ROOT, '..', 'config', 'routing.yml')

      expect { described_class.load(path) }.not_to raise_error
    end
  end

  describe 'ошибки схемы — всегда Config::SchemaError, никогда NoMethodError' do
    {
      'отсутствующий файл' => 'no/such/routing.yml',
      'битый синтаксис YAML' => fixture_path('config', 'broken_syntax.yml'),
      'неизвестный ключ верхнего уровня' => fixture_path('config', 'unknown_key.yml'),
      'отсутствует обязательный strategy' => fixture_path('config', 'missing_strategy.yml'),
      'layers не список' => fixture_path('config', 'layers_not_array.yml'),
      'amount_ranges без prefer' => fixture_path('config', 'amount_range_missing_prefer.yml'),
      'rate_limits не целое число' => fixture_path('config', 'rate_limit_not_integer.yml')
    }.each do |description, path|
      it "#{description} → SchemaError" do
        expect { described_class.load(path) }.to raise_error(Config::SchemaError)
      end
    end
  end

  it 'сообщение об ошибке называет конкретный неизвестный ключ' do
    expect { described_class.load(fixture_path('config', 'unknown_key.yml')) }
      .to raise_error(Config::SchemaError, /stratgey/)
  end

  it 'сообщение об ошибке называет путь до вложенного поля' do
    expect { described_class.load(fixture_path('config', 'amount_range_missing_prefer.yml')) }
      .to raise_error(Config::SchemaError, /amount_ranges\[0\]\.prefer/)
  end
end
# rubocop:enable RSpec/MultipleExpectations
