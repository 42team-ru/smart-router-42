# frozen_string_literal: true

# Дубль validate_structure из reference/scripts/validate_10.rb, строки 53-71.
# Сам скрипт подключить нельзя — он выполняет main при загрузке. Логика
# продублирована здесь осознанно (те же поля, те же сообщения об ошибках),
# разбита на две части ради метрик линтера, смысл проверки не меняется.
#
# Вынесено из spec/contracts/fixtures_spec.rb в spec/support, чтобы тем же
# контролем мог пользоваться spec/synthetic/generator_spec.rb — третьей
# копии validate_structure в репозитории не заводим.
def validate_top_level_fields(decision)
  %w[operation_id selected_provider attempts].filter_map do |field|
    "отсутствует поле #{field}" unless decision.key?(field)
  end
end

def validate_attempt_fields(attempt, index)
  errors = %w[provider decision reason].filter_map do |field|
    "attempts[#{index}]: отсутствует #{field}" unless attempt.key?(field)
  end
  unless %w[selected skipped].include?(attempt['decision'])
    errors << "attempts[#{index}]: decision должен быть selected или skipped"
  end
  errors
end

def validate_structure(decision)
  errors = validate_top_level_fields(decision)
  decision['attempts']&.each_with_index do |attempt, i|
    errors.concat(validate_attempt_fields(attempt, i))
  end
  errors
end
