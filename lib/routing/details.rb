# frozen_string_literal: true

module Routing
  # Единственное место, где живёт текст причин отсева (details). Правило
  # проекта: причина без числа не принимается — каждый метод обязан вернуть
  # строку с конкретным сравнением и хотя бы одной цифрой.
  #
  # Методы чистые: одни и те же аргументы всегда дают одну и ту же строку.
  module Details
    module_function

    # "status suspended != active (1 допустимый статус)"
    def inactive(status)
      "status #{status} != active (1 допустимый статус)"
    end

    # "traffic_percentage 0 == 0"
    def zero_traffic(value)
      "traffic_percentage #{value} == 0"
    end

    # "available_requisites 0 == 0"
    def no_requisites(value)
      "available_requisites #{value} == 0"
    end

    # "800 < limit_amount_min 1000"
    def below_min(amount, min)
      "#{amount} < limit_amount_min #{min}"
    end

    # "150000 > limit_amount_max 100000"
    def above_max(amount, max)
      "#{amount} > limit_amount_max #{max}"
    end

    # "daily_approved_amount 2900000 + 150000 = 3050000 > daily_amount_limit 3000000"
    def sum_over(field, current, delta, limit_field, limit)
      total = current + delta
      "#{field} #{current} + #{delta} = #{total} > #{limit_field} #{limit}"
    end

    # "bank alfa не входит в banks [sberbank, tinkoff, vtb] (3 банка)"
    def bank_not_allowed(bank, banks)
      "bank #{bank} не входит в banks [#{banks.join(', ')}] (#{bank_count(banks.size)})"
    end

    # "bank sberbank входит в exclude_banks [sberbank] (1 банк)"
    def bank_excluded(bank, banks)
      "bank #{bank} входит в exclude_banks [#{banks.join(', ')}] (#{bank_count(banks.size)})"
    end

    # "provider_margin_pct 1.8 > merchant_margin_pct 1.5, allow_negative_agreement false"
    #
    # Хвост "allow_negative_agreement false" — не форматирование третьего
    # аргумента, а константа текста: это сравнение срабатывает только тогда,
    # когда соглашение не разрешает отрицательную маржу, иначе отсева бы не
    # было.
    def negative_margin(provider_pct, merchant_pct)
      "provider_margin_pct #{provider_pct} > merchant_margin_pct #{merchant_pct}, " \
        'allow_negative_agreement false'
    end

    # Склонение слова «банк»: 1 → банк, 2–4 → банка, иначе → банков.
    def bank_count(count)
      word = case count
             when 1
               'банк'
             when 2..4
               'банка'
             else
               'банков'
             end

      "#{count} #{word}"
    end
  end
end
