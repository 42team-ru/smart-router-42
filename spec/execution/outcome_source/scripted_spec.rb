# frozen_string_literal: true

require 'execution/outcome_source/scripted'

# rubocop:disable RSpec/MultipleExpectations -- одна проверка касается двух пар
# (op_id, provider) из одного скрипта, дробить теряет связь с YAML-фикстурой.
RSpec.describe Execution::OutcomeSource::Scripted do
  let(:vipay) { build_provider('vipay') }
  let(:payflow) { build_provider('payflow') }
  let(:operation) { build_operation(id: 'op_1') }

  describe '.load + #call' do
    it 'загружает YAML и возвращает исход из скрипта' do
      source = described_class.load(fixture_path('outcomes/cascade_reject_then_ok.yml'))

      expect(source.call(operation, vipay, 1)).to eq(:rejected)
      expect(source.call(operation, payflow, 2)).to eq(:approved)
    end
  end

  describe '#call промах ключа' do
    it 'на неизвестной операции — KeyError' do
      source = described_class.new(script: { 'op_1' => { 'vipay' => :approved } })

      expect { source.call(build_operation(id: 'op_999'), vipay, 1) }
        .to raise_error(KeyError, /op_999/)
    end

    it 'на неизвестном провайдере — KeyError с обеими координатами' do
      source = described_class.new(script: { 'op_1' => { 'vipay' => :approved } })

      expect { source.call(operation, payflow, 1) }
        .to raise_error(KeyError, /op_1.*payflow/)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
