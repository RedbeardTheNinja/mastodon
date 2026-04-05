# frozen_string_literal: true

class MigrateNewToMeToCustomFeeds < ActiveRecord::Migration[7.2]
  NTM_TITLE = 'New To Me'

  NTM_STEPS = [
    { phase: 'source',            step_type: 'followed_posts',   position: 0 },
    { phase: 'filter',            step_type: 'interacted_posts', position: 0 },
    { phase: 'removal_strategy',  step_type: 'on_interaction',   position: 0 },
    { phase: 'overflow_strategy', step_type: 'oldest_first',     position: 0 },
  ].freeze

  def up
    ntm_lists = exec_query(
      "SELECT id, account_id FROM lists WHERE title = #{quote(NTM_TITLE)}"
    )

    ntm_lists.each do |row|
      list_id    = row['id']
      account_id = row['account_id']

      # Skip if a config already exists for this list
      existing = exec_query(
        "SELECT id FROM custom_feed_configs WHERE list_id = #{list_id} LIMIT 1"
      )
      next if existing.any?

      now = quoted_date(Time.current)

      exec_insert(
        'INSERT INTO custom_feed_configs (account_id, list_id, enabled, created_at, updated_at) ' \
        "VALUES (#{account_id}, #{list_id}, TRUE, #{now}, #{now})",
        'MigrateNTM insert config'
      )

      config_id = exec_query('SELECT lastval()').first['lastval'].to_i

      NTM_STEPS.each do |step|
        exec_insert(
          'INSERT INTO custom_feed_steps ' \
          '(custom_feed_config_id, phase, step_type, options, position, created_at, updated_at) ' \
          "VALUES (#{config_id}, #{quote(step[:phase])}, #{quote(step[:step_type])}, '{}', #{step[:position]}, #{now}, #{now})",
          'MigrateNTM insert step'
        )
      end
    end
  end

  def down
    ntm_lists = exec_query(
      "SELECT id FROM lists WHERE title = #{quote(NTM_TITLE)}"
    )
    list_ids = ntm_lists.pluck('id')
    return if list_ids.empty?

    config_ids = exec_query(
      "SELECT id FROM custom_feed_configs WHERE list_id IN (#{list_ids.join(',')})"
    ).pluck('id')
    return if config_ids.empty?

    execute("DELETE FROM custom_feed_steps WHERE custom_feed_config_id IN (#{config_ids.join(',')})")
    execute("DELETE FROM custom_feed_configs WHERE id IN (#{config_ids.join(',')})")
  end

  private

  def quoted_date(time)
    "'#{time.utc.strftime('%Y-%m-%d %H:%M:%S')}'"
  end
end
