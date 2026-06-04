# encoding: UTF-8
# frozen_string_literal: true
# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_Installation` collection. This class is also responsible for managing the
  # device tokens for mobile devices in order to use push notifications. All queries done
  # to send pushes using Parse::Push are performed against the Installation collection.
  # An installation object represents an instance of your app being installed
  # on a device. These objects are used to store subscription data for
  # installations which have subscribed to one or more push notification channels.
  #
  # The default schema for {Installation} is as follows:
  #
  #   class Parse::Installation < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #     property :gcm_sender_id, field: :GCMSenderId
  #     property :app_identifier
  #     property :app_name
  #     property :app_version
  #     property :app_build_number
  #     property :badge, :integer
  #     property :channels, :array
  #     property :device_token
  #     property :device_token_last_modified, :integer
  #     property :device_type, enum: [:ios, :android, :osx, :tvos, :watchos, :web, :expo, :win, :other, :unknown, :unsupported]
  #     property :installation_id
  #     property :locale_identifier
  #     property :parse_version
  #     property :push_type
  #     property :time_zone, :timezone
  #
  #     has_one :session, ->{ where(installation_id: i.installation_id) }, scope_only: true
  #   end
  # ## Class-Level Permissions on `_Installation`
  #
  # `_Installation` is special-cased inside Parse Server. Some operations are
  # hardcoded at the REST layer and CANNOT be relaxed via CLP — calling
  # {Parse::Object.set_clp} for them has no effect on the server's actual
  # behavior, regardless of what you pass. Other operations work the way
  # CLP normally does. The matrix:
  #
  # | Operation  | Behavior                                                                                  |
  # |------------|-------------------------------------------------------------------------------------------|
  # | `find`     | **Master key only. Hardcoded.** `set_clp :find, ...` is effectively ignored by the server. |
  # | `delete`   | **Master key only. Hardcoded.** `set_clp :delete, ...` is effectively ignored by the server. |
  # | `create`   | Open to anonymous clients (the `X-Parse-Installation-Id` header is the credential). Locking via CLP breaks first-launch device registration. |
  # | `update`   | Open to clients whose `installationId` matches the record; else master key. Locking via CLP breaks silent device-token refresh and channel subscribe/unsubscribe before login. |
  # | `get`      | CLP applies normally. Safe to tighten — SDKs don't usually GET their own installation from the server. |
  # | `count`    | CLP applies normally. Safe to tighten to master-only (the push flow doesn't need it). |
  # | `addField` | CLP applies normally. Safe to tighten to master-only as a hardening default. |
  #
  # ### What you can safely do with `set_clp` on `_Installation`
  #
  # * `set_clp :get, requires_authentication: true` (or `{}` for master-only)
  # * `set_clp :count` (master-only)
  # * `set_clp :addField` (master-only)
  # * {Parse::Object.protect_fields} to hide `device_token`, `gcm_sender_id`,
  #   `push_type`, etc. from non-master reads — these are write-only from the
  #   client's perspective in normal SDK flows.
  #
  # ### What you should NOT do with `set_clp` on `_Installation`
  #
  # * `set_clp :create, requires_authentication: true` — breaks device
  #   registration for users who haven't logged in yet.
  # * `set_clp :update, requires_authentication: true` — breaks background
  #   device-token refresh and pre-login channel subscribe/unsubscribe.
  # * Pointer-based `set_read_user_fields` / `set_write_user_fields` —
  #   an installation has no stable owning user (a device can outlive a user
  #   session and change users), so user-pointer ACLing is unreliable here.
  # * `set_clp :find, public: true` (or any other `:find` config) —
  #   has no effect; the server enforces master-only at the REST layer.
  #
  # If your app actually does require login before any installation write,
  # put that policy in a `beforeSave('_Installation')` Cloud Code trigger
  # rather than in CLP — the trigger fires under master-key context and can
  # inspect `request.user` directly without breaking the SDK's anonymous
  # registration handshake.
  #
  # @see Push
  # @see Parse::Object
  class Installation < Parse::Object
    parse_class Parse::Model::CLASS_INSTALLATION

    # The CLP operations Parse Server does NOT honor on `_Installation`:
    # `find` and `delete` are hardcoded master-key-only at the REST layer,
    # and `create`/`update` are gated on the `X-Parse-Installation-Id`
    # header rather than CLP. Setting CLP for any of these either does
    # nothing or breaks the SDK's device-registration flow, so the advisory
    # fires only for them. `get`, `count`, `addField`, and `protectedFields`
    # respond to CLP normally and are configured without a warning.
    INEFFECTIVE_CLP_OPERATIONS = %i[find create update delete].freeze

    class << self
      # Override {Parse::Object.set_clp} on `_Installation` so that an
      # attempt to change CLP for an operation the server ignores emits a
      # one-time advisory. CLP changes for `get` / `count` / `addField`
      # take effect normally and are applied without a warning. Behavior is
      # otherwise unchanged.
      def set_clp(operation, **opts)
        _warn_about_installation_clp!(:set_clp, operation) if _installation_clp_ineffective?(operation)
        super
      end

      # Same advisory for the bulk-config DSL — warn only about the keys that
      # name an ineffective operation, and stay silent when the caller only
      # touches the operations CLP actually controls.
      def set_class_access(**ops_to_access)
        offending = ops_to_access.keys.select { |op| _installation_clp_ineffective?(op) }
        _warn_about_installation_clp!(:set_class_access, offending) unless offending.empty?
        super
      end

      # `protect_fields` on `_Installation` is a documented-legitimate use
      # (e.g. hiding `device_token` / `gcm_sender_id` / `push_type` from
      # non-master reads), so we deliberately do NOT fire the
      # find/delete-are-hardcoded advisory here. The advisory exists to
      # nudge callers away from CLP changes that the server ignores;
      # protectedFields is one of the four operations on _Installation
      # that CLP actually controls.
      def protect_fields(pattern, fields)
        super
      end

      # Pointer-permission helpers on `_Installation` are a mistake in
      # practice (devices have no stable owning user); warn loudly.
      def set_read_user_fields(*fields)
        _warn_about_installation_clp!(:set_read_user_fields, fields)
        super
      end

      def set_write_user_fields(*fields)
        _warn_about_installation_clp!(:set_write_user_fields, fields)
        super
      end

      # @!visibility private
      # Whether a CLP operation is one Parse Server ignores on `_Installation`
      # (and therefore worth warning about). Normalizes Strings/Symbols.
      def _installation_clp_ineffective?(operation)
        INEFFECTIVE_CLP_OPERATIONS.include?(operation.to_s.to_sym)
      end

      # @!visibility private
      def _warn_about_installation_clp!(method, detail)
        return if @_installation_clp_warned
        @_installation_clp_warned = true
        msg = "[Parse::Installation] #{method}(#{Array(detail).inspect}) on _Installation: " \
              "Parse Server hardcodes find/delete on _Installation to master-key-only " \
              "(CLP changes for those operations are ignored), and gates create/update " \
              "on the X-Parse-Installation-Id header rather than CLP. Only get, count, " \
              "addField, and protectedFields actually respond to CLP here. " \
              "If you need login-required writes, use a beforeSave('_Installation') " \
              "Cloud Code trigger instead. See Parse::Installation docs and " \
              "docs/client_sdk_guide.md §6.3."
        if Parse.respond_to?(:logger) && Parse.logger
          Parse.logger.warn(msg)
        else
          Kernel.warn(msg)
        end
      end
    end
    # @!attribute gcm_sender_id
    # This field only has meaning for Android installations that use the GCM
    # push type. It is reserved for directing Parse to send pushes to this
    # installation with an alternate GCM sender ID. This field should generally
    # not be set unless you are uploading installation data from another push
    # provider. If you set this field, then you must set the GCM API key
    # corresponding to this GCM sender ID in your Parse application’s push settings.
    # @return [String]
    property :gcm_sender_id, field: :GCMSenderId

    # @!attribute app_identifier
    # A unique identifier for this installation’s client application. In iOS, this is the Bundle Identifier.
    # @return [String]
    property :app_identifier

    # @!attribute app_name
    # The display name of the client application to which this installation belongs.
    # @return [String]
    property :app_name

    # @!attribute app_version
    # The version string of the client application to which this installation belongs.
    # @return [String]
    property :app_version

    # @!attribute app_build_number
    # The build number of the client application to which this installation belongs.
    # @return [String]
    property :app_build_number

    # @!attribute badge
    # A number field representing the last known application badge for iOS installations.
    # @return [Integer]
    property :badge, :integer

    # @!attribute channels
    # An array of the channels to which a device is currently subscribed.
    # Note that **channelUris** (the Microsoft-generated push URIs for Windows devices) is
    # not supported at this time.
    # @return [Array]
    property :channels, :array

    # @!attribute device_token
    # The Apple or Google generated token used to deliver messages to the APNs
    # or GCM push networks respectively.
    # @return [String]
    property :device_token

    # @!attribute device_token_last_modified
    # @return [Integer] number of seconds since token modified
    property :device_token_last_modified, :integer

    # @!attribute device_type
    # The type of device: "ios", "android", "osx", "tvos", "watchos", "web", "expo", "win",
    # "other", "unknown", or "unsupported".
    # This property is implemented as a Parse::Stack enumeration.
    # @return [String]
    property :device_type, enum: [:ios, :android, :osx, :tvos, :watchos, :web, :expo, :win, :other, :unknown, :unsupported]

    # @!attribute installation_id
    # Universally Unique Identifier (UUID) for the device used by Parse. It
    # must be unique across all of an app’s installations. (readonly).
    # @return [String]
    property :installation_id

    # @!attribute locale_identifier
    # The locale for this device.
    # @return [String]
    property :locale_identifier

    # @!attribute parse_version
    # The version of the Parse SDK which this installation uses.
    # @return [String]
    property :parse_version

    # @!attribute push_type
    # This field is reserved for directing Parse to the push delivery network
    # to be used. If the device is registered to receive pushes via GCM, this
    # field will be marked “gcm”. If this device is not using GCM, and is
    # using Parse’s push notification service, it will be blank (readonly).
    # @return [String]
    property :push_type

    # @!attribute time_zone
    # The current time zone where the target device is located. This should be an IANA time zone identifier
    # or a {Parse::TimeZone} instance.
    # @return [Parse::TimeZone]
    property :time_zone, :timezone

    # @!attribute session
    # Returns the corresponding {Parse::Session} associated with this installation, if any exists.
    # This is implemented as a has_one association to the Session class using the {installation_id}.
    # @version 1.7.1
    # @return [Parse::Session] The associated {Parse::Session} that might be tied to this installation
    has_one :session, -> { where(installation_id: i.installation_id) }, scope_only: true

    # @!attribute user
    # The {Parse::User} associated with this installation. Parse Server
    # populates this pointer when the installation is created or updated
    # by an authenticated client (the session-token holder on the
    # request). It is useful for targeted push delivery — finding all
    # installations belonging to a given user.
    #
    # **Caveat — do not use for ACL or CLP scoping.** Devices outlive
    # sessions and can change users (account switch, sign-out, shared
    # device), so the `user` pointer on `_Installation` is not a
    # reliable owner identity. See the "What you should NOT do with
    # `set_clp`" notes above for the broader context.
    # @return [Parse::User]
    belongs_to :user

    # =========================================================================
    # Channel Management - Class Methods
    # =========================================================================

    class << self
      # List all unique channel names across all installations.
      # @return [Array<String>] array of channel names
      # @example
      #   all_channels = Parse::Installation.all_channels
      #   # => ["news", "sports", "weather"]
      def all_channels
        distinct(:channels)
      end

      # Count the number of installations subscribed to a specific channel.
      # @param channel [String] the channel name to count subscribers for
      # @return [Integer] the number of subscribers
      # @example
      #   count = Parse::Installation.subscribers_count("news")
      #   # => 1250
      def subscribers_count(channel)
        query(:channels.in => [channel]).count
      end

      # Get a query for installations subscribed to a specific channel.
      # @param channel [String] the channel name to find subscribers for
      # @return [Parse::Query] a query scoped to the channel's subscribers
      # @example
      #   # Get all iOS subscribers to the "news" channel
      #   installations = Parse::Installation.subscribers("news")
      #     .where(device_type: "ios")
      #     .all
      def subscribers(channel)
        query(:channels.in => [channel])
      end

      # =========================================================================
      # Device Type Scopes
      # =========================================================================
      # Note: ios and android scopes are automatically created by the enum property:
      #   property :device_type, enum: [:ios, :android, :osx, :tvos, :watchos, :web, :expo, :win, :other, :unknown, :unsupported]
      # This creates: Installation.ios, Installation.android, etc.

      # Query scope for a specific device type.
      # @param type [String, Symbol] the device type (ios, android, osx, tvos, watchos, web, expo, win, other, unknown, unsupported)
      # @return [Parse::Query] a query for the specified device type
      # @example
      #   mac_devices = Parse::Installation.by_device_type(:osx).all
      def by_device_type(type)
        query(device_type: type.to_s)
      end

      # =========================================================================
      # Badge Management
      # =========================================================================

      # Reset badge count for all installations in a channel.
      # @param channel [String] the channel name
      # @return [Integer] the number of installations updated
      # @example
      #   Parse::Installation.reset_badges_for_channel("news")
      def reset_badges_for_channel(channel)
        installations = subscribers(channel).where(:badge.gt => 0).all
        installations.each do |installation|
          installation.badge = 0
          installation.save
        end
        installations.count
      end

      # Reset badge count for all installations of a specific device type.
      # @param type [String, Symbol] the device type (default: :ios since badges are primarily iOS)
      # @return [Integer] the number of installations updated
      # @example
      #   Parse::Installation.reset_all_badges
      #   Parse::Installation.reset_all_badges(:android)
      def reset_all_badges(type = :ios)
        installations = by_device_type(type).where(:badge.gt => 0).all
        installations.each do |installation|
          installation.badge = 0
          installation.save
        end
        installations.count
      end

      # =========================================================================
      # Stale Token Detection
      # =========================================================================

      # Query for installations with stale (old) device tokens.
      # Useful for cleaning up installations that are likely no longer active.
      # @param days [Integer] number of days since last token modification (default: 90)
      # @return [Parse::Query] a query for installations with old tokens
      # @example
      #   # Find installations not updated in 90 days
      #   stale = Parse::Installation.stale_tokens.all
      #
      #   # Find installations not updated in 30 days
      #   stale = Parse::Installation.stale_tokens(days: 30).all
      def stale_tokens(days: 90)
        cutoff = Time.now - (days * 24 * 60 * 60)
        query(:updated_at.lt => cutoff)
      end

      # Count installations with stale tokens.
      # @param days [Integer] number of days since last update (default: 90)
      # @return [Integer] count of stale installations
      # @example
      #   count = Parse::Installation.stale_count(days: 60)
      def stale_count(days: 90)
        stale_tokens(days: days).count
      end

      # Delete all installations with stale tokens.
      # Use with caution - this permanently removes installation records.
      # @param days [Integer] number of days since last update (default: 90)
      # @return [Integer] the number of installations deleted
      # @example
      #   # Clean up installations not updated in 180 days
      #   deleted = Parse::Installation.cleanup_stale_tokens!(days: 180)
      def cleanup_stale_tokens!(days: 90)
        installations = stale_tokens(days: days).all
        installations.each(&:destroy)
        installations.count
      end
    end

    # =========================================================================
    # Channel Management - Instance Methods
    # =========================================================================

    # Subscribe this installation to one or more channels.
    # The changes are automatically saved to the server.
    # @param channel_names [Array<String>] the channel names to subscribe to
    # @return [Boolean] true if the save was successful
    # @example
    #   installation.subscribe("news", "weather")
    #   installation.subscribe(["sports", "updates"])
    def subscribe(*channel_names)
      self.channels ||= []
      self.channels = (self.channels + channel_names.flatten.map(&:to_s)).uniq
      save
    end

    # Unsubscribe this installation from one or more channels.
    # The changes are automatically saved to the server.
    # @param channel_names [Array<String>] the channel names to unsubscribe from
    # @return [Boolean] true if the save was successful, or true if no channels were set
    # @example
    #   installation.unsubscribe("news")
    #   installation.unsubscribe("sports", "weather")
    def unsubscribe(*channel_names)
      return true unless channels.present?
      self.channels = channels - channel_names.flatten.map(&:to_s)
      save
    end

    # Check if this installation is subscribed to a specific channel.
    # @param channel [String] the channel name to check
    # @return [Boolean] true if subscribed to the channel
    # @example
    #   if installation.subscribed_to?("news")
    #     puts "Subscribed to news!"
    #   end
    def subscribed_to?(channel)
      channels&.include?(channel.to_s) || false
    end

    # =========================================================================
    # Badge Management - Instance Methods
    # =========================================================================

    # Reset the badge count to 0 and save.
    # @return [Boolean] true if save was successful
    # @example
    #   installation.reset_badge!
    def reset_badge!
      self.badge = 0
      save
    end

    # Increment the badge count and save.
    # @param amount [Integer] amount to increment by (default: 1)
    # @return [Boolean] true if save was successful
    # @example
    #   installation.increment_badge!
    #   installation.increment_badge!(5)
    def increment_badge!(amount = 1)
      self.badge = (badge || 0) + amount
      save
    end

    # =========================================================================
    # Stale Token Detection - Instance Methods
    # =========================================================================

    # Check if this installation's token is considered stale.
    # @param days [Integer] number of days to consider stale (default: 90)
    # @return [Boolean] true if the installation hasn't been updated in the given days
    # @example
    #   if installation.stale?
    #     puts "This installation may no longer be active"
    #   end
    def stale?(days: 90)
      return false if updated_at.nil?
      cutoff = Time.now - (days * 24 * 60 * 60)
      updated_at < cutoff
    end

    # Get the number of days since this installation was last updated.
    # @return [Integer, nil] days since last update, or nil if no updated_at
    # @example
    #   puts "Last active #{installation.days_since_update} days ago"
    def days_since_update
      return nil if updated_at.nil?
      ((Time.now - updated_at.to_time) / (24 * 60 * 60)).to_i
    end

    # =========================================================================
    # Device Type Helpers - Instance Methods
    # =========================================================================
    # Note: ios? and android? predicates are automatically created by the enum property:
    #   property :device_type, enum: [:ios, :android, :osx, :tvos, :watchos, :web, :expo, :win, :other, :unknown, :unsupported]
    # This creates: installation.ios?, installation.android?, etc.
  end
end
