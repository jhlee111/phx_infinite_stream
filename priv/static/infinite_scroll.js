// Loads the next page when the last stream item comes within LOAD_MARGIN_PX
// of the visible area, using an IntersectionObserver on the last child.
//
// The observer fires its callback with the current intersection state right
// after observe() — no scrolling required — so pages that don't fill the
// viewport chain-load until they do. A `pending` flag keeps a single load
// in flight, and the current page rides along in the event payload so the
// server can drop stale or duplicate events (see PhxInfiniteStream.load_more/4).

const LOAD_MARGIN_PX = 200;

const findScrollContainer = (el) => {
  if (!el || ["HTML", "BODY"].indexOf(el.nodeName.toUpperCase()) >= 0) return null;
  if (["scroll", "auto"].indexOf(getComputedStyle(el).overflowY) >= 0) return el;
  return findScrollContainer(el.parentElement);
};

const InfiniteScroll = {
  mounted() {
    this.pending = false;
    this.createObserver();
  },

  updated() {
    // A patch landed: any in-flight load has been applied, and the scroll
    // container may have changed. Re-observe the (possibly new) last child;
    // the observer fires again immediately if it is already visible.
    this.pending = false;

    if (findScrollContainer(this.el) !== this.root) {
      this.createObserver();
    } else {
      this.observeLastChild();
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect();
  },

  createObserver() {
    if (this.observer) this.observer.disconnect();

    // Root against the nearest scrollable ancestor (or the viewport) so the
    // load margin applies to the box the user actually scrolls.
    this.root = findScrollContainer(this.el);

    this.observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) this.loadMore();
      },
      { root: this.root, rootMargin: `0px 0px ${LOAD_MARGIN_PX}px 0px` }
    );

    this.observeLastChild();
  },

  observeLastChild() {
    this.observer.disconnect();
    const lastChild = this.el.lastElementChild;
    if (lastChild) this.observer.observe(lastChild);
  },

  loadMore() {
    const loadEvent = this.el.dataset.loadEvent;
    if (this.pending || !loadEvent || this.el.dataset.end === "true") return;

    const payload = {};
    const page = parseInt(this.el.dataset.page, 10);
    if (Number.isInteger(page)) payload.page = page;

    this.pending = true;
    this.pushEvent(loadEvent, payload, () => {
      // The server processed the event. If it appended a page, updated() has
      // (or will have) re-observed the new last child; if it was a no-op,
      // clearing the flag makes us eligible to fire again.
      this.pending = false;
    });
  },
};

export default InfiniteScroll;
