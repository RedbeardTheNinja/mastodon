# frozen_string_literal: true

module Recommendations
  module SignalConfig
    CONFIG = YAML.safe_load_file(Rails.root.join('config', 'recommendations.yml')).freeze

    def self.interaction_weight(type) = CONFIG.dig('interaction_weights', type.to_s) || 0.0
    def self.signal_weight(key)       = CONFIG.dig('signal_weights', key.to_s) || 1.0
    def self.scoring(key)             = CONFIG.dig('scoring', key.to_s)
    def self.keybert(key)             = CONFIG.dig('keybert', key.to_s)
  end
end
