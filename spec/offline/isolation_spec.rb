# frozen_string_literal: true

require 'offline/objective'

# Замер: полный CLI-прогон queue_100 на рабочем окружении занял 0.34 с (лимит 5 с).
# rubocop:disable-next RSpec/SpecFilePathFormat
RSpec.describe Offline do
  it 'не упоминается в routing и execution' do
    files = Dir['lib/routing/**/*.rb', 'lib/execution/**/*.rb']

    mentions = files.select { |path| File.read(path).include?('Offline') }

    expect(mentions).to be_empty
  end
end
