# frozen_string_literal: true

# Migrates remote_tag_timeline steps from the old paired sources format:
#   { "sources" => [{ "domain" => "...", "tag" => "..." }, ...] }
# to the new separate tags/domains format:
#   { "tags" => [...], "domains" => [...] }
#
# The new format lets users define a list of tags and a list of servers
# independently; the backend fetches all cross-product combinations.
# Unique tags and domains are extracted from the old sources array.
class MigrateRemoteTagTimelineStepOptions < ActiveRecord::Migration[7.2]
  def up
    CustomFeedStep.where(step_type: 'remote_tag_timeline').find_each do |step|
      old_options = step.options
      sources     = Array(old_options['sources'])

      # Skip steps already using the new format.
      next if sources.empty? || old_options.key?('tags') || old_options.key?('domains')

      tags    = sources.filter_map { |s| s['tag'].to_s.delete_prefix('#').strip.presence }.uniq
      domains = sources.filter_map { |s| s['domain'].to_s.strip.presence }.uniq

      new_options = old_options.except('sources').merge('tags' => tags, 'domains' => domains)
      step.update_column(:options, new_options)
    end
  end

  def down
    # One-way: the old paired format cannot be reliably reconstructed from the
    # cross-product representation without knowing the original pairings.
  end
end
