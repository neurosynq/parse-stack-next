# encoding: UTF-8
# frozen_string_literal: true

# Load all custom validators for Parse Stack
require_relative "validations/uniqueness_validator"

module Parse
  # The Validations module provides custom validators for Parse::Object subclasses.
  #
  # Parse Stack builds on ActiveModel::Validations, which means all standard Rails
  # validations are available:
  #
  # - `validates :field, presence: true`
  # - `validates :field, length: { minimum: 1, maximum: 200 }`
  # - `validates :field, numericality: { greater_than: 0 }`
  # - `validates :field, format: { with: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i }`
  # - `validates :field, inclusion: { in: %w[small medium large] }`
  # - `validates :field, exclusion: { in: %w[admin root] }`
  #
  # In addition, Parse Stack provides:
  #
  # - `validates :field, uniqueness: true` - Queries Parse to ensure uniqueness
  #
  # @example Full validation example
  #   class User < Parse::Object
  #     property :email, :string
  #     property :username, :string
  #     property :age, :integer
  #     property :status, :string
  #
  #     # Standard ActiveModel validations
  #     validates :email, presence: true,
  #                       format: { with: URI::MailTo::EMAIL_REGEXP }
  #     validates :username, presence: true,
  #                          length: { minimum: 3, maximum: 30 }
  #     validates :age, numericality: { greater_than_or_equal_to: 0 },
  #                     allow_nil: true
  #     validates :status, inclusion: { in: %w[active inactive pending] }
  #
  #     # Parse-specific uniqueness validation
  #     validates :email, uniqueness: true
  #     validates :username, uniqueness: { case_sensitive: false }
  #
  #     # Custom validation method
  #     validate :email_domain_allowed
  #
  #     private
  #
  #     def email_domain_allowed
  #       return if email.blank?
  #       domain = email.split('@').last
  #       unless %w[company.com partner.org].include?(domain)
  #         errors.add(:email, "must be from an allowed domain")
  #       end
  #     end
  #   end
  #
  # @example Validation callbacks
  #   class Song < Parse::Object
  #     property :title, :string
  #
  #     validates :title, presence: true
  #
  #     before_validation :normalize_title
  #     after_validation :log_validation_result
  #
  #     private
  #
  #     def normalize_title
  #       self.title = title.strip.titleize if title.present?
  #     end
  #
  #     def log_validation_result
  #       if errors.any?
  #         puts "Validation failed: #{errors.full_messages.join(', ')}"
  #       end
  #     end
  #   end
  #
  # @example Conditional validations
  #   class Order < Parse::Object
  #     property :status, :string
  #     property :shipping_address, :string
  #     property :tracking_number, :string
  #
  #     validates :shipping_address, presence: true, if: :requires_shipping?
  #     validates :tracking_number, presence: true, if: -> { status == "shipped" }
  #
  #     def requires_shipping?
  #       status.in?(%w[processing shipped delivered])
  #     end
  #   end
  #
  module Validations
  end
end
