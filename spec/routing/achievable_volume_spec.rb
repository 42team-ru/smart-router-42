# frozen_string_literal: true

require 'routing/achievable'

# Routing::Achievable.for_volume -- достижимая доля по объёму (рубли), а не
# по количеству мест. Синтетические края контракта: реальные числа публичной
# очереди проверяет spec/routing/achievable_public_queue_spec.rb.
RSpec.describe Routing::Achievable, '.for_volume' do
  describe 'нижняя граница: singleton-допуск по крупной операции' do
    # a допущен ко всем трём операциям, b -- только к двум мелким. Крупная
    # операция (100_000) допустима только a, и одна она перевешивает
    # паспортные 50%: достижимая доля a обязана уйти выше цели, а не остаться
    # равной ей.
    let(:provider_a) { build_provider('a', traffic_percentage: 50) }
    let(:provider_b) { build_provider('b', traffic_percentage: 50) }
    let(:operations) do
      [build_operation(id: 'op_1', amount: 1_000), build_operation(id: 'op_2', amount: 1_000),
       build_operation(id: 'op_3', amount: 100_000)]
    end
    let(:eligibility) do
      { 'op_1' => %w[a b], 'op_2' => %w[a b], 'op_3' => ['a'] }
    end
    let(:result) do
      described_class.for_volume(operations: operations, providers: [provider_a, provider_b],
                                 eligibility: eligibility)
    end

    it 'достижимая доля a строго больше паспортной цели' do
      expect(result.fetch('a').fetch(:achievable_bp)).to be > 5000
    end

    it 'помечает границу a как :only_option' do
      expect(result.fetch('a').fetch(:bound)).to eq(:only_option)
    end
  end

  describe 'верхняя граница: исчерпанный дневной лимит' do
    # c и d допущены к одним и тем же трём операциям по 1000 -- без лимита
    # доля пропорциональна целям (70/30). У c дневной лимит выбирает только
    # 1000 из 3000 допустимых: достижимая доля обязана уйти ниже 70%.
    let(:provider_c) do
      build_provider('c', traffic_percentage: 70, daily_amount_limit: 1_000,
                          daily_approved_amount: 0)
    end
    let(:provider_d) { build_provider('d', traffic_percentage: 30) }
    let(:operations) do
      [build_operation(id: 'op_1', amount: 1_000), build_operation(id: 'op_2', amount: 1_000),
       build_operation(id: 'op_3', amount: 1_000)]
    end
    let(:eligibility) do
      { 'op_1' => %w[c d], 'op_2' => %w[c d], 'op_3' => %w[c d] }
    end
    let(:result) do
      described_class.for_volume(operations: operations, providers: [provider_c, provider_d],
                                 eligibility: eligibility)
    end

    it 'достижимая доля c ограничена свободным остатком лимита' do
      expect(result.fetch('c').fetch(:achievable_bp)).to be < 7000
    end

    it 'помечает границу c как :money' do
      expect(result.fetch('c').fetch(:bound)).to eq(:money)
    end
  end

  describe 'daily_amount_limit: nil -- ограничения нет' do
    # Если бы nil трактовался как ноль (а не "лимита нет"), headroom ушёл бы
    # в минус, upper обнулился бы, и единственный провайдер получил бы 0%
    # вместо честных 100%.
    let(:provider_e) do
      build_provider('e', traffic_percentage: 100, daily_amount_limit: nil,
                          daily_approved_amount: 999_999_999)
    end
    let(:operation) { build_operation(id: 'op_1', amount: 500) }
    let(:result) do
      described_class.for_volume(operations: [operation], providers: [provider_e],
                                 eligibility: { 'op_1' => ['e'] })
    end

    it 'не обнуляет достижимую долю провайдера' do
      expect(result.fetch('e').fetch(:achievable_bp)).to eq(10_000)
    end
  end

  describe 'пустая очередь' do
    it 'возвращает пустой результат без падения' do
      provider = build_provider('a', traffic_percentage: 100)

      expect(described_class.for_volume(operations: [], providers: [provider],
                                        eligibility: {})).to eq({})
    end
  end
end
