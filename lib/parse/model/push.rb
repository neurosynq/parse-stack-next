# encoding: UTF-8
# frozen_string_literal: true

require_relative "../query.rb"
require_relative "../client.rb"
require "active_model/serializers/json"

module Parse
  # This class represents the API to send push notification to devices that are
  # available in the Installation table. Push notifications are implemented
  # through the `Parse::Push` class. To send push notifications through the
  # REST API, you must enable `REST push enabled?` option in the `Push
  # Notification Settings` section of the `Settings` page in your Parse
  # application. Push notifications targeting uses the Installation Parse
  # class to determine which devices receive the notification. You can provide
  # any query constraint, similar to using `Parse::Query`, in order to target
  # the specific set of devices you want given the columns you have configured
  # in your `Installation` class. The `Parse::Push` class supports many other
  # options not listed here.
  #
  # @example Traditional API
  #   push = Parse::Push.new
  #   push.send("Hello World!") # to everyone
  #
  #   # simple channel push
  #   push = Parse::Push.new
  #   push.channels = ["addicted2salsa"]
  #   push.send "You are subscribed to Addicted2Salsa!"
  #
  #   # advanced targeting
  #   push = Parse::Push.new({..where query constraints..})
  #   push.where :device_type.in => ['ios','android'], :location.near => some_geopoint
  #   push.alert = "Hello World!"
  #   push.sound = "soundfile.caf"
  #   push.data = { uri: "app://deep_link_path" }
  #   push.send
  #
  # @example Builder Pattern API (Fluent Interface)
  #   # Simple channel push with builder pattern
  #   Parse::Push.new
  #     .to_channel("news")
  #     .with_alert("Breaking news!")
  #     .send!
  #
  #   # Rich push with scheduling
  #   Parse::Push.new
  #     .to_channels("sports", "updates")
  #     .with_title("Game Alert")
  #     .with_body("Your team is playing now!")
  #     .with_badge(1)
  #     .with_sound("alert.caf")
  #     .with_data(game_id: "12345")
  #     .schedule(1.hour.from_now)
  #     .expires_in(3600)
  #     .send!
  #
  #   # Using class method shortcut
  #   Parse::Push.to_channel("alerts")
  #     .with_alert("Important update")
  #     .send!
  #
  #   # Using query block for advanced targeting
  #   Parse::Push.new
  #     .to_query { |q| q.where(:device_type => "ios", :app_version.gte => "2.0") }
  #     .with_alert("iOS 2.0+ users only")
  #     .send!
  #
  class Push
    include Client::Connectable

    # Device types that support push notifications.
    # These are the device types that Parse Server has push adapters for.
    # @see https://docs.parseplatform.org/parse-server/guide/#push-notifications
    SUPPORTED_PUSH_DEVICE_TYPES = %w[ios android osx tvos watchos web expo].freeze

    # Device types that are known but may not have push support configured.
    # These will generate warnings when targeted.
    UNSUPPORTED_PUSH_DEVICE_TYPES = %w[win other unknown unsupported].freeze

    # @!attribute [rw] query
    # Sending a push notification is done by performing a query against the Installation
    # collection with a Parse::Query. This query contains the constraints that will be
    # sent to Parse with the push payload.
    #   @return [Parse::Query] the query containing Installation constraints.

    # @!attribute [rw] alert
    #   @return [String]
    # @!attribute [rw] badge
    #   @return [Integer]
    # @!attribute [rw] sound
    #   @return [String] the name of the sound file
    # @!attribute [rw] title
    #   @return [String]
    # @!attribute [rw] data
    #   @return [Hash] specific payload data.
    # @!attribute [rw] expiration_time
    #   @return [Parse::Date]
    # @!attribute [rw] expiration_interval
    #   @return [Integer]
    # @!attribute [rw] push_time
    #   @return [Parse::Date]
    # @!attribute [rw] channels
    #   @return [Array] an array of strings for subscribed channels.
    # @!attribute [rw] content_available
    #   @return [Boolean] whether this is a silent push (iOS content-available).
    # @!attribute [rw] mutable_content
    #   @return [Boolean] whether this notification can be modified by a service extension (iOS).
    # @!attribute [rw] category
    #   @return [String] the notification category for action buttons (iOS).
    # @!attribute [rw] image_url
    #   @return [String] URL for an image attachment (requires mutable-content).
    # @!attribute [rw] localized_alerts
    #   @return [Hash] language-specific alert messages (e.g., {"en" => "Hello", "fr" => "Bonjour"})
    # @!attribute [rw] localized_titles
    #   @return [Hash] language-specific titles (e.g., {"en" => "Welcome", "fr" => "Bienvenue"})
    attr_writer :query
    attr_reader :channels, :data
    attr_accessor :alert, :badge, :sound, :title,
                  :expiration_time, :expiration_interval, :push_time,
                  :content_available, :mutable_content, :category, :image_url,
                  :localized_alerts, :localized_titles

    alias_method :message, :alert
    alias_method :message=, :alert=

    # Send a push notification using a push notification hash
    # @param payload [Hash] a push notification hash payload
    def self.send(payload)
      client.push payload.as_json
    end

    # Create a new Push targeting a specific channel.
    # @param channel [String] the channel name to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_channel("news").with_alert("Hello!").send!
    def self.to_channel(channel)
      new.to_channel(channel)
    end

    # Create a new Push targeting multiple channels.
    # @param channels [Array<String>] the channel names to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_channels("news", "sports").with_alert("Update!").send!
    def self.to_channels(*channels)
      new.to_channels(*channels)
    end

    # List all available channels from the Installation collection.
    # This is a convenience method that delegates to {Installation.all_channels}.
    # @return [Array<String>] array of channel names
    # @example
    #   available_channels = Parse::Push.channels
    #   # => ["news", "sports", "weather"]
    def self.channels
      Parse::Installation.all_channels
    end

    # Create a new Push targeting a specific user.
    # @param user [Parse::User, Hash, String] the user to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_user(current_user).with_alert("Hello!").send!
    def self.to_user(user)
      new.to_user(user)
    end

    # Create a new Push targeting a user by their objectId.
    # @param user_id [String] the objectId of the user to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_user_id("abc123").with_alert("Hello!").send!
    def self.to_user_id(user_id)
      new.to_user_id(user_id)
    end

    # Create a new Push targeting multiple users.
    # @param users [Array<Parse::User, Hash, String>] the users to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_users(user1, user2).with_alert("Group message!").send!
    def self.to_users(*users)
      new.to_users(*users)
    end

    # Create a new Push targeting a specific installation.
    # @param installation [Parse::Installation, Hash, String] the installation to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_installation(device).with_alert("Hello!").send!
    def self.to_installation(installation)
      new.to_installation(installation)
    end

    # Create a new Push targeting an installation by its objectId.
    # @param installation_id [String] the objectId of the installation to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_installation_id("abc123").with_alert("Hello!").send!
    def self.to_installation_id(installation_id)
      new.to_installation_id(installation_id)
    end

    # Create a new Push targeting multiple installations.
    # @param installations [Array<Parse::Installation, Hash, String>] the installations to target
    # @return [Parse::Push] a new Push instance for chaining
    # @example
    #   Parse::Push.to_installations(device1, device2).with_alert("Hello!").send!
    def self.to_installations(*installations)
      new.to_installations(*installations)
    end

    # Initialize a new push notification request.
    # @param constraints [Hash] a set of query constraints
    def initialize(constraints = {})
      self.where constraints
    end

    def query
      @query ||= Parse::Query.new(Parse::Model::CLASS_INSTALLATION)
    end

    # Set a hash of conditions for this push query.
    # @return [Parse::Query]
    def where=(where_clauses)
      query.where where_clauses
    end

    # Apply a set of constraints.
    # @param constraints [Hash] the set of {Parse::Query} cosntraints
    # @return [Hash] if no constraints were passed, returns a compiled query.
    # @return [Parse::Query] if constraints were passed, returns the chainable query.
    def where(constraints = nil)
      return query.compile_where unless constraints.is_a?(Hash)
      query.where constraints
      query
    end

    def channels=(list)
      @channels = Array.wrap(list)
    end

    # Check if this push has content-available set (silent push).
    # @return [Boolean] true if content-available is enabled
    def content_available?
      @content_available == true
    end

    # Check if this push has mutable-content set (rich notifications).
    # @return [Boolean] true if mutable-content is enabled
    def mutable_content?
      @mutable_content == true
    end

    def data=(h)
      if h.is_a?(String)
        @alert = h
      else
        @data = h.symbolize_keys
      end
    end

    # @return [Hash] a JSON encoded hash.
    def as_json(*args)
      payload.as_json
    end

    # @return [String] a JSON encoded string.
    def to_json(*args)
      as_json.to_json
    end

    # This method takes all the parameters of the instance and creates a proper
    # hash structure, required by Parse, in order to process the push notification.
    # @return [Hash] the prepared push payload to be used in the request.
    def payload
      msg = {
        data: {
          alert: alert,
          badge: badge || "Increment",
        },
      }
      msg[:data][:sound] = sound if sound.present?
      msg[:data][:title] = title if title.present?
      msg[:data][:"content-available"] = 1 if content_available?
      msg[:data][:"mutable-content"] = 1 if mutable_content?
      msg[:data][:category] = @category if @category.present?
      msg[:data][:image] = @image_url if @image_url.present?

      # Add localized alerts (e.g., "alert-en", "alert-fr")
      if @localized_alerts.is_a?(Hash)
        @localized_alerts.each do |lang, text|
          msg[:data][:"alert-#{lang}"] = text
        end
      end

      # Add localized titles (e.g., "title-en", "title-fr")
      if @localized_titles.is_a?(Hash)
        @localized_titles.each do |lang, text|
          msg[:data][:"title-#{lang}"] = text
        end
      end

      msg[:data].merge! @data if @data.is_a?(Hash)

      if @expiration_time.present?
        msg[:expiration_time] = @expiration_time.respond_to?(:iso8601) ? @expiration_time.iso8601(3) : @expiration_time
      end
      if @push_time.present?
        msg[:push_time] = @push_time.respond_to?(:iso8601) ? @push_time.iso8601(3) : @push_time
      end

      if @expiration_interval.is_a?(Numeric)
        msg[:expiration_interval] = @expiration_interval.to_i
      end

      if query.where.present?
        q = @query.dup
        if @channels.is_a?(Array) && @channels.empty? == false
          q.where :channels.in => @channels
        end
        msg[:where] = q.compile_where unless q.where.empty?
      elsif @channels.is_a?(Array) && @channels.empty? == false
        msg[:channels] = @channels
      end
      msg
    end

    # helper method to send a message
    # @param message [String] the message to send
    def send(message = nil)
      @alert = message if message.is_a?(String)
      @data = message if message.is_a?(Hash)
      client.push(payload.as_json)
    end

    # =========================================================================
    # Builder Pattern Methods (Fluent Interface)
    # =========================================================================

    # Target a specific channel for this push notification.
    # @param channel [String] the channel name to target
    # @return [self] returns self for method chaining
    # @example
    #   push.to_channel("news").with_alert("Update!").send!
    def to_channel(channel)
      self.channels = [channel]
      self
    end

    # Target multiple channels for this push notification.
    # @param channels [Array<String>] the channel names to target
    # @return [self] returns self for method chaining
    # @example
    #   push.to_channels("news", "sports").with_alert("Update!").send!
    def to_channels(*channels)
      self.channels = channels.flatten
      self
    end

    # Configure the push query using a block.
    # The block receives the query object for adding constraints.
    # @yield [Parse::Query] the Installation query to configure
    # @return [self] returns self for method chaining
    # @example
    #   push.to_query { |q| q.where(:device_type => "ios") }.send!
    def to_query
      yield query if block_given?
      self
    end

    # Set the alert message for this push notification.
    # @param message [String] the alert message
    # @return [self] returns self for method chaining
    # @example
    #   push.with_alert("Hello World!").send!
    def with_alert(message)
      self.alert = message
      self
    end

    # Alias for {#with_alert} - sets the body text of the notification.
    # @param body [String] the body/alert message
    # @return [self] returns self for method chaining
    # @see #with_alert
    def with_body(body)
      with_alert(body)
    end

    # Set the title for this push notification (appears above the alert).
    # @param title [String] the notification title
    # @return [self] returns self for method chaining
    # @example
    #   push.with_title("News").with_body("Article published").send!
    def with_title(title)
      self.title = title
      self
    end

    # Set the badge number for this push notification.
    # @param count [Integer, String] the badge count, or "Increment" to increment
    # @return [self] returns self for method chaining
    # @example
    #   push.with_badge(5).send!  # Set to 5
    #   push.with_badge(0).send!  # Clear badge
    def with_badge(count)
      self.badge = count
      self
    end

    # Set the sound file for this push notification.
    # @param sound_name [String] the name of the sound file
    # @return [self] returns self for method chaining
    # @example
    #   push.with_sound("notification.caf").send!
    def with_sound(sound_name)
      self.sound = sound_name
      self
    end

    # Set custom data payload for this push notification.
    # @param hash [Hash] custom key-value pairs to include in the payload
    # @return [self] returns self for method chaining
    # @example
    #   push.with_data(article_id: "123", action: "open").send!
    def with_data(hash)
      @data ||= {}
      @data.merge!(hash.symbolize_keys)
      self
    end

    # Schedule the push notification for a future time.
    # @param time [Time, DateTime, String] when to send the push
    # @return [self] returns self for method chaining
    # @example
    #   push.schedule(1.hour.from_now).send!
    #   push.schedule(Time.new(2025, 12, 25, 9, 0, 0)).send!
    def schedule(time)
      self.push_time = time
      self
    end

    # Set the expiration time for this push notification.
    # The push will not be delivered after this time.
    # @param time [Time, DateTime, String] when the push expires
    # @return [self] returns self for method chaining
    # @example
    #   push.expires_at(2.hours.from_now).send!
    def expires_at(time)
      self.expiration_time = time
      self
    end

    # Set the expiration interval for this push notification.
    # The push will expire after this many seconds from now.
    # @param seconds [Integer] number of seconds until expiration
    # @return [self] returns self for method chaining
    # @example
    #   push.expires_in(3600).send!  # Expires in 1 hour
    #   push.expires_in(86400).send! # Expires in 24 hours
    def expires_in(seconds)
      self.expiration_interval = seconds.to_i
      self
    end

    # Mark this as a silent push notification (iOS content-available).
    # Silent pushes wake the app in the background without displaying an alert.
    # @return [self] returns self for method chaining
    # @example
    #   push.silent!.with_data(action: "sync").send!
    # @see https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    def silent!
      @content_available = true
      self
    end

    # =========================================================================
    # Rich Push Methods (iOS Notification Service Extension)
    # =========================================================================

    # Add an image attachment to the push notification.
    # This automatically enables mutable-content for iOS service extension processing.
    # @param url [String] the URL of the image to attach
    # @return [self] returns self for method chaining
    # @example
    #   push.with_image("https://example.com/image.jpg").with_alert("Check this out!").send!
    # @see https://developer.apple.com/documentation/usernotifications/modifying_content_in_newly_delivered_notifications
    def with_image(url)
      @image_url = url
      @mutable_content = true
      self
    end

    # Set the notification category for action buttons (iOS).
    # Categories must be registered in the app's notification settings.
    # @param category_name [String] the notification category identifier
    # @return [self] returns self for method chaining
    # @example
    #   push.with_category("MESSAGE_ACTIONS").with_alert("New message").send!
    # @see https://developer.apple.com/documentation/usernotifications/declaring_your_actionable_notification_types
    def with_category(category_name)
      @category = category_name
      self
    end

    # Enable mutable-content for iOS notification service extension.
    # This allows the notification to be modified by a service extension before display.
    # @return [self] returns self for method chaining
    # @example
    #   push.mutable!.with_data(encrypted_body: "...").send!
    def mutable!
      @mutable_content = true
      self
    end

    # Send the push notification, raising an error on failure.
    # This is the bang version that raises {Parse::Error} if the push fails.
    # @return [Parse::Response] the response from the Parse server
    # @raise [Parse::Error] if the push notification fails
    # @example
    #   push.with_alert("Hello!").send!
    def send!
      response = client.push(payload.as_json)
      if response.error?
        raise Parse::Error.new(response.code, response.error)
      end
      response
    end

    # =========================================================================
    # Localization Methods
    # =========================================================================

    # Add a localized alert message for a specific language.
    # Parse Server will automatically send the appropriate message based on device locale.
    # @param lang [String, Symbol] the language code (e.g., :en, :fr, :es, :de)
    # @param message [String] the alert message in that language
    # @return [self] returns self for method chaining
    # @example
    #   push.with_localized_alert(:en, "Hello!")
    #       .with_localized_alert(:fr, "Bonjour!")
    #       .with_localized_alert(:es, "Hola!")
    #       .send!
    def with_localized_alert(lang, message)
      @localized_alerts ||= {}
      @localized_alerts[lang.to_s] = message
      self
    end

    # Add a localized title for a specific language.
    # Parse Server will automatically send the appropriate title based on device locale.
    # @param lang [String, Symbol] the language code (e.g., :en, :fr, :es, :de)
    # @param title [String] the title in that language
    # @return [self] returns self for method chaining
    # @example
    #   push.with_localized_title(:en, "Welcome")
    #       .with_localized_title(:fr, "Bienvenue")
    #       .with_alert("Default message")
    #       .send!
    def with_localized_title(lang, title)
      @localized_titles ||= {}
      @localized_titles[lang.to_s] = title
      self
    end

    # Set multiple localized alerts at once.
    # @param translations [Hash] a hash of language codes to messages
    # @return [self] returns self for method chaining
    # @example
    #   push.with_localized_alerts(en: "Hello!", fr: "Bonjour!", es: "Hola!").send!
    def with_localized_alerts(translations)
      @localized_alerts ||= {}
      translations.each { |lang, msg| @localized_alerts[lang.to_s] = msg }
      self
    end

    # Set multiple localized titles at once.
    # @param translations [Hash] a hash of language codes to titles
    # @return [self] returns self for method chaining
    # @example
    #   push.with_localized_titles(en: "Welcome", fr: "Bienvenue").send!
    def with_localized_titles(translations)
      @localized_titles ||= {}
      translations.each { |lang, title| @localized_titles[lang.to_s] = title }
      self
    end

    # =========================================================================
    # Badge Increment Methods
    # =========================================================================

    # Increment the badge count instead of setting an absolute value.
    # This is useful when you want to add to the existing badge rather than replace it.
    # @param amount [Integer] the amount to increment by (default: 1)
    # @return [self] returns self for method chaining
    # @example
    #   push.increment_badge.with_alert("New message!").send!     # +1
    #   push.increment_badge(5).with_alert("5 new items!").send!  # +5
    def increment_badge(amount = 1)
      if amount == 1
        self.badge = "Increment"
      else
        self.badge = { "__op" => "Increment", "amount" => amount.to_i }
      end
      self
    end

    # Clear the badge (set to 0).
    # @return [self] returns self for method chaining
    # @example
    #   push.clear_badge.silent!.send!  # Clear badge silently
    def clear_badge
      self.badge = 0
      self
    end

    # =========================================================================
    # Audience Targeting Methods
    # =========================================================================

    # Target a saved audience by name.
    # Audiences are pre-defined in the _Audience collection and can be reused.
    # Uses caching by default for better performance.
    #
    # @param audience_name [String] the name of the saved audience
    # @param cache [Boolean] whether to use audience cache (default: true)
    # @return [self] returns self for method chaining
    # @raise [ArgumentError] if audience is not found and strict mode is enabled
    # @example
    #   push.to_audience("VIP Users").with_alert("Exclusive offer!").send!
    # @note The audience must exist in the _Audience collection
    def to_audience(audience_name, cache: true)
      # Use cached audience lookup for better performance
      audience = Parse::Audience.find_by_name(audience_name, cache: cache)

      if audience.nil?
        warn "[Parse::Push] Warning: Audience '#{audience_name}' not found"
        return self
      end

      if audience.query_constraint.present?
        # Merge the audience's query constraints into our query
        audience.query_constraint.each do |key, value|
          query.where(key.to_sym => value)
        end
      end
      self
    end

    # Target a saved audience by its object ID.
    # @param audience_id [String] the objectId of the saved audience
    # @return [self] returns self for method chaining
    # @example
    #   push.to_audience_id("abc123").with_alert("Hello!").send!
    def to_audience_id(audience_id)
      audience = Parse::Audience.find(audience_id)
      if audience && audience.query_constraint.present?
        audience.query_constraint.each do |key, value|
          query.where(key.to_sym => value)
        end
      end
      self
    end

    # =========================================================================
    # User Targeting Methods
    # =========================================================================

    # Target installations belonging to a specific user (or multiple users).
    # This queries the Installation collection for devices where the user pointer
    # matches the given user(s).
    #
    # @param user [Parse::User, Hash, String, Array] the user(s) to target. Can be:
    #   - A Parse::User object
    #   - A pointer hash (e.g., { "__type" => "Pointer", "className" => "_User", "objectId" => "abc123" })
    #   - A user objectId string (will be converted to a pointer)
    #   - An array of any of the above (delegates to to_users)
    # @return [self] returns self for method chaining
    # @example With a Parse::User object
    #   user = Parse::User.find("abc123")
    #   Parse::Push.new.to_user(user).with_alert("Hello!").send!
    #
    # @example With a user objectId
    #   Parse::Push.new.to_user("abc123").with_alert("Hello!").send!
    #
    # @example With an array of users
    #   Parse::Push.new.to_user([user1, user2]).with_alert("Hello!").send!
    #
    # @example Using class method shortcut
    #   Parse::Push.to_user(current_user).with_alert("Welcome back!").send!
    def to_user(user)
      # Delegate to to_users if given an array
      return to_users(user) if user.is_a?(Array)

      pointer = case user
        when Parse::User
          user.pointer
        when Hash
          user
        when String
          Parse::Pointer.new(Parse::Model::CLASS_USER, user).to_h
        else
          raise ArgumentError, "Expected Parse::User, Hash, String, or Array, got #{user.class}"
        end

      query.where(user: pointer)
      self
    end

    # Target installations belonging to a user by their objectId.
    # This is a convenience method equivalent to to_user with a string ID.
    #
    # @param user_id [String] the objectId of the user to target
    # @return [self] returns self for method chaining
    # @example
    #   Parse::Push.new.to_user_id("abc123").with_alert("Hello!").send!
    #
    # @example Using class method shortcut
    #   Parse::Push.to_user_id("abc123").with_alert("You have a message").send!
    def to_user_id(user_id)
      pointer = Parse::Pointer.new(Parse::Model::CLASS_USER, user_id).to_h
      query.where(user: pointer)
      self
    end

    # Target installations belonging to multiple users.
    # This queries the Installation collection for devices where the user pointer
    # matches any of the given users.
    #
    # @param users [Array<Parse::User, Hash, String>] the users to target
    # @return [self] returns self for method chaining
    # @example
    #   Parse::Push.new.to_users(user1, user2, user3).with_alert("Group message!").send!
    #
    # @example With user IDs
    #   Parse::Push.new.to_users("id1", "id2", "id3").with_alert("Hello everyone!").send!
    def to_users(*users)
      pointers = users.flatten.map do |user|
        case user
        when Parse::User
          user.pointer
        when Hash
          user
        when String
          Parse::Pointer.new(Parse::Model::CLASS_USER, user).to_h
        else
          raise ArgumentError, "Expected Parse::User, Hash, or String, got #{user.class}"
        end
      end

      query.where(:user.in => pointers)
      self
    end

    # =========================================================================
    # Installation Targeting Methods
    # =========================================================================

    # Target a specific installation (or multiple installations) by object or objectId.
    # This directly targets device installation(s).
    #
    # When given a Parse::Installation object, this method validates:
    # - The installation has a device_token (raises ArgumentError if missing)
    # - The device_type is supported for push (warns if unsupported)
    #
    # @param installation [Parse::Installation, Hash, String, Array] the installation(s) to target. Can be:
    #   - A Parse::Installation object
    #   - A hash with objectId key
    #   - An objectId string
    #   - An array of any of the above (delegates to to_installations)
    # @return [self] returns self for method chaining
    # @raise [ArgumentError] if installation object has no device_token
    # @example With a Parse::Installation object
    #   device = Parse::Installation.find("abc123")
    #   Parse::Push.new.to_installation(device).with_alert("Hello!").send!
    #
    # @example With an objectId
    #   Parse::Push.new.to_installation("abc123").with_alert("Hello!").send!
    #
    # @example With an array of installations
    #   Parse::Push.new.to_installation([device1, device2]).with_alert("Hello!").send!
    #
    # @example Using class method shortcut
    #   Parse::Push.to_installation(device).with_alert("Device notification").send!
    def to_installation(installation)
      # Delegate to to_installations if given an array
      return to_installations(installation) if installation.is_a?(Array)

      object_id = case installation
        when Parse::Installation
          validate_installation_for_push!(installation)
          installation.id
        when Hash
          installation[:objectId] || installation["objectId"] || installation[:id] || installation["id"]
        when String
          installation
        else
          raise ArgumentError, "Expected Parse::Installation, Hash, String, or Array, got #{installation.class}"
        end

      query.where(objectId: object_id)
      self
    end

    # Target a specific installation by its objectId.
    # This is a convenience method equivalent to to_installation with a string ID.
    #
    # @param installation_id [String] the objectId of the installation to target
    # @return [self] returns self for method chaining
    # @example
    #   Parse::Push.new.to_installation_id("abc123").with_alert("Hello!").send!
    #
    # @example Using class method shortcut
    #   Parse::Push.to_installation_id("abc123").with_alert("Device notification").send!
    def to_installation_id(installation_id)
      query.where(objectId: installation_id)
      self
    end

    # Target multiple installations.
    # This queries the Installation collection for devices matching any of the given
    # installation objectIds.
    #
    # When given Parse::Installation objects, this method validates each:
    # - The installation has a device_token (raises ArgumentError if missing)
    # - The device_type is supported for push (warns if unsupported)
    #
    # @param installations [Array<Parse::Installation, Hash, String>] the installations to target
    # @return [self] returns self for method chaining
    # @raise [ArgumentError] if any installation object has no device_token
    # @example
    #   Parse::Push.new.to_installations(device1, device2, device3).with_alert("Group notification!").send!
    #
    # @example With objectIds
    #   Parse::Push.new.to_installations("id1", "id2", "id3").with_alert("Hello devices!").send!
    def to_installations(*installations)
      object_ids = installations.flatten.map do |installation|
        case installation
        when Parse::Installation
          validate_installation_for_push!(installation)
          installation.id
        when Hash
          installation[:objectId] || installation["objectId"] || installation[:id] || installation["id"]
        when String
          installation
        else
          raise ArgumentError, "Expected Parse::Installation, Hash, or String, got #{installation.class}"
        end
      end

      query.where(:objectId.in => object_ids)
      self
    end

    private

    # Validate that an installation can receive push notifications.
    # @param installation [Parse::Installation] the installation to validate
    # @raise [ArgumentError] if the installation has no device_token
    # @return [void]
    def validate_installation_for_push!(installation)
      # Access instance variables directly to avoid triggering autofetch
      device_token = installation.instance_variable_get(:@device_token)
      device_type = installation.instance_variable_get(:@device_type).to_s
      installation_id = installation.id

      # Check for device_token - required for push delivery
      if device_token.blank?
        raise ArgumentError,
          "Cannot send push to installation #{installation_id}: missing device_token. " \
          "Push notifications require a valid device_token."
      end

      # Check for unsupported device types - warn but allow
      if device_type.present? && !SUPPORTED_PUSH_DEVICE_TYPES.include?(device_type)
        if UNSUPPORTED_PUSH_DEVICE_TYPES.include?(device_type)
          warn "[Parse::Push] Warning: device_type '#{device_type}' may not be supported for push notifications. " \
               "Supported types: #{SUPPORTED_PUSH_DEVICE_TYPES.join(', ')}"
        else
          warn "[Parse::Push] Warning: unknown device_type '#{device_type}' for installation #{installation_id}. " \
               "This device type may not receive push notifications. " \
               "Supported types: #{SUPPORTED_PUSH_DEVICE_TYPES.join(', ')}"
        end
      end
    end
  end
end
