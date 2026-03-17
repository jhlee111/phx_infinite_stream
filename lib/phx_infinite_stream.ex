defmodule PhxInfiniteStream do
  @moduledoc """
  Reusable infinite scroll pagination for Phoenix LiveView streams.

  Provides a function component for the template and socket helpers for
  managing page state. Pagination metadata is stored under a single
  `@pagination` assign keyed by stream name.

  ## Setup

  Import the component in your LiveView or add it to your `html_helpers`:

      import PhxInfiniteStream, only: [infinite_stream: 1]

  For socket helpers, alias the module:

      alias PhxInfiniteStream

  ## Usage

  ### Mount

      socket
      |> PhxInfiniteStream.init(:items, page_size: 20)

  ### Template

      <.infinite_stream
        id="items-stream"
        end?={@pagination.items.all_loaded}
        load_event="load_more_items"
        class="space-y-3"
      >
        <div :for={{id, item} <- @streams.items} id={id}>
          ...
        </div>
      </.infinite_stream>

  ### Load more (handle_event)

      def handle_event("load_more_items", _, socket) do
        loader = fn page -> MyApp.load_items(page) end
        {:noreply, PhxInfiniteStream.load_more(socket, :items, loader)}
      end

  ### Reload (reset to page 1)

      loader = fn page -> MyApp.load_items(page) end
      PhxInfiniteStream.reload(socket, :items, loader)

  ### Set pre-loaded items (e.g. from async task)

      PhxInfiniteStream.put_items(socket, :items, 1, items, reset: true)

  The loader function receives a page number and must return `{:ok, items}`.

  ## Multiple streams

  You can have multiple independent infinite streams on a single page.
  Each stream tracks its own page, page_size, and loaded state under
  `@pagination.<stream_name>`:

      socket
      |> PhxInfiniteStream.init(:posts, page_size: 10)
      |> PhxInfiniteStream.init(:comments, page_size: 25)

  ## JavaScript Hook

  The component uses a custom `InfiniteScroll` JS hook (not LiveView's built-in
  `phx-viewport-bottom` binding) to reliably detect when the user scrolls near the
  bottom of the stream container. This avoids a known issue where LiveView's
  internal hook fails to initialize on `phx-update="stream"` containers during
  join patches.

  ### Setup

  Add the hook to your LiveSocket:

      import InfiniteScroll from "phx_infinite_stream"

      const liveSocket = new LiveSocket("/live", Socket, {
        hooks: { InfiniteScroll, ...otherHooks }
      })

  For path deps, add an esbuild alias in `config/config.exs`:

      config :esbuild,
        your_app: [
          args: ~w(... --alias:phx_infinite_stream=<path>/priv/static/infinite_scroll.js),
          ...
        ]

  Or call `PhxInfiniteStream.js_path/0` to get the absolute path at compile time.
  """

  use Phoenix.Component
  import Phoenix.LiveView, only: [stream: 3, stream: 4]

  @default_page_size 20

  @doc """
  Returns the absolute path to the JavaScript hook file.

  Useful for configuring esbuild aliases at compile time:

      config :esbuild,
        your_app: [
          args: ~w(... --alias:phx_infinite_stream=\#{PhxInfiniteStream.js_path()}),
          ...
        ]
  """
  def js_path do
    Application.app_dir(:phx_infinite_stream, "priv/static/infinite_scroll.js")
  end

  # --- Template Component ---

  @doc """
  Renders a stream container with infinite scroll.

  The `phx-viewport-bottom` event is automatically disabled when `end?` is true,
  preventing unnecessary events once all items are loaded.

  ## Attributes

    * `id` (required) — DOM id for the stream container
    * `end?` — whether all items are loaded (default: `false`)
    * `load_event` (required) — the event name pushed when the viewport reaches the bottom
    * `class` — CSS classes for the container
    * All other attributes are passed through to the container div

  ## Example

      <.infinite_stream
        id="items-stream"
        end?={@pagination.items.all_loaded}
        load_event="load_more_items"
        class="space-y-3 pb-8"
      >
        <.item_card :for={{id, item} <- @streams.items} id={id} item={item} />
      </.infinite_stream>
  """
  attr :id, :string, required: true
  attr :end?, :boolean, default: false
  attr :load_event, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def infinite_stream(assigns) do
    ~H"""
    <div
      id={@id}
      phx-update="stream"
      phx-hook="InfiniteScroll"
      data-load-event={@load_event}
      data-end={@end? && "true"}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  # --- Socket Helpers ---

  @doc """
  Initialize an infinite stream with pagination tracking.

  Creates the stream and sets up pagination metadata under `@pagination.<stream_name>`.

  ## Options

    * `:page_size` — items per page (default: #{@default_page_size})

  ## Example

      socket
      |> PhxInfiniteStream.init(:items, page_size: 20)
  """
  def init(socket, stream_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    pagination = Map.get(socket.assigns, :pagination, %{})
    meta = %{page: 0, all_loaded: true, page_size: page_size}

    socket
    |> assign(:pagination, Map.put(pagination, stream_name, meta))
    |> stream(stream_name, [])
  end

  @doc """
  Set pre-loaded items into the stream and update pagination state.

  Use this when items are already fetched (e.g. from an async task)
  and you want to put them into the stream without calling a loader.

  ## Options

    * `:reset` — when `true`, resets the stream (default: `false`, appends with `at: -1`)

  ## Examples

      # Reset stream with first page (e.g. after async initial load)
      PhxInfiniteStream.put_items(socket, :items, 1, items, reset: true)

      # Append next page
      PhxInfiniteStream.put_items(socket, :items, 2, items)
  """
  def put_items(socket, stream_name, page, items, opts \\ []) do
    meta = socket.assigns.pagination[stream_name]
    reset = Keyword.get(opts, :reset, false)

    updated = %{meta | page: page, all_loaded: length(items) < meta.page_size}
    pagination = Map.put(socket.assigns.pagination, stream_name, updated)

    stream_opts = if reset, do: [reset: true], else: [at: -1]

    socket
    |> assign(:pagination, pagination)
    |> stream(stream_name, items, stream_opts)
  end

  @doc """
  Load the next page and append to the stream.

  Returns the socket unchanged if all items are already loaded.
  The `loader` function receives the page number and must return `{:ok, items}`.

  ## Example

      def handle_event("load_more_items", _, socket) do
        loader = fn page -> MyApp.Items.list_page(page) end
        {:noreply, PhxInfiniteStream.load_more(socket, :items, loader)}
      end
  """
  def load_more(socket, stream_name, loader) do
    meta = socket.assigns.pagination[stream_name]

    if meta.all_loaded do
      socket
    else
      next_page = meta.page + 1
      {:ok, items} = loader.(next_page)
      put_items(socket, stream_name, next_page, items)
    end
  end

  @doc """
  Reload the stream from page 1 (full reset).

  The `loader` function receives the page number (1) and must return `{:ok, items}`.

  ## Example

      loader = fn page -> MyApp.Items.list_page(page, filter: new_filter) end
      socket = PhxInfiniteStream.reload(socket, :items, loader)
  """
  def reload(socket, stream_name, loader) do
    {:ok, items} = loader.(1)
    put_items(socket, stream_name, 1, items, reset: true)
  end

  @doc "Check if all items have been loaded for a stream."
  def all_loaded?(socket, stream_name) do
    socket.assigns.pagination[stream_name].all_loaded
  end

  @doc "Get the current page number for a stream."
  def page(socket, stream_name) do
    socket.assigns.pagination[stream_name].page
  end

  @doc "Get the page size for a stream."
  def page_size(socket, stream_name) do
    socket.assigns.pagination[stream_name].page_size
  end
end
