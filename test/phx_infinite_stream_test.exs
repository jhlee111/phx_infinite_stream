defmodule PhxInfiniteStreamTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  describe "infinite_stream/1 component" do
    test "renders stream container with load event when not ended" do
      assigns = %{end?: false}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" end?={@end?} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(id="test-stream")
      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(phx-viewport-bottom="load_more")
    end

    test "omits viewport-bottom when ended" do
      assigns = %{end?: true}

      html =
        rendered_to_string(~H"""
        <PhxInfiniteStream.infinite_stream id="test-stream" end?={@end?} load_event="load_more">
          <div id="items-1">Item 1</div>
        </PhxInfiniteStream.infinite_stream>
        """)

      assert html =~ ~s(id="test-stream")
      assert html =~ ~s(phx-update="stream")
      refute html =~ ~s(phx-viewport-bottom)
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

  describe "pagination logic" do
    # These tests exercise the pagination metadata helpers directly,
    # using a minimal socket-like map. The stream/3 call requires a full
    # LiveView socket, so init/load_more/reload are best tested via
    # LiveView integration tests in consuming apps. Here we test the
    # metadata functions that don't touch the stream.

    test "all_loaded?/2 returns value from pagination metadata" do
      socket = %{assigns: %{pagination: %{items: %{page: 1, all_loaded: true, page_size: 20}}}}
      assert PhxInfiniteStream.all_loaded?(socket, :items) == true
    end

    test "page/2 returns current page" do
      socket = %{assigns: %{pagination: %{items: %{page: 3, all_loaded: false, page_size: 20}}}}
      assert PhxInfiniteStream.page(socket, :items) == 3
    end

    test "page_size/2 returns configured page size" do
      socket = %{assigns: %{pagination: %{items: %{page: 1, all_loaded: false, page_size: 50}}}}
      assert PhxInfiniteStream.page_size(socket, :items) == 50
    end

    test "load_more/3 returns socket unchanged when all_loaded" do
      socket = %{assigns: %{pagination: %{items: %{page: 1, all_loaded: true, page_size: 20}}}}

      # Should not call loader at all
      result = PhxInfiniteStream.load_more(socket, :items, fn _page -> raise "should not be called" end)
      assert result == socket
    end
  end
end
