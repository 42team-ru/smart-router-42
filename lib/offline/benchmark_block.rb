# frozen_string_literal: true

module Offline
  module BenchmarkBlock
    # rubocop:disable-next Metrics/MethodLength
    def self.build(bound:, ours:, total:, seed: '42', local_search_skipped: false)
      return empty_block if total.zero?

      ratio = competitive_ratio(bound, ours)
      note = base_note(seed)
      note = "#{note}; абсолютный разрыв #{ours.max_deviation_pp} п.п." if ratio.nil?
      if bound.delivered > ours.delivered
        note = "#{note}; эталон доставил на #{bound.delivered - ours.delivered} заявок больше"
      end
      if local_search_skipped
        note = "#{note}; локальный поиск отключён для #{total} операций (порог 500)"
      end

      {
        'offline_bound' => bound.to_block,
        'our_online_result' => ours.to_block,
        'competitive_ratio' => ratio,
        'note' => note
      }
    end

    def self.competitive_ratio(bound, ours)
      return 1.0 if bound.max_deviation_num.zero? && ours.max_deviation_num.zero?
      return nil if bound.max_deviation_num.zero?

      Rational(ours.max_deviation_num, bound.max_deviation_num).to_f.round(2)
    end
    private_class_method :competitive_ratio

    def self.empty_block
      {
        'offline_bound' => nil,
        'our_online_result' => nil,
        'competitive_ratio' => nil,
        'note' => 'очередь пуста, эталон не считался'
      }
    end
    private_class_method :empty_block

    def self.base_note(seed)
      'эталон эвристический: жадный старт и локальные улучшения с учётом порядка очереди, ' \
        'не доказанный оптимум; отклонение меряется от паспортных целей 40/35/25, а не от ' \
        'достижимых, поэтому не совпадает с distribution.deviation_pp; контрфактуалы ' \
        "посчитаны нашим симулятором (seed #{seed}), а не генератором организаторов"
    end
    private_class_method :base_note
  end
end
