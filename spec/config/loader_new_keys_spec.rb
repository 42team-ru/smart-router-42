# frozen_string_literal: true

require 'tempfile'
require 'config/loader'

# rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- YAML в примерах часть контракта.
RSpec.describe Config::Loader do
  def load_yaml(contents)
    Tempfile.create(['routing', '.yml']) do |file|
      file.write(contents)
      file.flush
      return Config::Loader.load(file.path)
    end
  end

  it 'подставляет пустые goals и strategy_selection, если ключей нет' do
    config = load_yaml("strategy: count_share\nfallback_provider: spacepayments\n")

    expect(config.goals).to eq({})
    expect(config.strategy_selection).to eq({})
  end

  it 'сохраняет порог слоя в goals' do
    config = load_yaml(<<~YAML)
      strategy: count_share
      fallback_provider: spacepayments
      goals:
        budget_headroom: { psi_threshold_micro: 100000 }
    YAML

    expect(config.goals).to eq('budget_headroom' => { 'psi_threshold_micro' => 100_000 })
  end

  it 'отклоняет goals-список как ошибку схемы' do
    expect do
      load_yaml("strategy: count_share\nfallback_provider: spacepayments\ngoals: [1, 2]\n")
    end.to raise_error(Config::SchemaError, /goals/)
  end

  describe 'ключ cascade' do
    it 'подставляет пустой hash, если ключа cascade нет вовсе' do
      config = load_yaml("strategy: count_share\nfallback_provider: spacepayments\n")

      expect(config.cascade).to eq({})
    end

    it 'сохраняет заданный cascade как есть (без домысленных подключей)' do
      config = load_yaml(<<~YAML)
        strategy: count_share
        fallback_provider: spacepayments
        cascade:
          on_timeout: continue
      YAML

      expect(config.cascade).to eq('on_timeout' => 'continue')
    end

    it 'принимает обе валидные комбинации exhausted/on_timeout' do
      config = load_yaml(<<~YAML)
        strategy: count_share
        fallback_provider: spacepayments
        cascade:
          exhausted: fallback_provider
          on_timeout: continue
      YAML

      expect(config.cascade).to eq('exhausted' => 'fallback_provider', 'on_timeout' => 'continue')
    end

    it 'неизвестный подключ внутри cascade → SchemaError с перечислением допустимых' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          cascade:
            timeout: stop
        YAML
      end.to raise_error(Config::SchemaError, /cascade.*timeout.*exhausted, on_timeout/)
    end

    it 'значение вне перечисления для exhausted → SchemaError с текстом допустимых' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          cascade:
            exhausted: foo
        YAML
      end.to raise_error(
        Config::SchemaError,
        'cascade.exhausted должен быть одним из: last_candidate, fallback_provider; получено "foo"'
      )
    end

    it 'значение вне перечисления для on_timeout → SchemaError' do
      expect do
        load_yaml(<<~YAML)
          strategy: count_share
          fallback_provider: spacepayments
          cascade:
            on_timeout: sometimes
        YAML
      end.to raise_error(Config::SchemaError,
                         /cascade\.on_timeout должен быть одним из: stop, continue/)
    end

    it 'cascade не отображение → SchemaError' do
      expect do
        load_yaml("strategy: count_share\nfallback_provider: spacepayments\ncascade: [1, 2]\n")
      end.to raise_error(Config::SchemaError, /cascade/)
    end

    it 'существующие config/examples/*.yml без ключа cascade грузятся без изменений' do
      paths = Dir[File.expand_path('../../config/examples/*.yml', __dir__)]
              .reject { |path| File.basename(path) == 'tz_literal.yml' }

      expect(paths).not_to be_empty
      paths.each { |path| expect { described_class.load(path) }.not_to raise_error }
    end

    it 'config/examples/tz_literal.yml (обе альтернативные ветки) грузится без ошибок' do
      path = File.expand_path('../../config/examples/tz_literal.yml', __dir__)
      config = described_class.load(path)

      expect(config.cascade).to eq('exhausted' => 'fallback_provider', 'on_timeout' => 'continue')
    end

    it 'дефолтный config/routing.yml несёт явные дефолты cascade' do
      config = described_class.load(File.expand_path('../../config/routing.yml', __dir__))

      expect(config.cascade).to eq('exhausted' => 'last_candidate', 'on_timeout' => 'stop')
    end
  end
end
