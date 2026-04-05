# frozen_string_literal: true

namespace :custom_feeds do
  desc 'Seed NSFW custom feed for the admin account'
  task seed_nsfw: :environment do
    admin = Account.find_by(username: 'admin') || Account.first
    abort 'No account found' unless admin

    list = admin.owned_lists.find_or_create_by!(title: 'NSFW')

    config = CustomFeedConfig.find_or_initialize_by(account: admin, list: list)
    config.enabled = true
    config.pull_cadence_minutes = 30
    config.save!

    # remote_tag_timeline singleton covering mastodon.social and mastodon.art
    source_step = CustomFeedStep.find_or_initialize_by(
      custom_feed_config: config,
      phase: 'source',
      step_type: 'remote_tag_timeline'
    )
    source_step.position = 0
    source_step.options = {
      'sources' => [
        { 'domain' => 'mastodon.social', 'tag' => 'nsfw' },
        { 'domain' => 'mastodon.art', 'tag' => 'nsfw' },
      ],
      'limit_per_run' => 40,
    }
    source_step.save!

    # Remove posts once the user interacts with them
    removal_step = CustomFeedStep.find_or_initialize_by(
      custom_feed_config: config,
      phase: 'removal_strategy',
      step_type: 'on_interaction'
    )
    removal_step.position = 0
    removal_step.options = {}
    removal_step.save!

    # Overflow: remove oldest posts first
    overflow_step = CustomFeedStep.find_or_initialize_by(
      custom_feed_config: config,
      phase: 'overflow_strategy',
      step_type: 'oldest_first'
    )
    overflow_step.position = 0
    overflow_step.options = {}
    overflow_step.save!

    puts "NSFW feed seeded for @#{admin.username}:"
    puts "  List     ##{list.id} '#{list.title}'"
    puts "  Config   ##{config.id} (cadence: #{config.pull_cadence_minutes}m)"
    puts '  Sources  mastodon.social#nsfw + mastodon.art#nsfw'
  end
end
