# frozen_string_literal: true

require_relative "test_helper"

# Covers Ask::AGUI::RunStore::InMemory: per-thread recording, replay, and
# cooperative stop flags.
class RunStoreTest < Minitest::Test
  def new_store
    Ask::AGUI::RunStore::InMemory.new
  end

  def test_records_and_replays_frames_per_thread
    store = new_store
    store.begin_run("t1", "r1")
    store.record("t1", "data: {\"type\":\"RUN_STARTED\"}\n\n")
    store.record("t1", "data: {\"type\":\"RUN_FINISHED\"}\n\n")
    store.finish_run("t1")

    assert_equal [
      "data: {\"type\":\"RUN_STARTED\"}\n\n",
      "data: {\"type\":\"RUN_FINISHED\"}\n\n"
    ], store.replay("t1")
  end

  def test_replays_nothing_for_unknown_threads
    assert_equal [], new_store.replay("nope")
  end

  def test_threads_do_not_see_each_other
    store = new_store
    store.begin_run("t1", "r1")
    store.record("t1", "data: 1\n\n")
    store.finish_run("t1")

    assert_equal [], store.replay("t2")
  end

  def test_stop_flags_a_thread_until_the_next_run_begins
    store = new_store

    refute store.stop_requested?("t1")
    assert_equal true, store.request_stop("t1")
    assert store.stop_requested?("t1")

    store.begin_run("t1", "r2")
    refute store.stop_requested?("t1")
  end

  def test_stop_is_thread_scoped
    store = new_store
    store.request_stop("t1")

    refute store.stop_requested?("t2")
  end
end
