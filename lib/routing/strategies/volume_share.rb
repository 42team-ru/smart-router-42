# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует так, чтобы сойтись к целевым долям по деньгам. То же, что
    # CountShare, но считает рубли: десять заявок по тысяче и одна на десять
    # тысяч дают одинаковый объём при десятикратной разнице в количестве.
    #
    # Источник — Deficit Round Robin (см. docs/ARCHITECTURE.md). В DRR размер
    # пакета участвует в решении наравне с накопленным дефицитом, поэтому
    # ранжирование смотрит не на дефицит ДО заявки, а на ошибку долей ПОСЛЕ
    # гипотетического назначения:
    #
    #   error(candidate) = Σ_p | volume_p_после × 10_000 − target_bp_p × total_после |
    #
    # Сумма идёт по кандидатам, дошедшим до стратегии; total_после — уже
    # распределённый объём плюс сумма заявки. Первым идёт кандидат с наименьшей
    # ошибкой. Всё в целых: веса в базисных пунктах, деления в решающем пути нет.
    #
    # Слагаемые провайдеров, не дошедших до стратегии, у всех кандидатов
    # одинаковы и на argmin не влияют, поэтому в explain их нет.
    #
    # Целевая доля — volume_share_pct, при его отсутствии общая доля трафика:
    # доли по деньгам и по количеству у провайдера обычно разные.
    #
    # При равной ошибке побеждает больший вес, при равном весе — имя.
    #
    # Правило минимизирует ошибку текущего шага, а не всей очереди: жадное, а
    # не глобально оптимальное. По теореме Балински — Янга методы наибольших
    # остатков подвержены немонотонностям, от которых свободны дивизорные вроде
    # Сент-Лагю; на коротких очередях это не проявляется.
    class VolumeShare < Base
      def rank(candidates, operation, state)
        errors = errors_after_assignment(candidates, operation, state)
        candidates.sort { |left, right| compare(left, right, errors) }
      end

      def name = 'volume_share'

      def explain(ranked, operation, state)
        errors = errors_after_assignment(ranked, operation, state)
        total_after = state.total_volume_units + operation.amount
        winner = ranked.first
        winner_text = "#{winner.name} ошибка #{format_pp(errors.fetch(winner), total_after)}"
        return "volume_share: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "volume_share: #{winner_text} против #{other.name} #{format_pp(errors.fetch(other),
                                                                       total_after)} " \
          "при заявке #{operation.amount} (веса #{weight_bp(winner)}/#{weight_bp(other)} bp)"
      end

      private

      # Единственное деление в классе, и только здесь — на границе текста для
      # человека; rank и compare работают с целыми «бп × рубль». Оба шага
      # перевода в проценты считаются сразу в десятых п.п., чтобы не потерять
      # десятую долю при целочисленном делении. Округление — вниз, без float.
      def format_pp(error, total_after)
        return '0.0 п.п.' if total_after.zero?

        tenths = (error * 10) / (total_after * 100)
        "#{tenths / 10}.#{tenths % 10} п.п."
      end

      # Ошибка в единицах «базисный пункт × рубль» для каждого кандидата, если
      # отдать ему текущую заявку. Считается один раз на всех, чтобы rank и
      # explain не разъезжались.
      #
      # Меняется только слагаемое самого кандидата, поэтому вместо полного
      # пересчёта снимаем его слагаемое «до» и добавляем «после».
      def errors_after_assignment(candidates, operation, state)
        amount = operation.amount
        total_after = state.total_volume_units + amount
        before = candidates.to_h do |provider|
          [provider, deviation_bp(provider, state, total_after)]
        end
        base_total = before.values.sum

        candidates.to_h do |candidate|
          after = deviation_bp(candidate, state, total_after, extra: amount)
          [candidate, base_total - before.fetch(candidate) + after]
        end
      end

      def deviation_bp(provider, state, total_after, extra: 0)
        volume = state.volume_units(provider) + extra
        ((volume * 10_000) - (weight_bp(provider) * total_after)).abs
      end

      def compare(left, right, errors)
        left_error = errors.fetch(left)
        right_error = errors.fetch(right)
        return -1 if left_error < right_error
        return 1 if left_error > right_error
        return -1 if weight_bp(left) > weight_bp(right)
        return 1 if weight_bp(left) < weight_bp(right)

        left.name <=> right.name
      end

      def weight_bp(provider)
        (provider.volume_share_pct || provider.traffic_percentage).to_i * 100
      end
    end

    register('volume_share', VolumeShare)
  end
end
