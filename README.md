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
`@pagination.items`. The stream stays silent until the first page arrives:
use `start_async` + `put_items` as above for non-blocking initial loads, or
call `reload/3` right after `init/3` for a simple synchronous load.

`init/3` options:

- `:page_size` — items per page, positive integer (default: `20`)
- `:limit` — DOM cap forwarded to every stream insert. Pages are appended,
  so use a negative value (`limit: -300` keeps the 300 most recent entries);
  pruned items are not re-fetched when scrolling back up
- anything else (e.g. `:dom_id`) is forwarded to `Phoenix.LiveView.stream/4`

### Render the stream

```heex
<.infinite_stream
  id="items-stream"
  end?={@pagination.items.all_loaded}
  page={@pagination.items.page}
  load_event="load_more_items"
  class="space-y-3 pb-8"
>
  <.item_card :for={{id, item} <- @streams.items} id={id} item={item} />
</.infinite_stream>
```

The hook roots its IntersectionObserver at the nearest scrollable ancestor
(`overflow-y: auto|scroll`), falling back to the viewport — plain window
scrolling works, no wrapper element required.

### Handle load events

```elixir
def handle_event("load_more_items", params, socket) do
  loader = fn page -> MyApp.Items.list_page(page) end
  {:noreply, InfiniteStream.load_more(socket, :items, params, loader)}
end
```

The `loader` receives a 1-based page number and must return `{:ok, items}`.
`load_more/4` is a no-op when all items are already loaded — or when the
event carries a page (via the component's `page` attribute) that no longer
matches the server's, which drops duplicate and stale scroll events. Both
the `page` attribute and the params are optional; `load_more/3` without
params trusts every event.

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
| `init(socket, name, opts)` | Initialize a stream (`:page_size`, `:limit`, rest to `stream/4`) |
| `put_items(socket, name, page, items, opts)` | Set pre-loaded items (`:reset` option for full reset) |
| `load_more(socket, name, params \\ %{}, loader)` | Load next page and append (no-op if all loaded or event is stale) |
| `reload(socket, name, loader)` | Reset stream and load from page 1 |
| `all_loaded?(socket, name)` | Check if all items have been loaded |
| `page(socket, name)` | Get the current page number |
| `page_size(socket, name)` | Get the configured page size |
| `js_path()` | Absolute path to the JS hook file |

All helpers raise `ArgumentError` for stream names that were never passed to
`init/3`.

### Component Attributes

| Attribute | Type | Required | Default | Description |
|---|---|---|---|---|
| `id` | `string` | yes | — | DOM id for the stream container |
| `end?` | `boolean` | no | `false` | Whether all items are loaded |
| `page` | `integer` | no | `nil` | Current page; enables duplicate/stale-event protection |
| `load_event` | `string` | yes | — | Event pushed when more items are needed |
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
1. Observes the last stream item with an IntersectionObserver, rooted at the
   nearest scrollable ancestor (`overflow-y: auto|scroll`) or the viewport,
   with a 200px load margin
2. Fires as soon as the last item approaches the visible area — including
   right after mount and after every patch, so first pages that don't fill
   the viewport chain-load without any scrolling
3. Keeps a single load in flight and sends the current `data-page` in the
   event payload, letting `load_more/4` drop duplicate or stale events
4. Stops once `data-end` is set; re-observes the new last item (and
   re-detects the scroll container) after every patch

## License

MIT
