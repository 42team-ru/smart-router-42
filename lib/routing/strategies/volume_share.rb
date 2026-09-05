# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует так, чтобы сойтись к целевым долям по ДЕНЬГАМ.
    #
    # Родная сестра CountShare, но считает не заявки, а рубли. Разница
    # существенная: десять заявок по тысяче и одна на десять тысяч — это
    # одинаковый объём при десятикратной разнице в количестве. Если
    # договорённость с провайдером звучит как «половина оборота», считать штуки
    # бессмысленно.
    #
    # Механика — дефицит объёма: сколько денег провайдер недополучил против
    # своей доли на текущий момент. Формула сравнивает «сколько ему причиталось
    # бы от всего розданного объёма» с «сколько он получил на самом деле»,
    # первым идёт тот, кто отстал сильнее. Всё в целых числах: веса в базисных
    # пунктах, сравнение без единого деления.
    #
    # Целевая доля берётся из volume_share_pct, а если его нет — из общей доли
    # трафика. Отдельное поле нужно потому, что доли по деньгам и по количеству
    # у одного провайдера обычно разные.
    #
    # При равном дефиците побеждает больший вес, при равном весе — имя: порядок
    # обязан быть однозначным при любых входных данных.
    class VolumeShare < Base
      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'volume_share'

      def explain(ranked, _operation, state)
        winner = ranked.first
        winner_text = "#{winner.name} дефицит #{deficit(winner, state)}"
        return "volume_share: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "volume_share: #{winner_text} против #{other.name} #{deficit(other, state)} " \
          "(веса #{weight_bp(winner)}/#{weight_bp(other)} bp)"
      end

      private

      def compare(left, right, state)
        left_deficit = deficit(left, state)
        right_deficit = deficit(right, state)
        return -1 if left_deficit > right_deficit
        return 1 if left_deficit < right_deficit
        return -1 if weight_bp(left) > weight_bp(right)
        return 1 if weight_bp(left) < weight_bp(right)

        left.name <=> right.name
      end

      def deficit(provider, state)
        (weight_bp(provider) * state.total_volume_units) - (10_000 * state.volume_units(provider))
      end

      def weight_bp(provider)
        (provider.volume_share_pct || provider.traffic_percentage).to_i * 100
      end
    end

    register('volume_share', VolumeShare)
  end
end
