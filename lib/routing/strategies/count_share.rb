# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует так, чтобы сойтись к целевым долям по КОЛИЧЕСТВУ заявок.
    #
    # Боевая стратегия проекта. Задача: если договорено 40/35/25, то по итогам
    # очереди распределение должно быть настолько близко к этим числам,
    # насколько позволяют лимиты и банковские фильтры.
    #
    # Наивное решение — считать текущий процент и отдавать отстающему — плохо
    # работает на коротких очередях: после первой же заявки у одного провайдера
    # 100%, у остальных 0%, и распределение начинает скакать. Здесь используется
    # метод делителей Сент-Лагю, тот же, которым распределяют места в
    # парламентах по голосам: заявку получает провайдер с наибольшим значением
    # вес / (2 × выдано + 1).
    #
    # Знаменатель растёт с каждой полученной заявкой, поэтому провайдер
    # автоматически уступает очередь другим, а вес возвращает его обратно тем
    # быстрее, чем больше его целевая доля. Метод даёт распределение, ближайшее
    # к целевому на каждом шаге, а не только в пределе, — именно это нужно на
    # очереди из десяти заявок.
    #
    # Сравнение — перекрёстным умножением целых, без единого деления: веса
    # хранятся в базисных пунктах, дроби никогда не превращаются в float.
    # При равных значениях побеждает больший вес, при равных весах — имя
    # провайдера, чтобы порядок был однозначным при любых данных.
    #
    # Дальше по коду: Routing::ShareLedger — счётчики выданного, на которые
    # опирается знаменатель; Routing::Achievable — расчёт достижимых долей,
    # от которых меряется отклонение в отчёте; README, раздел про алгоритмы —
    # ссылка на первоисточник метода.
    class CountShare < Base
      def rank(candidates, _operation, state)
        candidates.sort { |left, right| compare(left, right, state) }
      end

      def name = 'count_share'

      def explain(ranked, _operation, state)
        winner = ranked.first
        numerator, denominator = quotient_parts(winner, state)
        winner_text = "#{winner.name} #{numerator}/#{denominator}=#{numerator / denominator}"
        return "count_share: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        other_numerator, other_denominator = quotient_parts(other, state)
        "count_share: #{winner_text} против #{other.name} " \
          "#{other_numerator}/#{other_denominator}=#{other_numerator / other_denominator}"
      end

      private

      def compare(left, right, state)
        left_weight = weight_bp(left)
        right_weight = weight_bp(right)
        left_value = left_weight * divisor(right, state)
        right_value = right_weight * divisor(left, state)
        return -1 if left_value > right_value
        return 1 if left_value < right_value
        return -1 if left_weight > right_weight
        return 1 if left_weight < right_weight

        left.name <=> right.name
      end

      def quotient_parts(provider, state) = [weight_bp(provider), divisor(provider, state)]

      def divisor(provider, state) = (2 * state.count_units(provider)) + 1

      def weight_bp(provider) = provider.traffic_percentage.to_i * 100
    end

    register('count_share', CountShare)
  end
end
