# frozen_string_literal: true

require 'reporting/recommendations'
require 'io/history_stats'

RSpec.describe Reporting::Recommendations do
  def history_entry(obs:, approved:, approved_bp:)
    Io::HistoryStats::Entry.new(
      n: obs, approved_count: approved, rejected_count: 0, expired_count: obs - approved,
      approved_bp: approved_bp, rejected_bp: 0, expired_bp: 10_000 - approved_bp
    )
  end

  describe '.build (recommendation по конверсии)' do
    # rubocop:disable-next RSpec/ExampleLength -- провайдер, история и итог собраны в одном примере намеренно.
    it 'показывает число наблюдений и не заявляет больше, чем позволяет маленькая выборка' do
      payflow = build_provider('payflow', conversion_24h: 0.91, daily_amount_limit: nil,
                                          traffic_percentage: nil)
      history = Io::HistoryStats.new(
        entries: { 'payflow' => history_entry(obs: 19, approved: 9, approved_bp: 5510) },
        k: Rational(4_855_626_093, 426_317_971), smoothed: true
      )

      recommendations = described_class.build([], [payflow], history)

      expect(recommendations).to contain_exactly(
        'payflow: conversion_24h заявлена 0.91, по истории 9/19 ' \
        '(сглаженная оценка 0.551, k=11.4) — расхождение существенное, но выборка мала: ' \
        'проверить на большем периоде'
      )
    end

    # rubocop:disable-next RSpec/ExampleLength -- провайдер, история и итог собраны в одном примере намеренно.
    it 'на большой выборке остаётся формулировкой "пересчитать по факту"' do
      vipay = build_provider('vipay', conversion_24h: 0.87, daily_amount_limit: nil,
                                      traffic_percentage: nil)
      history = Io::HistoryStats.new(
        entries: { 'vipay' => history_entry(obs: 1000, approved: 780, approved_bp: 7800) },
        k: 0, smoothed: false
      )

      recommendations = described_class.build([], [vipay], history)

      expect(recommendations).to contain_exactly(
        'vipay: conversion_24h заявлена 0.87, по истории 780/1000 (наблюдаемая 0.78) — ' \
        'пересчитать по факту'
      )
    end

    it 'не предлагает ничего, когда провайдера нет в истории' do
      unknown = build_provider('newpay', conversion_24h: 0.9, daily_amount_limit: nil,
                                         traffic_percentage: nil)
      history = Io::HistoryStats.new(entries: {}, k: 0, smoothed: false)

      expect(described_class.build([], [unknown], history)).to eq([])
    end

    # rubocop:disable-next RSpec/ExampleLength -- провайдер и история собраны в одном примере намеренно.
    it 'молчит, когда паспорт и история согласны в пределах порога' do
      vipay = build_provider('vipay', conversion_24h: 0.76, daily_amount_limit: nil,
                                      traffic_percentage: nil)
      history = Io::HistoryStats.new(
        entries: { 'vipay' => history_entry(obs: 1000, approved: 780, approved_bp: 7800) },
        k: 0, smoothed: false
      )

      expect(described_class.build([], [vipay], history)).to eq([])
    end
  end
end
