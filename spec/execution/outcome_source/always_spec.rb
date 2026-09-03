# frozen_string_literal: true

require 'execution/outcome_source/always_ok'
require 'execution/outcome_source/always_fail'

# rubocop:disable RSpec/MultipleExpectations, RSpec/DescribeClass -- один спек
# для двух парных источников; каждый it повторяет константный ответ дважды,
# чтобы явно показать «на любой попытке одинаково».
RSpec.describe 'Execution::OutcomeSource вырожденные источники' do
  let(:operation) { build_operation }
  let(:provider) { build_provider('vipay') }

  describe Execution::OutcomeSource::AlwaysOk do
    it 'возвращает :approved на любой попытке' do
      source = described_class.new

      expect(source.call(operation, provider, 1)).to eq(:approved)
      expect(source.call(operation, provider, 42)).to eq(:approved)
    end
  end

  describe Execution::OutcomeSource::AlwaysFail do
    it 'возвращает :rejected на любой попытке' do
      source = described_class.new

      expect(source.call(operation, provider, 1)).to eq(:rejected)
      expect(source.call(operation, provider, 42)).to eq(:rejected)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/DescribeClass
