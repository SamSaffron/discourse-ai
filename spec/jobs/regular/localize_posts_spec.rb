# frozen_string_literal: true

describe Jobs::LocalizePosts do
  fab!(:post)
  subject(:job) { described_class.new }

  let(:locales) { %w[en ja de] }

  before do
    SiteSetting.discourse_ai_enabled = true
    Fabricate(:fake_model).tap do |fake_llm|
      SiteSetting.public_send("ai_translation_model=", "custom:#{fake_llm.id}")
    end
    SiteSetting.ai_translation_enabled = true
    SiteSetting.content_localization_supported_locales = locales.join("|")
  end

  it "does nothing when translator is disabled" do
    SiteSetting.discourse_ai_enabled = false
    DiscourseAi::Translation::PostLocalizer.expects(:localize).never

    job.execute({ limit: 10 })
  end

  it "does nothing when ai_translation_enabled is disabled" do
    SiteSetting.ai_translation_enabled = false
    DiscourseAi::Translation::PostLocalizer.expects(:localize).never

    job.execute({ limit: 10 })
  end

  it "does nothing when no target languages are configured" do
    SiteSetting.content_localization_supported_locales = ""
    DiscourseAi::Translation::PostLocalizer.expects(:localize).never

    job.execute({ limit: 10 })
  end

  it "does nothing when there are no posts to translate" do
    Post.destroy_all
    DiscourseAi::Translation::PostLocalizer.expects(:localize).never

    job.execute({ limit: 10 })
  end

  it "skips posts that already have localizations" do
    Post.all.each do |post|
      Fabricate(:post_localization, post:, locale: "en")
      Fabricate(:post_localization, post:, locale: "ja")
    end
    DiscourseAi::Translation::PostLocalizer.expects(:localize).never

    job.execute({ limit: 10 })
  end

  it "skips bot posts" do
    post.update!(user: Discourse.system_user)
    DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "en").never
    DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "ja").never

    job.execute({ limit: 10 })
  end

  it "handles translation errors gracefully" do
    post.update(locale: "es")
    DiscourseAi::Translation::PostLocalizer
      .expects(:localize)
      .with(post, "en")
      .raises(StandardError.new("API error"))
    DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "ja").once
    DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "de").once

    expect { job.execute({ limit: 10 }) }.not_to raise_error
  end

  it "logs a summary after translation" do
    post.update(locale: "es")
    DiscourseAi::Translation::PostLocalizer.stubs(:localize)
    DiscourseAi::Translation::VerboseLogger.expects(:log).with(includes("Translated 1 posts to en"))
    DiscourseAi::Translation::VerboseLogger.expects(:log).with(includes("Translated 1 posts to ja"))
    DiscourseAi::Translation::VerboseLogger.expects(:log).with(includes("Translated 1 posts to de"))

    job.execute({ limit: 10 })
  end

  context "for translation scenarios" do
    it "scenario 1: skips post when locale is not set" do
      DiscourseAi::Translation::PostLocalizer.expects(:localize).never

      job.execute({ limit: 10 })
    end

    it "scenario 2: returns post with locale 'es' if localizations for en/ja/de do not exist" do
      post = Fabricate(:post, locale: "es")

      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "en").once
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "ja").once
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "de").once

      job.execute({ limit: 10 })
    end

    it "scenario 3: returns post with locale 'en' if ja/de localization does not exist" do
      post = Fabricate(:post, locale: "en")

      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "ja").once
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "de").once
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "en").never

      job.execute({ limit: 10 })
    end

    it "scenario 4: skips post with locale 'en' if 'ja' localization already exists" do
      post = Fabricate(:post, locale: "en")
      Fabricate(:post_localization, post: post, locale: "ja")

      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "en").never
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "ja").never
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(post, "de").once

      job.execute({ limit: 10 })
    end
  end

  describe "with public content limitation" do
    fab!(:private_category) { Fabricate(:private_category, group: Group[:staff]) }
    fab!(:private_topic) { Fabricate(:topic, category: private_category) }
    fab!(:private_post) { Fabricate(:post, topic: private_topic, locale: "es") }

    fab!(:public_post) { Fabricate(:post, locale: "es") }

    fab!(:personal_pm_topic) { Fabricate(:private_message_topic) }
    fab!(:personal_pm_post) { Fabricate(:post, topic: personal_pm_topic, locale: "es") }

    fab!(:group)
    fab!(:group_pm_topic) { Fabricate(:group_private_message_topic, recipient_group: group) }
    fab!(:group_pm_post) { Fabricate(:post, topic: group_pm_topic, locale: "es") }

    before { SiteSetting.content_localization_supported_locales = "ja" }

    context "when ai_translation_backfill_limit_to_public_content is true" do
      before { SiteSetting.ai_translation_backfill_limit_to_public_content = true }

      it "only processes posts from public categories" do
        DiscourseAi::Translation::PostLocalizer.expects(:localize).with(public_post, "ja").once

        DiscourseAi::Translation::PostLocalizer
          .expects(:localize)
          .with(private_post, any_parameters)
          .never

        DiscourseAi::Translation::PostLocalizer
          .expects(:localize)
          .with(personal_pm_post, any_parameters)
          .never
        DiscourseAi::Translation::PostLocalizer
          .expects(:localize)
          .with(group_pm_post, any_parameters)
          .never

        job.execute({ limit: 10 })
      end
    end

    context "when ai_translation_backfill_limit_to_public_content is false" do
      before { SiteSetting.ai_translation_backfill_limit_to_public_content = false }

      it "processes public posts and group PMs but not personal PMs" do
        DiscourseAi::Translation::PostLocalizer.expects(:localize).with(public_post, "ja").once
        DiscourseAi::Translation::PostLocalizer.expects(:localize).with(private_post, "ja").once

        DiscourseAi::Translation::PostLocalizer.expects(:localize).with(group_pm_post, "ja").once

        DiscourseAi::Translation::PostLocalizer
          .expects(:localize)
          .with(personal_pm_post, any_parameters)
          .never

        job.execute({ limit: 10 })
      end
    end
  end

  describe "with max age limit" do
    fab!(:old_post) { Fabricate(:post, locale: "es", created_at: 10.days.ago) }
    fab!(:new_post) { Fabricate(:post, locale: "es", created_at: 2.days.ago) }

    before do
      SiteSetting.ai_translation_backfill_max_age_days = 5
      SiteSetting.content_localization_supported_locales = "ja"
    end

    it "only processes posts within the age limit" do
      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(new_post, "ja").once

      DiscourseAi::Translation::PostLocalizer
        .expects(:localize)
        .with(old_post, any_parameters)
        .never

      job.execute({ limit: 10 })
    end

    it "processes all posts when setting is disabled" do
      SiteSetting.ai_translation_backfill_max_age_days = 0

      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(new_post, "ja").once

      DiscourseAi::Translation::PostLocalizer.expects(:localize).with(old_post, "ja").once

      job.execute({ limit: 10 })
    end
  end
end
