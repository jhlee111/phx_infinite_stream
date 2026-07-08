defmodule PhxInfiniteStreamTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhxInfiniteStream, as: IS

  # stream/3 needs socket.private.lifecycle (LiveView attaches an internal
  # after_render hook to prune streams). With it in place the real stream
  # plumbing works, so init/put_items/load_more/reload run unmocked.
  defp build_socket do
    %Phoenix.LiveView.Socket{
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp items(range), do: Enum.map(range, &%{id: &1})

  # Insert tuples are {dom_id, at, item, limit, update_only} and are prepended
  # internally — extract sorted item ids for stable assertions.
  defp inserted_ids(socket, name) do
    socket.assigns.streams[name].inserts
    |> Enum.map(&elem(&1, 2).id)
    |> Enum.sort()
  end

  # Loader that records which pages were requested (message per call) and
  # serves items from a page => items map. Unexpected pages raise.
  defp recording_loader(pages) do
    test_pid = self()

    fn page ->
      send(test_pid, {:loaded, page})
      {:ok, Map.fetch!(pages, page)}
    end
  end

  describe "infinite_stream/1 component" do
    test "renders a stream container wired to the InfiniteScroll hook" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" end?={false} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(id="test-stream")
      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(phx-hook="InfiniteScroll")
      assert html =~ ~s(data-load-event="load_more")
      refute html =~ "data-end"
    end

    test "sets data-end when all items are loaded, disabling the hook" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" end?={true} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(data-end="true")
    end

    test "renders data-page when page is set, for stale-event protection" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" page={3} end?={false} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(data-page="3")
    end

    test "omits data-page when page is not set" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" end?={false} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      refute html =~ "data-page"
    end

    test "passes through class and extra attributes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream
          id="styled"
          end?={false}
          load_event="load_more"
          class="space-y-3 pb-8"
          data-testid="my-stream"
        >
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(class="space-y-3 pb-8")
      assert html =~ ~s(data-testid="my-stream")
    end
  end

  describe "init/3" do
    test "creates an empty stream with pagination metadata" do
      socket = IS.init(build_socket(), :items, page_size: 5)

      assert socket.assigns.pagination.items ==
               %{page: 0, all_loaded: true, page_size: 5, limit: nil}

      assert socket.assigns.streams.items.inserts == []
    end

    test "defaults page_size to 20" do
      socket = IS.init(build_socket(), :items)

      assert IS.page_size(socket, :items) == 20
    end

    test "rejects a non-positive or non-integer page_size" do
      for bad <- [0, -5, 2.5, "20", nil] do
        assert_raise ArgumentError, ~r/:page_size to be a positive integer/, fn ->
          IS.init(build_socket(), :items, page_size: bad)
        end
      end
    end

    test "forwards extra options like :dom_id to stream creation" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2, dom_id: &"custom-#{&1.id}")
        |> IS.put_items(:items, 1, items(1..2))

      dom_ids = socket.assigns.streams.items.inserts |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert dom_ids == ["custom-1", "custom-2"]
    end

    test "forwards :limit to every stream insert" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2, limit: -100)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, fn 2 -> {:ok, items(3..4)} end)

      # insert tuples are {dom_id, at, item, limit, update_only}
      limits = socket.assigns.streams.items.inserts |> Enum.map(&elem(&1, 3)) |> Enum.uniq()
      assert limits == [-100]
    end

    test "tracks multiple streams independently" do
      socket =
        build_socket()
        |> IS.init(:posts, page_size: 10)
        |> IS.init(:comments, page_size: 25)
        |> IS.put_items(:posts, 1, items(1..10))

      assert IS.page(socket, :posts) == 1
      refute IS.all_loaded?(socket, :posts)
      assert IS.page(socket, :comments) == 0
      assert IS.page_size(socket, :comments) == 25
    end
  end

  describe "put_items/5" do
    test "appends a full page and keeps all_loaded false" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))

      assert IS.page(socket, :items) == 1
      refute IS.all_loaded?(socket, :items)
      assert inserted_ids(socket, :items) == [1, 2]
    end

    test "a short page marks the stream fully loaded" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..1))

      assert IS.all_loaded?(socket, :items)
    end

    test "an empty page marks the stream fully loaded" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, [])

      assert IS.all_loaded?(socket, :items)
    end

    test "reset: true resets the stream and pagination" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.put_items(:items, 1, items(10..11), reset: true)

      assert socket.assigns.streams.items.reset?
      assert IS.page(socket, :items) == 1
      refute IS.all_loaded?(socket, :items)
    end
  end

  describe "load_more/3" do
    test "fetches the next page and appends it" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, recording_loader(%{2 => items(3..4)}))

      assert_received {:loaded, 2}
      assert IS.page(socket, :items) == 2
      refute IS.all_loaded?(socket, :items)
      assert inserted_ids(socket, :items) == [1, 2, 3, 4]
    end

    test "a short page stops further loading" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, recording_loader(%{2 => items(3..3)}))

      assert IS.all_loaded?(socket, :items)

      result = IS.load_more(socket, :items, fn _ -> raise "must not be called" end)
      assert result == socket
    end
  end

  describe "reload/3" do
    test "resets to page 1 with fresh items" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, fn 2 -> {:ok, items(3..4)} end)
        |> IS.reload(:items, fn 1 -> {:ok, items(10..11)} end)

      assert IS.page(socket, :items) == 1
      refute IS.all_loaded?(socket, :items)
      assert socket.assigns.streams.items.reset?
    end
  end

  describe "load_more/4: stale-event protection" do
    # The hook sends the page its DOM was rendered against (data-page). Any
    # mismatch with the server's current page means a duplicate or stale
    # event, which must be dropped instead of fetching yet another page.
    # The client half (payload contents, in-flight guard) is covered in
    # test/js/infinite_scroll.test.mjs.
    test "drops a duplicate event carrying an outdated page" do
      loader = recording_loader(%{2 => items(3..4), 3 => items(5..6)})

      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        # two scroll ticks arrive before the first patch reaches the client:
        # both were emitted against a DOM that still says page 1
        |> IS.load_more(:items, %{"page" => 1}, loader)
        |> IS.load_more(:items, %{"page" => 1}, loader)

      assert_received {:loaded, 2}
      refute_received {:loaded, 3}
      assert IS.page(socket, :items) == 2
    end

    test "proceeds when the event page matches the current page" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, %{"page" => 1}, fn 2 -> {:ok, items(3..4)} end)

      assert IS.page(socket, :items) == 2
    end

    test "trusts events without an integer page (load_more/3 compatibility)" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, %{"page" => nil}, fn 2 -> {:ok, items(3..4)} end)
        |> IS.load_more(:items, %{"other" => "params"}, fn 3 -> {:ok, items(5..6)} end)

      assert IS.page(socket, :items) == 3
    end
  end

  describe "bare init/3 stays silent until the first page arrives" do
    # By design, init/3 sets all_loaded: true: the stream loads nothing until
    # the first page is put via put_items/5 or reload/3 — both the moduledoc
    # Usage section and the README show this initial-load step.
    test "after bare init/3, load_more/3 never invokes the loader" do
      socket = IS.init(build_socket(), :items, page_size: 5)

      result = IS.load_more(socket, :items, fn _ -> raise "never called" end)

      assert result == socket
      assert result.assigns.streams.items.inserts == []
    end

    test "after bare init/3, the component renders data-end, disabling the hook" do
      socket = IS.init(build_socket(), :items, page_size: 5)
      assigns = %{end?: IS.all_loaded?(socket, :items)}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="items" end?={@end?} load_event="load_more">
          <div id="items-x">x</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(data-end="true")
    end
  end

  describe "unknown stream names fail fast with a clear error" do
    # A typo in the stream name (or a missing init/3) raises an ArgumentError
    # naming the stream and listing the initialized ones — previously this
    # surfaced as a KeyError on nil from deep inside the library.
    test "put_items/5, load_more/3, reload/3 and getters all raise ArgumentError" do
      socket = IS.init(build_socket(), :items, page_size: 2)

      for fun <- [
            fn -> IS.put_items(socket, :itmes, 1, items(1..2)) end,
            fn -> IS.load_more(socket, :itmes, fn _ -> {:ok, []} end) end,
            fn -> IS.reload(socket, :itmes, fn _ -> {:ok, []} end) end,
            fn -> IS.all_loaded?(socket, :itmes) end,
            fn -> IS.page(socket, :itmes) end,
            fn -> IS.page_size(socket, :itmes) end
          ] do
        assert_raise ArgumentError, ~r/unknown infinite stream :itmes.*\[:items\]/s, fun
      end
    end

    test "reload/3 fails fast before calling the loader" do
      socket = IS.init(build_socket(), :items, page_size: 2)

      assert_raise ArgumentError, ~r/unknown infinite stream/, fn ->
        IS.reload(socket, :itmes, fn _ -> raise "loader must not run" end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Known sharp edges — tracked in GitHub issues
  #
  # The tests below PIN current behavior that is intentionally unchanged for
  # now. When the referenced issue is fixed, invert the assertions.
  # ---------------------------------------------------------------------------

  describe "issue #1: loader errors crash the LiveView" do
    # `{:ok, items} = loader.(page)` means any {:error, _} (DB down, timeout…)
    # raises MatchError and takes the whole LiveView process down — remounting
    # the page and wiping client state. An error path (`:on_error` option or
    # {:error, _} passthrough) is tracked in issue #1.
    test "an {:error, _} return raises MatchError" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))

      assert_raise MatchError, fn ->
        IS.load_more(socket, :items, fn _ -> {:error, :db_down} end)
      end
    end
  end

  describe "issue #1: item count divisible by page_size needs one extra request" do
    # Inherent cost of the count-less `length(items) < page_size` heuristic:
    # when the last real page is exactly full, all_loaded stays false and one
    # more (empty) round-trip is required to terminate. A page_size + 1 "peek"
    # in the loader contract would remove it — tracked in issue #1.
    test "an exactly-full last page requires an empty follow-up fetch" do
      socket =
        build_socket()
        |> IS.init(:items, page_size: 2)
        |> IS.put_items(:items, 1, items(1..2))
        |> IS.load_more(:items, fn 2 -> {:ok, items(3..4)} end)

      # the dataset (4 items) is exhausted, but the stream cannot know yet
      refute IS.all_loaded?(socket, :items)

      socket = IS.load_more(socket, :items, fn 3 -> {:ok, []} end)

      assert IS.all_loaded?(socket, :items)
      assert IS.page(socket, :items) == 3
    end
  end
end
