# frozen_string_literal: true

require 'json'

# Главный страховочный спек. reference/data/providers.json остаётся
# пристинным (валидатор организаторов считает допуск по нему).
# data/providers.json — наш расширенный снапшот: та же основа плюс
# volume_share_pct/daily_turnover_min/daily_turnover_max и
# requests_per_minute_limit.
# Если наш снапшот разъедется со снапшотом организаторов по hard-полю,
# eligible_providers валидатора и наш допуск начнут расходиться молча.
# rubocop:disable RSpec/DescribeClass -- сравниваются два файла снапшотов, а не класс
# rubocop:disable RSpec/ExampleLength -- проход по всем провайдерам и полям — один сценарий
RSpec.describe 'паритет data/providers.json со снапшотом организаторов' do
  let(:ours) { JSON.parse(File.read(File.expand_path('../../data/providers.json', __dir__))) }
  let(:reference) { JSON.parse(File.read(reference_path('providers.json'))) }
  let(:ours_providers) { ours.fetch('providers') }
  let(:reference_providers) { reference.fetch('providers') }

  # Дословно поля, которые читает eligible_providers из reference/scripts/validate_10.rb.
  let(:hard_fields) do
    %w[
      status traffic_percentage limit_amount_min limit_amount_max
      daily_amount_limit daily_approved_amount
      in_progress_count_limit in_progress_count
      in_progress_amount_limit in_progress_amount
      available_requisites provider_margin_pct merchant_margin_pct
      allow_negative_agreement banks exclude_banks
    ]
  end

  it 'состав и порядок payment_system совпадают' do
    expect(ours_providers.map { |p| p['payment_system'] })
      .to eq(reference_providers.map { |p| p['payment_system'] })
  end

  it 'совпадает по всем hard-полям, которые читает eligible_providers валидатора' do
    reference_providers.each_with_index do |ref_provider, index|
      our_provider = ours_providers[index]

      hard_fields.each do |field|
        message = "#{ref_provider['payment_system']}.#{field}: " \
                  "#{our_provider[field].inspect} != #{ref_provider[field].inspect}"
        expect(our_provider[field]).to eq(ref_provider[field]), message
      end
    end
  end

  it 'множество различий ключей равно ровно набору добавленных полей' do
    added_fields = %w[volume_share_pct daily_turnover_min daily_turnover_max
                      requests_per_minute_limit]

    reference_providers.each_with_index do |ref_provider, index|
      our_provider = ours_providers[index]
      diff = (our_provider.keys - ref_provider.keys) | (ref_provider.keys - our_provider.keys)

      expect(diff.sort).to eq(added_fields.sort)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
