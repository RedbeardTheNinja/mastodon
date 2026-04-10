# frozen_string_literal: true

module Recommendations
  class KeybertClient
    ENDPOINT = ENV.fetch('KEYBERT_ENDPOINT', 'http://keybert:8001')

    def self.extract(text, top_n: 10, max_ngram: 3)
      response = HTTP.timeout(5).post(
        "#{ENDPOINT}/extract",
        json: { text: text, top_n: top_n, max_ngram: max_ngram }
      )
      return [] unless response.status.success?

      JSON.parse(response.body.to_s).map { |kw| kw['phrase'] } # rubocop:disable Rails/Pluck
    rescue HTTP::Error, JSON::ParserError
      []
    end
  end
end
