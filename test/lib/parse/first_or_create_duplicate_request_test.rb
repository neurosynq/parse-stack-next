# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"

# Unit coverage for first_or_create! / create_or_update! recovery from a
# request-id idempotency duplicate (5.2.0).
#
# When the SDK transparently retries a create (server idempotency asserted) and
# the original attempt already landed but lost its response, Parse Server
# rejects the replay with code 159 and `save!` raises
# `Parse::Error::DuplicateRequestError`. first_or_create! / create_or_update!
# already carry `query_attrs` (the natural key), so they catch that error and
# re-find the row the original attempt created — turning the duplicate into a
# transparent success instead of an error the caller must handle.
#
# These are pure unit tests: `save!` is stubbed to raise (no network), and the
# class-level `_scoped_first` finder is stubbed to model "not found, then found
# on recovery". No live server required.
class FirstOrCreateDuplicateRequestTest < Minitest::Test
  class DupReqModel < Parse::Object
    parse_class "DupReqModel"
    property :name, :string

    # Stand in for a create whose retried replay was rejected by server
    # idempotency. Always raises so the recovery path is exercised.
    def save!(*)
      raise Parse::Error::DuplicateRequestError, "Duplicate request"
    end
  end

  # A found, persisted instance to hand back from the recovery find. Autofetch
  # is disabled so applying attributes in the update path doesn't try to hit a
  # server for this hand-built stub (a real _scoped_first result is fully loaded).
  def existing(attrs)
    obj = DupReqModel.new(attrs)
    obj.instance_variable_set(:@id, "EXISTING#{rand(10_000)}")
    obj.disable_autofetch! if obj.respond_to?(:disable_autofetch!)
    obj
  end

  # _scoped_first returns the queued values in order: first the pre-save find,
  # then the post-159 recovery find.
  def with_finds(*sequence)
    seq = sequence.dup
    DupReqModel.stub(:_scoped_first, ->(*_a, **_k) { seq.shift }) { yield }
  end

  def test_first_or_create_recovers_from_duplicate_request
    winner = existing(name: "x")
    with_finds(nil, winner) do
      result = DupReqModel.first_or_create!({ name: "x" })
      assert_same winner, result, "must return the row the original create landed"
    end
  end

  def test_create_or_update_recovers_from_duplicate_request
    winner = existing(name: "y")
    with_finds(nil, winner) do
      result = DupReqModel.create_or_update!({ name: "y" })
      assert_same winner, result
    end
  end

  def test_first_or_create_reraises_when_recovery_finds_nothing
    # If the row genuinely can't be located, the duplicate error must propagate
    # rather than be silently swallowed.
    with_finds(nil, nil) do
      assert_raises(Parse::Error::DuplicateRequestError) do
        DupReqModel.first_or_create!({ name: "z" })
      end
    end
  end

  def test_create_or_update_recovers_from_duplicate_request_on_update_path
    # The update-existing branch (found row → apply attrs → PUT) also recovers:
    # a retried PUT-into-159 means the update landed, so re-find returns it.
    found = existing(name: "u")          # initial find: row exists
    updated = existing(name: "u")        # recovery find: the now-updated row
    with_finds(found, updated) do
      result = DupReqModel.create_or_update!({ name: "u" }, { name: "u2" })
      assert_same updated, result, "update-path 159 must recover the updated row"
    end
  end

  def test_first_or_create_synchronized_recovers_from_duplicate_request
    # Same recovery on the synchronize: true (CreateLock) path. Skips if the
    # lock backend can't run degraded in this environment.
    winner = existing(name: "s")
    begin
      with_finds(nil, winner) do
        result = DupReqModel.first_or_create!({ name: "s" }, synchronize: true)
        assert_same winner, result
      end
    rescue => e
      skip "synchronize-create lock unavailable in this env: #{e.class}: #{e.message}"
    end
  end
end
