# frozen_string_literal: true

require 'io/history_loader'

RSpec.describe Io::HistoryLoader do
  describe '.load на operations_history.csv' do
    subject(:conversions) { described_class.load(reference_path('operations_history.csv')) }

    it 'калибрует наблюдаемую конверсию approved/всего по провайдеру' do
      expect(conversions).to eq(
        'vipay' => 0.78,
        'quickpay' => 0.675,
        'payflow' => 0.474
      )
    end
  end

  describe '.load с несуществующим файлом' do
    it 'падает с понятным сообщением' do
      expect { described_class.load('no/such/history.csv') }
        .to raise_error(/Файл истории операций не найден/)
    end
  end
end
