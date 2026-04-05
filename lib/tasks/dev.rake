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

  desc 'Add a "New To Me" custom feed list to the admin account and seed it with sample posts. Safe to run multiple times.'
  task setup_new_to_me: :environment do
    admin_user = User.find_by(email: 'admin@localhost') || User.admins.first
    abort 'Could not find admin user. Run bin/setup first.' unless admin_user

    admin_account = admin_user.account

    # Keep the admin feed active
    admin_user.update!(current_sign_in_at: Time.now.utc)

    Chewy.strategy(:mastodon) do
      # Create a dedicated poster account for New To Me demo content
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

      # Admin follows the demo poster so fan-out works in future
      Follow.find_or_create_by!(account: admin_account, target_account: ntm_poster)

      # Create the "New To Me" list and add the poster to it
      ntm_list = List.create_with(
        title: 'New To Me'
      ).find_or_create_by!(account: admin_account, title: 'New To Me')

      # Ensure the list has a CustomFeedConfig with the standard NTM pipeline
      ntm_config = CustomFeedConfig.find_or_initialize_by(list: ntm_list, account: admin_account)
      unless ntm_config.persisted?
        ntm_config.enabled = true
        ntm_config.save!
        [
          { phase: 'source',            step_type: 'followed_posts',   position: 0 },
          { phase: 'filter',            step_type: 'interacted_posts', position: 0 },
          { phase: 'removal_strategy',  step_type: 'on_interaction',   position: 0 },
          { phase: 'overflow_strategy', step_type: 'oldest_first',     position: 0 },
        ].each { |attrs| CustomFeedStep.create!(custom_feed_config: ntm_config, **attrs) }
      end
      ListAccount.find_or_create_by!(list: ntm_list, account: ntm_poster)
      # Plain text post
      plain_post = Status.create_with(
        text: 'This is a plain text post that will appear in your New To Me feed. Try liking it — it should disappear!',
        account: ntm_poster,
        visibility: :public
      ).find_or_create_by!(id: 11_000_000)

      # Post with hashtags
      tagged_post = Status.create_with(
        text: 'This post has hashtags to help you discover it. #NewToMe #Mastodon #FediDev',
        account: ntm_poster,
        visibility: :public
      ).find_or_create_by!(id: 11_000_001)
      ProcessHashtagsService.new.call(tagged_post)

      # Post with a content warning
      cw_post = Status.create_with(
        text: 'The content behind this CW is perfectly safe. This post tests that CW posts appear in the New To Me feed correctly.',
        spoiler_text: 'New To Me feed test — click to expand',
        account: ntm_poster,
        visibility: :public
      ).find_or_create_by!(id: 11_000_002)

      # Post with a poll
      poll_post = Status.create_with(
        text: 'Which interaction should remove a post from the New To Me feed?',
        account: ntm_poster,
        visibility: :public,
        poll_attributes: {
          voters_count: 0,
          account: ntm_poster,
          expires_at: 7.days.from_now,
          options: ['Liking it', 'Reblogging it', 'Replying to it', 'All three!'],
          multiple: false,
        }
      ).find_or_create_by!(id: 11_000_003)

      # Unlisted post (still eligible for New To Me)
      unlisted_post = Status.create_with(
        text: 'This is an unlisted (Quiet Public) post. It should still appear in the New To Me feed.',
        account: ntm_poster,
        visibility: :unlisted
      ).find_or_create_by!(id: 11_000_004)

      # Post with media
      media_attachment = MediaAttachment.create_with(
        account: ntm_poster,
        file: File.open('spec/fixtures/files/600x400.png'),
        description: 'Mastodon logo — a sample image for the New To Me feed demo'
      ).find_or_create_by!(id: 11_000_000)
      media_post = Status.create_with(
        text: 'This post has an image attachment. Reblogs of this post should remove it from your New To Me feed.',
        ordered_media_attachment_ids: [media_attachment.id],
        account: ntm_poster,
        visibility: :public
      ).find_or_create_by!(id: 11_000_005)
      media_attachment.update!(status_id: media_post.id)

      # A reply from the poster to themselves (tests that replies to NTM posts remove them)
      reply_post = Status.create_with(
        text: 'This is a self-reply. If you reply to the post above this one, that post should disappear from your New To Me feed.',
        account: ntm_poster,
        visibility: :public,
        thread: plain_post,
        in_reply_to_id: plain_post.id,
        in_reply_to_account_id: ntm_poster.id
      ).find_or_create_by!(id: 11_000_006)

      # Populate the custom feed Redis key directly
      cf_manager = CustomFeeds::FeedManager.instance
      [plain_post, tagged_post, cw_post, poll_post, unlisted_post, media_post, reply_post].each do |status|
        cf_manager.push(ntm_config, status)
      end

      feed_size = RedisConnection.with { |r| r.zcard(cf_manager.key(ntm_list.id)) }
      puts "New To Me list created: \"#{ntm_list.title}\" (id: #{ntm_list.id})"
      puts "Seeded #{feed_size} posts into the custom feed for @#{admin_account.username}"
      puts "Visit: http://localhost:3000/lists/#{ntm_list.id}"
    end
  end
end
