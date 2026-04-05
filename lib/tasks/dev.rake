# frozen_string_literal: true

namespace :dev do
  desc 'Populate database with test data. Can be run multiple times. Should not be run in production environments'
  task populate_sample_data: :environment do
    Chewy.strategy(:mastodon) do
      # Create a valid account to showcase multiple post types
      showcase_account = Account.create_with(username: 'showcase_account').find_or_create_by!(id: 10_000_000)
      showcase_user = User.create_with(
        account_id: showcase_account.id,
        agreement: true,
        password: SecureRandom.hex,
        email: ENV.fetch('TEST_DATA_SHOWCASE_EMAIL', 'showcase_account@joinmastodon.org'),
        confirmed_at: Time.now.utc,
        approved: true,
        bypass_registration_checks: true
      ).find_or_create_by!(id: 10_000_000)
      showcase_user.mark_email_as_confirmed!
      showcase_user.approve!

      french_post = Status.create_with(
        text: 'Ceci est un sondage public écrit en Français',
        language: 'fr',
        account: showcase_account,
        visibility: :public,
        poll_attributes: {
          voters_count: 0,
          account: showcase_account,
          expires_at: 1.day.from_now,
          options: ['ceci est un choix', 'ceci est un autre choix'],
          multiple: false,
        }
      ).find_or_create_by!(id: 10_000_000)

      private_mentionless = Status.create_with(
        text: 'This is a private message written in English',
        language: 'en',
        account: showcase_account,
        visibility: :private
      ).find_or_create_by!(id: 10_000_001)

      public_self_reply_with_cw = Status.create_with(
        text: 'This is a public self-reply written in English; it has a CW and a multi-choice poll',
        spoiler_text: 'poll (CW example)',
        language: 'en',
        account: showcase_account,
        visibility: :public,
        thread: french_post,
        poll_attributes: {
          voters_count: 0,
          account: showcase_account,
          expires_at: 1.day.from_now,
          options: ['this is a choice', 'this is another choice', 'you can chose any number of them'],
          multiple: true,
        }
      ).find_or_create_by!(id: 10_000_002)
      ProcessHashtagsService.new.call(public_self_reply_with_cw)

      unlisted_self_reply_with_cw_tag_mention = Status.create_with(
        text: 'This is an unlisted (Quiet Public) self-reply written in #English; it has a CW, mentions @showcase_account, and uses an emoji 🦣',
        spoiler_text: 'CW example',
        language: 'en',
        account: showcase_account,
        visibility: :unlisted,
        thread: public_self_reply_with_cw
      ).find_or_create_by!(id: 10_000_003)
      Mention.find_or_create_by!(status: unlisted_self_reply_with_cw_tag_mention, account: showcase_account)
      ProcessHashtagsService.new.call(unlisted_self_reply_with_cw_tag_mention)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/600x400.png'),
        description: 'Mastodon logo'
      ).find_or_create_by!(id: 10_000_000)
      status_with_media = Status.create_with(
        text: "This is a public status with a picture and tags. The attached picture has an alt text\n\n#Mastodon #Logo #English #Test",
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_004)
      media_attachment.update(status_id: status_with_media.id)
      ProcessHashtagsService.new.call(status_with_media)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/600x400.png'),
        description: 'Mastodon logo'
      ).find_or_create_by!(id: 10_000_001)
      status_with_sensitive_media = Status.create_with(
        text: "This is the same public status with a picture and tags, but it is marked as sensitive. The attached picture has an alt text\n\n#Mastodon #Logo #English #Test",
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public,
        sensitive: true,
        thread: status_with_media
      ).find_or_create_by!(id: 10_000_005)
      media_attachment.update(status_id: status_with_sensitive_media.id)
      ProcessHashtagsService.new.call(status_with_sensitive_media)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/600x400.png'),
        description: 'Mastodon logo'
      ).find_or_create_by!(id: 10_000_002)
      status_with_cw_media = Status.create_with(
        text: "This is the same public status with a picture and tags, but it is behind a CW. The attached picture has an alt text\n\n#Mastodon #Logo #English #Test",
        spoiler_text: 'Mastodon logo',
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public,
        sensitive: true,
        thread: status_with_sensitive_media
      ).find_or_create_by!(id: 10_000_006)
      media_attachment.update(status_id: status_with_cw_media.id)
      ProcessHashtagsService.new.call(status_with_cw_media)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/boop.ogg'),
        description: 'Mastodon boop'
      ).find_or_create_by!(id: 10_000_003)
      status_with_audio = Status.create_with(
        text: "This is the same public status with an audio file and tags. The attached picture has an alt text\n\n#Mastodon #English #Test",
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public,
        thread: status_with_cw_media
      ).find_or_create_by!(id: 10_000_007)
      media_attachment.update(status_id: status_with_audio.id)
      ProcessHashtagsService.new.call(status_with_audio)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/boop.ogg'),
        description: 'Mastodon boop'
      ).find_or_create_by!(id: 10_000_004)
      status_with_sensitive_audio = Status.create_with(
        text: "This is the same public status with an audio file and tags, but it is marked as sensitive. The attached picture has an alt text\n\n#Mastodon #English #Test",
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public,
        sensitive: true,
        thread: status_with_audio
      ).find_or_create_by!(id: 10_000_008)
      media_attachment.update(status_id: status_with_sensitive_audio.id)
      ProcessHashtagsService.new.call(status_with_sensitive_audio)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/boop.ogg'),
        description: 'Mastodon boop'
      ).find_or_create_by!(id: 10_000_005)
      status_with_cw_audio = Status.create_with(
        text: "This is the same public status with an audio file and tags, but it is behind a CW. The attached picture has an alt text\n\n#Mastodon #English #Test",
        spoiler_text: 'Mastodon boop',
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public,
        sensitive: true,
        thread: status_with_sensitive_audio
      ).find_or_create_by!(id: 10_000_009)
      media_attachment.update(status_id: status_with_cw_audio.id)
      ProcessHashtagsService.new.call(status_with_cw_audio)

      media_attachments = [
        MediaAttachment.create_with(
          account: showcase_account,
          file: File.open('spec/fixtures/files/600x400.png'),
          description: 'Mastodon logo'
        ).find_or_create_by!(id: 10_000_006),
        MediaAttachment.create_with(
          account: showcase_account,
          file: File.open('spec/fixtures/files/attachment.jpg')
        ).find_or_create_by!(id: 10_000_007),
        MediaAttachment.create_with(
          account: showcase_account,
          file: File.open('spec/fixtures/files/avatar-high.gif'),
          description: 'Walking cartoon cat'
        ).find_or_create_by!(id: 10_000_008),
        MediaAttachment.create_with(
          account: showcase_account,
          file: File.open('spec/fixtures/files/text.png'),
          description: 'Text saying “Hello Mastodon”'
        ).find_or_create_by!(id: 10_000_009),
      ]
      status_with_multiple_attachments = Status.create_with(
        text: "This is a post with multiple attachments, not all of which have a description\n\n#Mastodon #English #Test",
        spoiler_text: 'multiple attachments',
        ordered_media_attachment_ids: media_attachments.pluck(:id),
        account: showcase_account,
        visibility: :public,
        sensitive: true,
        thread: status_with_cw_audio
      ).find_or_create_by!(id: 10_000_010)
      media_attachments.each { |attachment| attachment.update!(status_id: status_with_multiple_attachments.id) }
      ProcessHashtagsService.new.call(status_with_multiple_attachments)

      remote_account = Account.create_with(
        username: 'fake.example',
        domain: 'example.org',
        uri: 'https://example.org/foo/bar',
        url: 'https://example.org/foo/bar',
        locked: true
      ).find_or_create_by!(id: 10_000_001)

      remote_formatted_post = Status.create_with(
        text: <<~HTML,
          <p>This is a post with a variety of HTML in it</p>
          <p>For instance, <strong>this text is bold</strong> and <b>this one as well</b>, while <del>this text is stricken through</del> and <s>this one as well</s>.</p>
          <blockquote>
            <p>This thing, here, is a block quote<br/>with some <strong>bold</strong> as well</p>
            <ul>
              <li>a list item</li>
              <li>
                and another with
                <ul>
                  <li>nested</li>
                  <li>items!</li>
                </ul>
              </li>
            </ul>
          </blockquote>
          <pre><code>// And this is some code
          // with two lines of comments
          </code></pre>
          <p>And this is <code>inline</code> code</p>
          <p>Finally, please observe this Ruby element: <ruby> 明日 <rp>(</rp><rt>Ashita</rt><rp>)</rp> </ruby></p>
        HTML
        account: remote_account,
        uri: 'https://example.org/foo/bar/baz',
        url: 'https://example.org/foo/bar/baz'
      ).find_or_create_by!(id: 10_000_011)
      Status.create_with(account: showcase_account, reblog: remote_formatted_post).find_or_create_by!(id: 10_000_012)

      unattached_quote_post = Status.create_with(
        text: 'This is a quote of a post that does not exist',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_013)
      Quote.create_with(
        status: unattached_quote_post,
        quoted_status: nil
      ).find_or_create_by!(id: 10_000_000)

      self_quote = Status.create_with(
        text: 'This is a quote of a public self-post',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_014)
      Quote.create_with(
        status: self_quote,
        quoted_status: status_with_media,
        state: :accepted
      ).find_or_create_by!(id: 10_000_001)

      nested_self_quote = Status.create_with(
        text: 'This is a quote of a public self-post which itself is a self-quote',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_015)
      Quote.create_with(
        status: nested_self_quote,
        quoted_status: self_quote,
        state: :accepted
      ).find_or_create_by!(id: 10_000_002)

      recursive_self_quote = Status.create_with(
        text: 'This is a recursive self-quote; no real reason for it to exist, but just to make sure we handle them gracefuly',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_016)
      Quote.create_with(
        status: recursive_self_quote,
        quoted_status: recursive_self_quote,
        state: :accepted
      ).find_or_create_by!(id: 10_000_003)

      self_private_quote = Status.create_with(
        text: 'This is a public post of a private self-post: the quoted post should not be visible to non-followers',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_017)
      Quote.create_with(
        status: self_private_quote,
        quoted_status: private_mentionless,
        state: :accepted
      ).find_or_create_by!(id: 10_000_004)

      uncwed_quote_cwed = Status.create_with(
        text: 'This is a quote without CW of a quoted post that has a CW',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_018)
      Quote.create_with(
        status: uncwed_quote_cwed,
        quoted_status: public_self_reply_with_cw,
        state: :accepted
      ).find_or_create_by!(id: 10_000_005)

      cwed_quote_cwed = Status.create_with(
        text: 'This is a quote with a CW of a quoted post that itself has a CW',
        spoiler_text: 'Quote post with a CW',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_019)
      Quote.create_with(
        status: cwed_quote_cwed,
        quoted_status: public_self_reply_with_cw,
        state: :accepted
      ).find_or_create_by!(id: 10_000_006)

      pending_quote_post = Status.create_with(
        text: 'This quote post is pending',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_020)
      Quote.create_with(
        status: pending_quote_post,
        quoted_status: remote_formatted_post,
        activity_uri: 'https://foo/bar',
        state: :pending
      ).find_or_create_by!(id: 10_000_007)

      rejected_quote_post = Status.create_with(
        text: 'This quote post is rejected',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_021)
      Quote.create_with(
        status: rejected_quote_post,
        quoted_status: remote_formatted_post,
        activity_uri: 'https://foo/foo',
        state: :rejected
      ).find_or_create_by!(id: 10_000_008)

      revoked_quote_post = Status.create_with(
        text: 'This quote post is revoked',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_022)
      Quote.create_with(
        status: revoked_quote_post,
        quoted_status: remote_formatted_post,
        activity_uri: 'https://foo/baz',
        state: :revoked
      ).find_or_create_by!(id: 10_000_009)

      StatusPin.create_with(account: showcase_account, status: public_self_reply_with_cw).find_or_create_by!(id: 10_000_000)
      StatusPin.create_with(account: showcase_account, status: private_mentionless).find_or_create_by!(id: 10_000_001)

      showcase_account.update!(
        display_name: 'Mastodon test/showcase account',
        note: 'Test account to showcase many Mastodon features. Most of its posts are public, but some are private!'
      )

      remote_quote = Status.create_with(
        text: <<~HTML,
          <p>This is a self-quote of a remote formatted post</p>
          <p class="quote-inline">RE: <a href="https://example.org/foo/bar/baz">https://example.org/foo/bar/baz</a></p>
        HTML
        account: remote_account,
        uri: 'https://example.org/foo/bar/quote',
        url: 'https://example.org/foo/bar/quote'
      ).find_or_create_by!(id: 10_000_023)
      Quote.create_with(
        status: remote_quote,
        quoted_status: remote_formatted_post,
        state: :accepted
      ).find_or_create_by!(id: 10_000_010)
      Status.create_with(
        account: showcase_account,
        reblog: remote_quote
      ).find_or_create_by!(id: 10_000_024)

      media_attachment = MediaAttachment.create_with(
        account: showcase_account,
        file: File.open('spec/fixtures/files/attachment.jpg')
      ).find_or_create_by!(id: 10_000_010)
      quote_post_with_media = Status.create_with(
        text: "This is a status with a picture and tags which also quotes a status with a picture.\n\n#Mastodon #Test",
        ordered_media_attachment_ids: [media_attachment.id],
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_025)
      media_attachment.update(status_id: quote_post_with_media.id)
      ProcessHashtagsService.new.call(quote_post_with_media)
      Quote.create_with(
        status: quote_post_with_media,
        quoted_status: status_with_media,
        state: :accepted
      ).find_or_create_by!(id: 10_000_011)

      showcase_sidekick_account = Account.create_with(username: 'showcase_sidekick').find_or_create_by!(id: 10_000_002)
      sidekick_user = User.create_with(
        account_id: showcase_sidekick_account.id,
        agreement: true,
        password: SecureRandom.hex,
        email: ENV.fetch('TEST_DATA_SHOWCASE_SIDEKICK_EMAIL', 'showcase_sidekick@joinmastodon.org'),
        confirmed_at: Time.now.utc,
        approved: true,
        bypass_registration_checks: true
      ).find_or_create_by!(id: 10_000_001)
      sidekick_user.mark_email_as_confirmed!
      sidekick_user.approve!

      sidekick_post = Status.create_with(
        text: 'This post only exists to be quoted.',
        account: showcase_sidekick_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_026)
      sidekick_quote_post = Status.create_with(
        text: 'This is a quote of a different user.',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_027)
      Quote.create_with(
        status: sidekick_quote_post,
        quoted_status: sidekick_post,
        activity_uri: 'https://foo/cross-account-quote',
        state: :accepted
      ).find_or_create_by!(id: 10_000_012)

      quoted = Status.create_with(
        text: 'This should have a preview card: https://joinmastodon.org',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_028)
      LinkCrawlWorker.perform_async(10_000_028)
      quoting = Status.create_with(
        text: 'This should quote a post with a preview card',
        account: showcase_account,
        visibility: :public
      ).find_or_create_by!(id: 10_000_029)
      Quote.create_with(
        status: quoting,
        quoted_status: quoted,
        state: :accepted
      ).find_or_create_by!(id: 10_000_013)

      Status.create_with(
        text: 'This post has a manual quote policy',
        account: remote_account,
        visibility: :public,
        quote_approval_policy: InteractionPolicy::POLICY_FLAGS[:public] << 16
      ).find_or_create_by!(id: 10_000_030)
    end
  end

  desc 'Seed test custom feeds (New To Me + Algorithmic) for the admin account. Safe to run multiple times.'
  task seed_custom_feeds: :environment do
    admin_user = User.find_by(email: 'admin@localhost') || User.admins.first
    abort 'Could not find admin user. Run bin/setup first.' unless admin_user

    admin_account = admin_user.account

    # Keep the admin feed active so signed_in_recently? guards pass
    admin_user.update!(current_sign_in_at: Time.now.utc)

    Chewy.strategy(:mastodon) do
      cf_manager = CustomFeeds::FeedManager.instance

      # -----------------------------------------------------------------------
      # Part 1: Standard "New To Me" feed
      # Filters out posts the admin has already interacted with.
      # Removal strategy: remove on any interaction.
      # -----------------------------------------------------------------------

      ntm_poster = Account.create_with(
        username: 'new_to_me_demo',
        display_name: 'New To Me Demo Account',
        note: 'Posts used to demonstrate the New To Me feed.'
      ).find_or_create_by!(id: 11_000_000)

      ntm_poster_user = User.create_with(
        account_id: ntm_poster.id,
        agreement: true,
        password: SecureRandom.hex,
        email: ENV.fetch('TEST_DATA_NTM_EMAIL', 'new_to_me_demo@localhost'),
        confirmed_at: Time.now.utc,
        approved: true,
        bypass_registration_checks: true
      ).find_or_create_by!(id: 11_000_000)
      ntm_poster_user.mark_email_as_confirmed!
      ntm_poster_user.approve!

      Follow.find_or_create_by!(account: admin_account, target_account: ntm_poster)

      ntm_list = List.create_with(title: 'New To Me').find_or_create_by!(account: admin_account, title: 'New To Me')

      ntm_config = CustomFeedConfig.find_or_create_by!(list: ntm_list, account: admin_account) do |c|
        c.enabled = true
        c.feed_type = 'standard'
      end
      [
        { phase: 'source',            step_type: 'followed_posts',   position: 0, options: {} },
        { phase: 'filter',            step_type: 'interacted_posts', position: 0, options: {} },
        { phase: 'removal_strategy',  step_type: 'on_interaction',   position: 0, options: {} },
        { phase: 'overflow_strategy', step_type: 'oldest_first',     position: 0, options: {} },
      ].each do |attrs|
        CustomFeedStep.find_or_create_by!(
          custom_feed_config: ntm_config, phase: attrs[:phase], step_type: attrs[:step_type]
        ) { |s| s.position = attrs[:position]; s.options = attrs[:options] }
      end
      ListAccount.find_or_create_by!(list: ntm_list, account: ntm_poster)

      plain_post = Status.create_with(
        text: 'This is a plain text post that will appear in your New To Me feed. Try liking it — it should disappear!',
        account: ntm_poster, visibility: :public
      ).find_or_create_by!(id: 11_000_000)

      tagged_post = Status.create_with(
        text: 'This post has hashtags. #NewToMe #Mastodon #FediDev',
        account: ntm_poster, visibility: :public
      ).find_or_create_by!(id: 11_000_001)
      ProcessHashtagsService.new.call(tagged_post)

      cw_post = Status.create_with(
        text: 'The content behind this CW is perfectly safe.',
        spoiler_text: 'New To Me feed test — click to expand',
        account: ntm_poster, visibility: :public
      ).find_or_create_by!(id: 11_000_002)

      unlisted_post = Status.create_with(
        text: 'Unlisted post — still eligible for New To Me.',
        account: ntm_poster, visibility: :unlisted
      ).find_or_create_by!(id: 11_000_003)

      [plain_post, tagged_post, cw_post, unlisted_post].each { |s| cf_manager.push(ntm_config, s) }

      ntm_size = RedisConnection.with { |r| r.zcard(cf_manager.key(ntm_list.id)) }
      puts "\n=== New To Me (standard feed) ==="
      puts "  List     ##{ntm_list.id} '#{ntm_list.title}'"
      puts "  Config   ##{ntm_config.id}"
      puts "  Feed     #{ntm_size} posts in Redis"
      puts "  URL      http://localhost:3000/lists/#{ntm_list.id}"

      # -----------------------------------------------------------------------
      # Part 2: Algorithmic feed
      # Uses AffinityScore to rank candidates. The admin account has positive
      # signals for the #algorithmtest tag (seeded below), so posts carrying
      # that tag score high and should be promoted. Posts without the tag (or
      # from an unknown author) score near zero and fail the min_score filter.
      # -----------------------------------------------------------------------

      algo_poster = Account.create_with(
        username: 'algo_test_poster',
        display_name: 'Algorithm Test Poster',
        note: 'Demo account whose posts feed the algorithmic feed test.'
      ).find_or_create_by!(id: 12_000_000)

      algo_poster_user = User.create_with(
        account_id: algo_poster.id,
        agreement: true,
        password: SecureRandom.hex,
        email: ENV.fetch('TEST_DATA_ALGO_EMAIL', 'algo_test_poster@localhost'),
        confirmed_at: Time.now.utc,
        approved: true,
        bypass_registration_checks: true
      ).find_or_create_by!(id: 12_000_000)
      algo_poster_user.mark_email_as_confirmed!
      algo_poster_user.approve!

      # Unknown poster — no prior signals from admin
      unknown_poster = Account.create_with(
        username: 'algo_unknown_poster',
        display_name: 'Unknown Algorithm Poster',
        note: 'Posts from this account have no signal history — used to test near-zero scoring.'
      ).find_or_create_by!(id: 12_000_001)

      unknown_poster_user = User.create_with(
        account_id: unknown_poster.id,
        agreement: true,
        password: SecureRandom.hex,
        email: ENV.fetch('TEST_DATA_ALGO_UNKNOWN_EMAIL', 'algo_unknown_poster@localhost'),
        confirmed_at: Time.now.utc,
        approved: true,
        bypass_registration_checks: true
      ).find_or_create_by!(id: 12_000_001)
      unknown_poster_user.mark_email_as_confirmed!
      unknown_poster_user.approve!

      Follow.find_or_create_by!(account: admin_account, target_account: algo_poster)
      Follow.find_or_create_by!(account: admin_account, target_account: unknown_poster)

      algo_list = List.create_with(title: 'Algorithm Test').find_or_create_by!(account: admin_account, title: 'Algorithm Test')
      ListAccount.find_or_create_by!(list: algo_list, account: algo_poster)
      ListAccount.find_or_create_by!(list: algo_list, account: unknown_poster)

      algo_config = CustomFeedConfig.find_or_create_by!(list: algo_list, account: admin_account) do |c|
        c.feed_type = 'algorithmic'
        c.enabled   = true
      end
      # Ensure feed_type is set even if the config pre-existed as standard
      algo_config.update!(feed_type: 'algorithmic') unless algo_config.feed_type == 'algorithmic'

      [
        # Source: followed accounts (routed to pending queue for algorithmic feeds)
        { phase: 'source',             step_type: 'followed_posts',
          position: 0, options: {} },
        # Algorithm: affinity score with a small batch size for easy testing
        { phase: 'algorithm',          step_type: 'affinity_score',
          position: 0, options: { 'batch_size' => 20, 'max_pending_age_hours' => 48 } },
        # Gate: wait until at least 2 signal records exist (we seed 2: tag + account)
        { phase: 'algorithmic_filter', step_type: 'min_signals',
          position: 0, options: { 'count' => 2 } },
        # Score threshold: only promote posts with score >= 5.0
        # should_show posts score ~12.0 × time_factor; should_not posts score ~0.0.
        { phase: 'algorithmic_filter', step_type: 'min_score',
          position: 1, options: { 'threshold' => 5.0 } },
        # Cap promotions per run
        { phase: 'algorithmic_filter', step_type: 'top_k_per_batch',
          position: 2, options: { 'k' => 10 } },
        { phase: 'overflow_strategy',  step_type: 'oldest_first',
          position: 0, options: {} },
      ].each do |attrs|
        step = CustomFeedStep.find_or_initialize_by(
          custom_feed_config: algo_config, phase: attrs[:phase], step_type: attrs[:step_type]
        )
        step.position = attrs[:position]
        step.options  = attrs[:options]
        step.save!
      end

      # -- Signal seeding -------------------------------------------------------
      # Simulate the admin having reblogged 3 posts tagged #algorithmtest from
      # algo_poster. algo_poster is a local account so no domain signal is created
      # (domain signals are only meaningful for remote accounts — see AffinityScore
      # and SignalWorker). This produces:
      #   tag:algorithmtest    weight = 3 × 2.0 = 6.0   (3 boosts)
      #   account:<id>         weight = 3 × 2.0 = 6.0
      # Total signal records: 2 (min_signals is set to 2 to match)
      #
      # Expected scores:
      #   should_show_1  tag(6.0) + account(6.0) ≈ 12.0 × time_factor  → PASS  min_score: 5.0
      #   should_show_2  tag(6.0) + tag(0) + account(6.0) ≈ 12.0       → PASS
      #   should_not_1   no tag match, no account match → 0.0           → FAIL
      #   should_not_2   no tag match, no account match → 0.0           → FAIL

      # Clear any stale domain signal from a previous seed run
      RecommendationSignal.where(
        account: admin_account, signal_type: 'domain', entity_id: ''
      ).delete_all

      signal_base_weight = 3 * 2.0  # 3 reblogs × reblog weight

      [
        { signal_type: 'tag',     entity_id: 'algorithmtest',     weight: signal_base_weight },
        { signal_type: 'account', entity_id: algo_poster.id.to_s, weight: signal_base_weight },
      ].each do |attrs|
        RecommendationSignal.upsert(
          attrs.merge(
            account_id:        admin_account.id,
            observation_count: 3,
            last_observed_at:  Time.current,
            created_at:        Time.current,
            updated_at:        Time.current
          ),
          on_duplicate: Arel.sql(
            'weight = EXCLUDED.weight, ' \
            'observation_count = EXCLUDED.observation_count, ' \
            'last_observed_at = EXCLUDED.last_observed_at, ' \
            'updated_at = EXCLUDED.updated_at'
          ),
          unique_by: :idx_rec_signals_lookup
        )
      end

      signal_count = RecommendationSignal.where(account: admin_account).count

      # -- Posts that SHOULD be promoted (score >> threshold) -------------------
      # Tagged #algorithmtest by the known poster → high tag + account affinity.

      should_show_1 = Status.create_with(
        text: '[SHOULD SHOW] High-signal post: tagged #algorithmtest by a known author. ' \
              'Score = tag_affinity + account_affinity. Should pass min_score filter.',
        account: algo_poster,
        visibility: :public
      ).find_or_create_by!(id: 12_000_100)
      ProcessHashtagsService.new.call(should_show_1)
      # Manually attach tag in case ProcessHashtags missed the inline #tag
      algo_tag = Tag.find_or_create_by!(name: 'algorithmtest')
      should_show_1.tags << algo_tag unless should_show_1.tags.include?(algo_tag)

      should_show_2 = Status.create_with(
        text: '[SHOULD SHOW] Another high-signal post. #algorithmtest #fedidev ' \
              'Two matching tags means even higher score.',
        account: algo_poster,
        visibility: :public
      ).find_or_create_by!(id: 12_000_101)
      ProcessHashtagsService.new.call(should_show_2)
      should_show_2.tags << algo_tag unless should_show_2.tags.include?(algo_tag)

      # -- Posts that should NOT be promoted (score < threshold) ----------------

      # Known author but no matching tag → only account affinity, still scores
      # 6.0 * time_factor which is above the threshold. To make a "should not
      # show" post from the known author, use a tag the admin has NEGATIVE
      # (zero) affinity for. Score = account_affinity alone ≈ 6.0 — which
      # actually passes. So instead we use the unknown poster with an unrelated
      # tag. Score ≈ 0.0.
      should_not_1 = Status.create_with(
        text: '[SHOULD NOT SHOW] Unknown author, unrelated tag #unrelated. ' \
              'No signal history → score ≈ 0, fails min_score: 1.0.',
        account: unknown_poster,
        visibility: :public
      ).find_or_create_by!(id: 12_000_200)
      ProcessHashtagsService.new.call(should_not_1)

      should_not_2 = Status.create_with(
        text: '[SHOULD NOT SHOW] Unknown author, no tags. Score = 0.0.',
        account: unknown_poster,
        visibility: :public
      ).find_or_create_by!(id: 12_000_201)

      # -- Load all test posts into the pending queue ---------------------------
      # Clear both the feed and pending queue first so re-runs start clean.
      RedisConnection.with do |r|
        r.del(cf_manager.key(algo_list.id))
        r.del(cf_manager.pending_key(algo_list.id))
        r.del(cf_manager.inserted_at_key(algo_list.id))
      end

      should_show = [should_show_1, should_show_2]
      should_not  = [should_not_1, should_not_2]

      (should_show + should_not).each do |status|
        cf_manager.enqueue_candidate(algo_config, status)
      end

      pending_size = RedisConnection.with { |r| r.zcard(cf_manager.pending_key(algo_list.id)) }

      puts "\n=== Algorithm Test (algorithmic feed) ==="
      puts "  List          ##{algo_list.id} '#{algo_list.title}'"
      puts "  Config        ##{algo_config.id} (feed_type: #{algo_config.feed_type})"
      puts "  Signals       #{signal_count} records for @#{admin_account.username}"
      puts "  Signal detail tag:algorithmtest=#{signal_base_weight}, " \
           "account:#{algo_poster.id}=#{signal_base_weight}"
      puts "  Pending queue #{pending_size} posts (#{should_show.size} should show, #{should_not.size} should not)"
      puts "  min_score     5.0  (should-show score ~#{(signal_base_weight * 2).round(1)} × time_factor, should-not ~0.0)"
      puts "  URL           http://localhost:3000/lists/#{algo_list.id}"
      puts "\n  Run the algorithm worker to promote posts:"
      puts "  bin/rails runner 'Recommendations::AlgorithmicFeedWorker.new.perform(#{algo_config.id})'"
      puts '  (or wait for the 5-minute Sidekiq scheduler to fire)'

      # Optionally run the worker inline when ALGO_FEED_RUN_WORKER=1 is set.
      if ENV['ALGO_FEED_RUN_WORKER'] == '1'
        puts "\n  Running AlgorithmicFeedWorker inline..."
        Recommendations::AlgorithmicFeedWorker.new.perform(algo_config.id)
        feed_size = RedisConnection.with { |r| r.zcard(cf_manager.key(algo_list.id)) }
        promoted_ids = RedisConnection.with { |r| r.zrange(cf_manager.key(algo_list.id), 0, -1) }.map(&:to_i)
        puts "  Promoted #{feed_size} post(s) to the feed: #{promoted_ids.inspect}"
        puts "  Expected: #{should_show.map(&:id).inspect}"
      end
    end

    puts "\nDone. Visit http://localhost:3000 and check the Lists column."
  end
end
