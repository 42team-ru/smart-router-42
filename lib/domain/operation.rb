# frozen_string_literal: true

module Domain
  # Одна заявка из очереди. Только чтение, без логики.
  # amount — целое число рублей: вся решающая арифметика целочисленная.
  Operation = Data.define(:operation_id, :created_at, :amount, :bank,
                          :card_brand, :payout_requisite)
end
