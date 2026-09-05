# frozen_string_literal: true

require 'routing/strategies'

# CFG-3: «новая стратегия = файл + строка в конфиге, без правок ядра».
# Реестр обязан совпадать с каталогом: файл без register и файл-мусор,
# оставшийся после демо, ломают равенство, а не проходят молча.
RSpec.describe Routing::Strategies do
  def strategies_dir = File.expand_path('../../lib/routing/strategies', __dir__)

  def directory_names
    Dir[File.join(strategies_dir, '*.rb')].map { |path| File.basename(path, '.rb') }
                                          .reject { |name| name == 'base' }.sort
  end

  it 'после load_all! реестр точно равен списку файлов каталога минус base' do
    described_class.load_all!

    expect(described_class.known).to eq(directory_names)
  end

  # require идемпотентен, повторной регистрации (ArgumentError «already
  # registered») быть не должно: исключение уронило бы этот пример.
  it 'повторный load_all! не бросает и не меняет реестр' do
    before = described_class.load_all!

    expect(described_class.load_all!).to eq(before)
  end

  it 'реестр содержит все семь стратегий Ф3 плюс round_robin из П3' do
    described_class.load_all!

    expect(described_class.known).to eq(
      %w[amount_range conversion count_share load obligations priority round_robin volume_share]
    )
  end

  it 'load_all! возвращает known' do
    expect(described_class.load_all!).to eq(described_class.known)
  end

  it 'bin/route не требует стратегии поимённо: новая стратегия ядра не касается' do
    source = File.read(File.expand_path('../../bin/route', __dir__))

    expect(source).not_to match(%r{require_relative\s+'\.\./lib/routing/strategies/})
  end

  it 'загружает каталог в отсортированном порядке: Dir.glob сам порядка не гарантирует' do
    source = File.read(File.join(strategies_dir, '..', 'strategies.rb'))

    expect(source).to match(/Dir\[[^\]]+\]\.sort/)
  end
end
