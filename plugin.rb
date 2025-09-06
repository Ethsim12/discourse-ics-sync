# frozen_string_literal: true

# name: discourse-ics-sync
# about: Pull ICS feeds into topics, upserting by UID (cronless via Sidekiq)
# version: 0.1.0
# authors: Ethan
# url: https://meta.discourse.org/t/syncing-ical-ics-feeds-into-discourse-topics-simple-python-script-cron-friendly/379361
# required_version: 3.2.0

# Ensure plugin gems are installed by Discourse during bootstrap
gem 'ice_cube', '0.16.4'
gem 'icalendar', '2.8.0'

enabled_site_setting :ics_enabled

after_initialize do
  require 'ice_cube'
  require 'icalendar'
  
  # --- NEW: build [event] BBCode understood by discourse-calendar/events ---
  module ::IcsSync
    class Bbcode
      def self.escape_attr(str)
        str.to_s.gsub('"', '\"').gsub("\n", " ").strip
      end

      # Format Ruby Time/Date/DateTime to:
      #  - date-only "YYYY-MM-DD" for all-day
      #  - ISO-8601 UTC with Z "YYYY-MM-DDTHH:MM:SSZ" for timed events
      def self.fmt(dt)
        return "" unless dt
        if dt.is_a?(Date) && !dt.is_a?(DateTime)
          dt.strftime("%Y-%m-%d")
        else
          (dt.to_time.getutc).strftime("%Y-%m-%dT%H:%M:%SZ")
        end
      end

      # Returns the full post body (event bbcode + optional description + invisible UID marker)
      def self.render_event(ev, site_tz:)
        start_s = fmt(ev[:starts_at])
        end_s   = fmt(ev[:ends_at]) if ev[:ends_at]
        tz      = (ev[:tzid] || site_tz).to_s
        name    = escape_attr(ev[:summary])
        url     = escape_attr(ev[:url])
        loc     = escape_attr(ev[:location])

        attrs = []
        attrs << %(start="#{start_s}") unless start_s.empty?
        attrs << %(end="#{end_s}")     if end_s && !end_s.empty?
        attrs << %(timezone="#{tz}")   unless tz.empty?
        attrs << %(status="standalone")  # or "public" if you want RSVP UI
        attrs << %(name="#{name}")     unless name.empty?
        attrs << %(url="#{url}")       unless url.empty?
        attrs << %(location="#{loc}")  unless loc.empty?
        attrs << %(minimal="true")

        body = +"[event #{attrs.join(' ')}]\n[/event]\n"
        desc = ev[:description].to_s.strip
        body << "\n#{desc}\n" unless desc.empty?
        body << "\n<!-- ics_uid: #{escape_attr(ev[:uid])} -->\n"
        body
      end
    end
  end

 
  module ::IcsSync
    PLUGIN_NAME = 'discourse-ics-sync'

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace IcsSync
    end

    def self.plugin_store
      @plugin_store ||= PluginStore.new(PLUGIN_NAME)
    end

    def self.get_feed_state(key)
      plugin_store.get("feed:#{key}") || {}
    end

    def self.set_feed_state(key, hash)
      plugin_store.set("feed:#{key}", hash)
    end

    def self.find_topic_id_by_uid(uid)
      TopicCustomField.where(name: 'ics_uid', value: uid).pick(:topic_id)
    end

    def self.normalize_tags(tags, namespace: nil, max_len: SiteSetting.ics_max_tags_length)
      tags ||= []
      tags = tags.map(&:to_s).map(&:downcase)
      tags = tags.map { |t| t.gsub(/[^a-z0-9\-_]/, '-') }
      tags = tags.reject(&:blank?).uniq
      tags = tags.map { |t| "#{namespace}-#{t}" } if namespace.present?
      tags.map { |t| t[0, max_len] }
    end

    def self.http_get_with_cache(url, key:)
      require 'net/http'
      require 'uri'

      state = get_feed_state(key)
      uri = URI.parse(url)
      req = Net::HTTP::Get.new(uri)
      req['If-None-Match'] = state['etag'] if state['etag']
      req['If-Modified-Since'] = state['last_modified'] if state['last_modified']

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 20
      http.open_timeout = 10

      res = http.request(req)

      case res.code.to_i
      when 200
        set_feed_state(key, {
          'etag' => res['ETag'],
          'last_modified' => res['Last-Modified'],
          'fetched_at' => Time.now.utc.iso8601,
          'status' => '200'
        }.compact)
        [res.body, :fresh]
      when 304
        set_feed_state(key, { 'fetched_at' => Time.now.utc.iso8601, 'status' => '304' }.compact)
        [nil, :not_modified]
      else
        set_feed_state(key, {
          'fetched_at' => Time.now.utc.iso8601,
          'status' => res.code,
          'error' => res.message
        }.compact)
        [nil, :error]
      end
    rescue => e
      set_feed_state(key, { 'fetched_at' => Time.now.utc.iso8601, 'status' => 'error', 'error' => e.message })
      [nil, :error]
    end
# Replace the entire render_event_body with this version:

