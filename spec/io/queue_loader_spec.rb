# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'io/queue_loader'
require 'domain/operation'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый сценарий
# готовит временный файл очереди и проверяет связанные утверждения об одном прогоне
# загрузчика, дробить их — терять контекст сценария
RSpec.describe Io::QueueLoader do
  describe '.load на публичной очереди' do
    subject(:result) { described_class.load(reference_path('operations_queue_10.json')) }

    it 'даёт 10 валидных операций без ошибок, в порядке очереди' do
      expect(result.operations.size).to eq(10)
      expect(result.errors).to eq([])
      expect(result.operations).to all(be_a(Domain::Operation))
      expect(result.operations.map(&:operation_id)).to eq(
        (101..110).map { |n| "op_#{n}" }
      )
    end

    it 'card_brand читается как null' do
      expect(result.operations.first.card_brand).to be_nil
    end
  end

  describe '.load на битой очереди' do
    def with_queue_file(entries)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'queue.json')
        File.write(path, JSON.generate(entries))
        yield path
      end
    end

    let(:valid_entry) do
      {
        'operation_id' => 'op_1', 'created_at' => '2026-07-30T09:00:00+03:00',
        'amount' => 1000, 'bank' => 'sberbank', 'card_brand' => nil,
        'payout_requisite' => { 'sbp' => { 'phone' => '79000000000' } }
      }
    end

    it 'отклоняет операцию без обязательного поля и продолжает прогон' do
      broken = valid_entry.except('bank')

      with_queue_file([broken, valid_entry.merge('operation_id' => 'op_2')]) do |path|
        result = described_class.load(path)

        expect(result.operations.map(&:operation_id)).to eq(['op_2'])
        expect(result.errors.first).to include('нет обязательного поля bank')
      end
    end

    it 'отклоняет операцию с amount <= 0' do
      broken = valid_entry.merge('amount' => 0)

      with_queue_file([broken]) do |path|
        result = described_class.load(path)

        expect(result.operations).to eq([])
        expect(result.errors.first).to include('amount')
      end
    end

    it 'на дубле operation_id сохраняет первое решение и пишет предупреждение' do
      dup = valid_entry.merge('amount' => 2000)

      with_queue_file([valid_entry, dup]) do |path|
        result = described_class.load(path)

        expect(result.operations.size).to eq(1)
        expect(result.operations.first.amount).to eq(1000)
        expect(result.errors.first).to include('дубль operation_id op_1')
      end
    end

    it 'на пустой очереди возвращает пустой, но валидный результат' do
      with_queue_file([]) do |path|
        result = described_class.load(path)

        expect(result.operations).to eq([])
        expect(result.errors).to eq([])
      end
    end
  end

  describe '.load с несуществующим файлом' do
    it 'падает с понятным сообщением' do
      expect { described_class.load('no/such/queue.json') }
        .to raise_error(/Файл очереди не найден/)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
