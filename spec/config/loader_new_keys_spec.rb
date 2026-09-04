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
end
