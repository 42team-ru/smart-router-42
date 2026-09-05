# frozen_string_literal: true

require 'tempfile'
require 'config/loader'
require 'routing/layers'
require 'routing/strategies'

# Валидация ключа `comparison`. Реестры стратегий/слоёв должны быть
# загружены явно -- Config::SchemaRules
# грузит их сама (idempotent load_all!), но здесь дублируем перед блоком по
# тому же принципу, что spec/routing/assembly_spec.rb/selector_spec.rb: порядок
# исполнения спеков всего прогона не должен решать исход этого файла.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations -- каждый
# пример собирает YAML-фикстуру и проверяет одно связанное с ней сообщение
# SchemaError; дробить heredoc — терять читаемость сценария.
RSpec.describe Config::Loader do
  before do
    Routing::Strategies.load_all!
    Routing::Layers.load_all!
  end

  def load_yaml(contents)
    Tempfile.create(['routing', '.yml']) do |file|
      file.write(contents)
      file.flush
      return described_class.load(file.path)
    end
  end

  def base(comparison_block = '')
    "strategy: count_share\nfallback_provider: spacepayments\nlayers: []\n#{comparison_block}"
  end

  it 'отсутствующий ключ comparison -- законный вход, дефолт []' do
    config = load_yaml(base)

    expect(config.comparison).to eq([])
  end

  it 'пустой список comparison -- законный вход' do
    config = load_yaml(base("comparison: []\n"))

    expect(config.comparison).to eq([])
  end

  it 'comparison не список -> SchemaError' do
    expect { load_yaml(base("comparison: 1\n")) }
      .to raise_error(Config::SchemaError, /comparison.*списком/)
  end

  it 'загружает список вариантов как есть, со строковыми ключами' do
    config = load_yaml(base(<<~YAML))
      comparison:
        - { name: baseline, strategy: count_share, layers: [] }
        - { name: rr, strategy: round_robin, layers: [] }
    YAML

    expect(config.comparison).to eq(
      [{ 'name' => 'baseline', 'strategy' => 'count_share', 'layers' => [] },
       { 'name' => 'rr', 'strategy' => 'round_robin', 'layers' => [] }]
    )
  end

  it 'элемент не отображение -> SchemaError' do
    expect { load_yaml(base("comparison: [1]\n")) }
      .to raise_error(Config::SchemaError, /comparison\[0\]/)
  end

  it 'отсутствующее или пустое name -> SchemaError' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { strategy: count_share, layers: [] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison\[0\]\.name/)
  end

  it 'неизвестная strategy -> SchemaError с перечислением известных' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { name: baseline, strategy: count_share, layers: [] }
          - { name: bad, strategy: nope, layers: [] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison\[1\]\.strategy.*nope.*count_share/)
  end

  it 'неизвестный слой -> SchemaError с перечислением известных' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { name: baseline, strategy: count_share, layers: [] }
          - { name: bad, strategy: count_share, layers: [nope] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison\[1\]\.layers.*nope/)
  end

  it 'дублирующийся name -> SchemaError' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { name: dup, strategy: count_share, layers: [] }
          - { name: dup, strategy: round_robin, layers: [] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison.*повторяющееся имя.*dup/)
  end

  it 'ни один вариант не совпадает с боевым strategy/layers -> SchemaError' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { name: only_rr, strategy: round_robin, layers: [] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison.*не совпадает/)
  end

  it 'вариант с непустыми слоями не считается baseline для strategy/layers без слоёв' do
    expect do
      load_yaml(base(<<~YAML))
        comparison:
          - { name: with_layers, strategy: count_share, layers: [budget_headroom] }
      YAML
    end.to raise_error(Config::SchemaError, /comparison.*не совпадает/)
  end

  it 'дефолтный config/routing.yml проекта грузится без ошибок и несёт непустой comparison' do
    config = described_class.load(File.expand_path('../../config/routing.yml', __dir__))

    expect(config.comparison).not_to be_empty
    expect(config.comparison.map { |variant| variant['name'] })
      .to include('round_robin', 'count_share')
  end

  it 'существующие config/examples/*.yml без ключа comparison грузятся без изменений' do
    paths = Dir[File.expand_path('../../config/examples/*.yml', __dir__)]

    expect(paths).not_to be_empty
    paths.each { |path| expect { described_class.load(path) }.not_to raise_error }
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