def self.render_event_body(event, feed)
  # Pull tzid (if present) from DTSTART/DTEND params
  def extract_tzid(v)
    return nil unless v && v.respond_to?(:params)
    p = v.params || {}
    # params keys can be strings or symbols depending on gem version
    (p['tzid'] || p[:tzid] || [nil]).first
  end

  # Convert Icalendar::Values::* to Ruby Time/Date
  def to_ruby_time_or_date(v)
    return nil unless v
    # All-day: Icalendar::Values::Date → Date
    if defined?(Icalendar::Values::Date) && v.is_a?(Icalendar::Values::Date)
      v.to_date
    else
      # Timed: prefer UTC if available, else to_time
      v.respond_to?(:value_utc) ? v.value_utc : v.to_time
    end
  end

  ev = {
    uid:         event.uid.to_s,
    summary:     event.summary.to_s,
    description: event.description.to_s,
    location:    event.location.to_s,
    url:         event.url.to_s,
    starts_at:   to_ruby_time_or_date(event.dtstart),
    ends_at:     to_ruby_time_or_date(event.dtend),
    tzid:        extract_tzid(event.dtstart) || extract_tzid(event.dtend)
  }

  site_tz =
    if SiteSetting.respond_to?(:calendar_default_timezone) &&
       SiteSetting.calendar_default_timezone.present?
      SiteSetting.calendar_default_timezone
    else
      "UTC"
    end

  ::IcsSync::Bbcode.render_event(ev, site_tz: site_tz)
end

    def self.title_from_event(event)
      (event.summary || "Untitled event").to_s.strip
    end

    def self.update_first_post_raw(topic, new_raw)
      fp = Post.where(topic_id: topic.id, post_number: 1).first
      return unless fp
      old_raw = fp.raw
      if old_raw.to_s.strip != new_raw.to_s.strip
        fp.revise(Discourse.system_user, { raw: new_raw }, force_new_version: true)
      end
    end

    def self.upsert_event!(event, feed)
      uid = event.uid&.to_s&.strip
      return unless uid.present?

      topic_id = find_topic_id_by_uid(uid)
      category_id = feed['category_id'] || SiteSetting.ics_category_default
      category_id = category_id.to_i if category_id

      all_tags = []
      all_tags.concat(SiteSetting.ics_default_tags.split(',').map(&:strip)) if SiteSetting.ics_default_tags.present?
      all_tags.concat((feed['static_tags'] || []))
      all_tags = normalize_tags(all_tags, namespace: SiteSetting.ics_namespace.presence)

      body = render_event_body(event, feed)

      if topic_id
        topic = Topic.find_by(id: topic_id)
        return unless topic
        update_first_post_raw(topic, body)
        if all_tags.present?
          merged = (topic.tags.map(&:name) + all_tags).uniq
          DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), merged)
        end
        topic
      else
        title = title_from_event(event)
        creator = PostCreator.new(
          User.find_by(username: SiteSetting.ics_user) || Discourse.system_user,
          title: title,
          raw: body,
          category: category_id,
          tags: all_tags
        )
        post = creator.create
        raise creator.errors.full_messages.join(", ") unless post&.persisted?
        post.topic.custom_fields['ics_uid'] = uid
        post.topic.custom_fields['ics_source'] = (feed['key'] || feed['url']).to_s
        post.topic.save_custom_fields
        post.topic
      end
    end
  end

  module ::Jobs
    class FetchIcsFeeds < ::Jobs::Scheduled
      every 5.minutes

      def execute(args)
        return unless SiteSetting.ics_enabled

        if SiteSetting.ics_fetch_interval_mins.to_i >= 1
          last = PluginStore.get(::IcsSync::PLUGIN_NAME, "last_run_at")
          if last.present?
            delta = (Time.now - Time.parse(last)).to_i / 60
            return if delta < SiteSetting.ics_fetch_interval_mins.to_i
          end
          PluginStore.set(::IcsSync::PLUGIN_NAME, "last_run_at", Time.now.utc.iso8601)
        end

        feeds = parse_feeds
        feeds.each { |feed| process_feed(feed) }
      end

      def parse_feeds
        raw = SiteSetting.ics_feeds
        return [] if raw.blank?
        JSON.parse(raw)
      rescue JSON::ParserError
        Rails.logger.warn("[discourse-ics-sync] Invalid JSON in SiteSetting.ics_feeds")
        []
      end

      def process_feed(feed)
        url = feed['url'].to_s.strip
        return if url.blank?

        key = (feed['key'].presence || Digest::SHA1.hexdigest(url))[0, 20]
        body, status = ::IcsSync.http_get_with_cache(url, key: key)
        return unless status == :fresh

        cal = Icalendar::Calendar.parse(body).first rescue nil
        return unless cal

        cal.events.each do |ev|
          begin
            ::IcsSync.upsert_event!(ev, feed.merge('key' => key, 'url' => url))
          rescue => e
            Rails.logger.error("[discourse-ics-sync] upsert failed uid=#{ev&.uid} feed=#{key}: #{e.message}")
          end
        end
      end
    end
  end
end
