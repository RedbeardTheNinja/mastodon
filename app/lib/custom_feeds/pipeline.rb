# frozen_string_literal: true

module CustomFeeds
  # Wraps a CustomFeedConfig and evaluates its sources, filters, and removal
  # strategies for a given status and account.
  class Pipeline
    # @param [CustomFeedConfig] config
    def initialize(config)
      @algorithmic     = config.feed_type == 'algorithmic'
      @source_entries  = build_entries(config, 'source',           Sources::Base.registry)
      @filter_entries  = build_entries(config, 'filter',           Filters::Base.registry)
      @removal_entries = build_entries(config, 'removal_strategy', RemovalStrategies::Base.registry)

      overflow_step  = config.steps_for('overflow_strategy').first
      overflow_klass = overflow_step ? OverflowStrategies::Base.registry[overflow_step.step_type] : nil
      @overflow = (overflow_klass || OverflowStrategies::OldestFirst).new
    end

    # Returns true if the status should be inserted via the push path.
    # Only push sources are checked — pull sources are ignored here.
    # @param [Status]  status
    # @param [Account] account
    # @return [Boolean]
    def include?(status, account)
      push = @source_entries.reject { |e| e[:klass].pull_source? }
      if push.empty?
        Rails.logger.debug { "Pipeline: no push sources for config, skipping status #{status.id}" }
        return false
      end

      unless push.any? { |e| e[:instance].includes?(status, account, e[:options]) }
        Rails.logger.debug { "Pipeline: status #{status.id} rejected by all push sources" }
        return false
      end

      blocking = @filter_entries.find { |e| e[:instance].exclude?(status, account, e[:options]) }
      if blocking
        Rails.logger.debug { "Pipeline: status #{status.id} excluded by filter #{blocking[:klass].key}" }
        return false
      end

      true
    end

    # Called by PullSourceIngestWorker for candidates already sourced by a pull source.
    # Only runs the filter pipeline — the pull source itself is the gate.
    # @param [Status]  status
    # @param [Account] account
    # @return [Boolean]
    def passes_filters?(status, account)
      blocking = @filter_entries.find { |e| e[:instance].exclude?(status, account, e[:options]) }
      if blocking
        Rails.logger.debug { "Pipeline: status #{status.id} excluded by filter #{blocking[:klass].key}" }
        return false
      end

      true
    end

    # Returns true if this pipeline has at least one pull source step.
    def pull_sources?
      @source_entries.any? { |e| e[:klass].pull_source? }
    end

    # Pull source step entries: [{instance:, klass:, options:, step:}]
    # Used by PullSourceIngestWorker to enumerate buckets and cursors.
    def pull_source_entries
      @source_entries.select { |e| e[:klass].pull_source? }
    end

    # Returns true if the status should be removed from the feed after the given interaction.
    # @param [String] interaction_type 'favourite' | 'reblog' | 'reply'
    # @return [Boolean]
    def remove_on?(interaction_type)
      @removal_entries.any? { |e| e[:instance].remove_on?(interaction_type, e[:options]) }
    end

    # Returns true if this is an algorithmic feed (candidates go to pending queue).
    def algorithmic?
      @algorithmic
    end

    # The resolved overflow strategy (always non-nil; defaults to OldestFirst).
    # @return [CustomFeeds::OverflowStrategies::Base]
    attr_reader :overflow

    private

    # @return [Array<{instance: Object, klass: Class, options: HashWithIndifferentAccess, step: CustomFeedStep}>]
    def build_entries(config, phase, registry)
      config.steps_for(phase).filter_map do |step|
        klass = registry[step.step_type]
        next unless klass

        {
          instance: klass.new,
          klass: klass,
          options: step.options.with_indifferent_access,
          step: step,
        }
      end
    end
  end
end
