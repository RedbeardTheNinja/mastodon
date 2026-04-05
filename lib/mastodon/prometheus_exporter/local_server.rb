# frozen_string_literal: true

require 'prometheus_exporter/server'
require 'prometheus_exporter/client'

module Mastodon::PrometheusExporter
  module LocalServer
    mattr_accessor :bind, :port

    # Collectors registered here are added to the embedded server during setup!
    # Call this from initializers before Puma forks / Sidekiq starts.
    def self.register_collector(collector)
      pending_collectors << collector
    end

    def self.setup!
      server = PrometheusExporter::Server::WebServer.new(bind:, port:)
      pending_collectors.each { |c| server.collector.register_collector(c) }
      server.start

      # wire up a default local client
      PrometheusExporter::Client.default = PrometheusExporter::LocalClient.new(collector: server.collector)
    end

    def self.pending_collectors
      @pending_collectors ||= []
    end
    private_class_method :pending_collectors
  end
end
