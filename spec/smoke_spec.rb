# frozen_string_literal: true

require 'json'

# rubocop:disable RSpec/DescribeClass -- смок-спек проверяет окружение, а не класс
RSpec.describe 'смок-тест окружения' do
  # rubocop:enable RSpec/DescribeClass
  it 'запускается на Ruby не старше 3.3' do
    expect(Gem::Version.new(RUBY_VERSION)).to be >= Gem::Version.new('3.3')
  end

  it 'парсит очередь операций организаторов и находит ровно 10 операций' do
    queue = JSON.parse(File.read(reference_path('operations_queue_10.json')))

    expect(queue.size).to eq(10)
  end

  it 'ставит op_101 первой операцией очереди' do
    queue = JSON.parse(File.read(reference_path('operations_queue_10.json')))

    expect(queue.first.fetch('operation_id')).to eq('op_101')
  end
end
