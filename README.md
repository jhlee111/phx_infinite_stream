# PhxInfiniteStream

Reusable infinite scroll pagination for Phoenix LiveView streams.

Drop-in component + socket helpers that manage page state, stream inserts,
and scroll detection — so you don't have to.

## Why not `phx-viewport-bottom`?

LiveView's built-in `phx-viewport-bottom` binding relies on an internal
`Phoenix.InfiniteScroll` hook that is auto-attached via `data-phx-hook`
during DOM patching. However, this hook **fails to initialize** on
`phx-update="stream"` containers during join patches — the `data-phx-hook`
attribute is set on the element, but `mounted()` never fires, so no scroll
listener is registered.

This library uses an explicit `phx-hook="InfiniteScroll"` with a custom JS
hook that reliably mounts on stream containers regardless of patch timing.

See the [investigation details](#how-it-works) below.

## Installation

### 1. Add the dependency

```elixir
# mix.exs
defp deps do
  [
    {:phx_infinite_stream, github: "jhlee111/phx_infinite_stream"}
  ]
end
```

```bash
mix deps.get
```

### 2. Register the JavaScript hook

The JS import resolves automatically through Phoenix's default `NODE_PATH`
(which includes `deps/`).

```js
// assets/js/app.js
import InfiniteScroll from "phx_infinite_stream"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { InfiniteScroll, ...otherHooks },
  params: { _csrf_token: csrfToken },
})
```

> **Using a path dep?** If you're developing locally with
> `path: "../phx_infinite_stream"`, the package won't be in `deps/`.
> Add an esbuild alias in `config/config.exs`:
>
> ```elixir
> config :esbuild,
>   your_app: [
>     args: ~w(... --alias:phx_infinite_stream=../../phx_infinite_stream/priv/static/infinite_scroll.js),
>     ...
>   ]
> ```
>
> The alias path is relative to the esbuild `cd` directory (usually `assets/`).
> You can also use `PhxInfiniteStream.js_path/0` to get the absolute path
> at compile time.

### 3. Import in your LiveView

```elixir
defmodule MyAppWeb.ItemsLive do
  use MyAppWeb, :live_view

  import PhxInfiniteStream, only: [infinite_stream: 1]
  alias PhxInfiniteStream, as: InfiniteStream

  # ...
end
```

Or add to your `html_helpers/0` in `my_app_web.ex` to make it available everywhere.

## Usage

### Initialize a stream

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> InfiniteStream.init(:items, page_size: 20)
   |> start_async(:load_items, fn ->
     {:ok, items} = MyApp.Items.list_page(1)
     items
   end)}
end

def handle_async(:load_items, {:ok, items}, socket) do
  {:noreply, InfiniteStream.put_items(socket, :items, 1, items, reset: true)}
end
```

`init/3` creates an empty stream and sets up pagination metadata under
`@pagination.items`. Use `start_async` + `put_items` for non-blocking
initial loads.

### Render the stream

```heex
<.infinite_stream
  id="items-stream"
  end?={@pagination.items.all_loaded}
  load_event="load_more_items"
  class="space-y-3 pb-8"
>
  <.item_card :for={{id, item} <- @streams.items} id={id} item={item} />
</.infinite_stream>
```

The container must live inside a scrollable parent (e.g., a div with
`overflow-y: auto` and constrained height). The hook auto-detects the
nearest scrollable ancestor.

### Handle scroll events

```elixir
def handle_event("load_more_items", _, socket) do
  loader = fn page -> MyApp.Items.list_page(page) end
  {:noreply, InfiniteStream.load_more(socket, :items, loader)}
end
```

The `loader` receives a 1-based page number and must return `{:ok, items}`.
`load_more/3` is a no-op when all items are already loaded.

### Reload after filter/sort changes

```elixir
def handle_event("filter_changed", %{"filter" => filter}, socket) do
  loader = fn page -> MyApp.Items.list_page(page, filter: filter) end
  {:noreply, InfiniteStream.reload(socket, :items, loader)}
end
```

### Pre-load items (from async tasks)

```elixir
# Reset stream with first page
InfiniteStream.put_items(socket, :items, 1, items, reset: true)

# Append next page
InfiniteStream.put_items(socket, :items, 2, more_items)
```

## Multiple Streams

Each stream tracks its own page, page_size, and loaded state independently
under `@pagination.<stream_name>`:

```elixir
socket
|> InfiniteStream.init(:posts, page_size: 10)
|> InfiniteStream.init(:comments, page_size: 25)
```

## API Reference

### Socket Helpers

| Function | Description |
|---|---|
| `init(socket, name, opts)` | Initialize a stream with pagination tracking |
| `put_items(socket, name, page, items, opts)` | Set pre-loaded items (`:reset` option for full reset) |
| `load_more(socket, name, loader)` | Load next page and append (no-op if all loaded) |
| `reload(socket, name, loader)` | Reset stream and load from page 1 |
| `all_loaded?(socket, name)` | Check if all items have been loaded |
| `page(socket, name)` | Get the current page number |
| `page_size(socket, name)` | Get the configured page size |
| `js_path()` | Absolute path to the JS hook file |

### Component Attributes

| Attribute | Type | Required | Default | Description |
|---|---|---|---|---|
| `id` | `string` | yes | — | DOM id for the stream container |
| `end?` | `boolean` | no | `false` | Whether all items are loaded |
| `load_event` | `string` | yes | — | Event pushed on scroll to bottom |
| `class` | `string` | no | `nil` | CSS classes |
| `:global` | | | | All other attributes passed through |

## How it Works

### The LiveView bug

LiveView (tested on 1.1.24) handles `phx-viewport-bottom` by auto-setting
`data-phx-hook="Phoenix.InfiniteScroll"` in two places:

1. **`onBeforeElUpdated`** (morphdom callback) — runs during DOM patches
2. **`execNewMounted`** — scans the DOM after patches for hook initialization

For stream containers, the join patch treats the element as an **update**
(not an addition), since it already exists in the dead render HTML. The
`patch.after("updated")` callback only calls `__updated()` on *existing*
hooks — it never calls `maybeAddNewHook()`. The `execNewMounted` scan
*should* catch it, but empirically does not mount the hook (the element's
`phxPrivate` remains undefined and no hook instance appears in the view's
`viewHooks` registry).

Manually calling `view.addHook(el)` works perfectly, confirming the hook
definition and element ownership are correct — the framework just never
invokes it for stream containers during joins.

### The fix

Instead of relying on the implicit `data-phx-hook` mechanism, this library
uses an explicit `phx-hook="InfiniteScroll"` attribute. User-defined hooks
via `phx-hook` are processed through a different code path in LiveView that
reliably mounts during both join patches and regular updates.

The custom hook:
1. Walks up the DOM to find the nearest scrollable ancestor (`overflow-y: auto|scroll`)
2. Attaches a scroll listener to that ancestor (or `window` if none found)
3. On each downward scroll, checks if the last stream child is visible
4. Pushes the configured `data-load-event` to the server
5. Reads `data-end` on each scroll — stops firing once all items are loaded
6. Re-detects the scroll container on `updated()` in case the DOM changes

## License

MIT
