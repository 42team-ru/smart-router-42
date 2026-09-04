# frozen_string_literal: true

module Config
  # Наследник RuntimeError, а не StandardError: bin/route уже ловит RuntimeError
  # от загрузчиков (lib/io/*_loader.rb) через `rescue RuntimeError => e;
  # fail_with(e.message)`. Тот же rescue подхватит и ошибки схемы конфига без правок.
  class SchemaError < RuntimeError; end
end
