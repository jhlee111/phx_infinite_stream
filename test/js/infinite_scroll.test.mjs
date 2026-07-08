// Zero-dependency tests for the InfiniteScroll hook, using node's built-in
// test runner:
//
//     npm test        (= node --test 'test/js/*.test.mjs')
//
// The hook observes the last stream item with an IntersectionObserver, so the
// tests drive a fake observer: `intersect()` simulates the browser reporting
// intersection state — which real browsers also do right after observe(),
// with no scrolling required.
//
// Server-side halves of these behaviors (stale-event drop, pagination state)
// are covered in test/phx_infinite_stream_test.exs.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import InfiniteScroll from "../../priv/static/infinite_scroll.js";

// --- minimal DOM stubs -------------------------------------------------------

const BODY = { nodeName: "BODY" };

class FakeIntersectionObserver {
  static instances = [];

  constructor(callback, options = {}) {
    this.callback = callback;
    this.root = options.root ?? null;
    this.rootMargin = options.rootMargin;
    this.observed = new Set();
    FakeIntersectionObserver.instances.push(this);
  }

  observe(target) {
    this.observed.add(target);
  }

  unobserve(target) {
    this.observed.delete(target);
  }

  disconnect() {
    this.observed.clear();
  }

  // Test helper: deliver an intersection notification for an observed target.
  intersect(target, isIntersecting = true) {
    if (this.observed.has(target)) {
      this.callback([{ target, isIntersecting }], this);
    }
  }

  static latest() {
    return this.instances[this.instances.length - 1];
  }
}

beforeEach(() => {
  FakeIntersectionObserver.instances = [];
  globalThis.IntersectionObserver = FakeIntersectionObserver;
  globalThis.getComputedStyle = (el) => ({ overflowY: el._overflowY ?? "visible" });
});

function streamEl({ page, end, parent = BODY } = {}) {
  const dataset = { loadEvent: "load_more" };
  if (page !== undefined) dataset.page = page;
  if (end !== undefined) dataset.end = end;

  return {
    nodeName: "DIV",
    parentElement: parent,
    dataset,
    lastElementChild: { id: "items-1" },
  };
}

function scrollableContainer() {
  return { nodeName: "DIV", parentElement: BODY, _overflowY: "auto" };
}

// Mounts the hook with a pushEvent recorder. Server replies are delivered
// manually via serverReplies() to model in-flight latency.
function mountHook(el) {
  const hook = Object.create(InfiniteScroll);
  hook.el = el;
  hook.pushes = [];
  hook.replies = [];
  hook.pushEvent = (event, payload, onReply) => {
    hook.pushes.push([event, payload]);
    if (onReply) hook.replies.push(onReply);
  };
  hook.mounted();
  return hook;
}

function serverReplies(hook) {
  hook.replies.splice(0).forEach((onReply) => onReply({}));
}

// --- behavior ------------------------------------------------------------------

test("observes the last stream item — no scroll listeners involved", () => {
  const el = streamEl();
  mountHook(el);

  const observer = FakeIntersectionObserver.latest();
  assert.deepEqual([...observer.observed], [el.lastElementChild]);
});

test("loads when the last item becomes visible, without any scrolling", () => {
  // Fixes review bug 1: IntersectionObserver reports the initial state right
  // after observe(), so an underfilled first page triggers the next load even
  // though the page cannot scroll.
  const el = streamEl({ page: "1" });
  const hook = mountHook(el);

  FakeIntersectionObserver.latest().intersect(el.lastElementChild);

  assert.deepEqual(hook.pushes, [["load_more", { page: 1 }]]);
});

test("keeps a single load in flight", () => {
  // Fixes review bug 2 (client half): repeated notifications while the
  // server is still working must not push again.
  const el = streamEl({ page: "1" });
  const hook = mountHook(el);
  const observer = FakeIntersectionObserver.latest();

  observer.intersect(el.lastElementChild);
  observer.intersect(el.lastElementChild);
  observer.intersect(el.lastElementChild);

  assert.equal(hook.pushes.length, 1);
});

test("chain-loads across updates until the viewport is filled", () => {
  const el = streamEl({ page: "1" });
  const hook = mountHook(el);

  FakeIntersectionObserver.latest().intersect(el.lastElementChild);
  assert.equal(hook.pushes.length, 1);

  // the server appends page 2: patch lands, dataset and last child change
  serverReplies(hook);
  el.dataset.page = "2";
  const newLast = { id: "items-40" };
  el.lastElementChild = newLast;
  hook.updated();

  // the fresh last item is still visible (page 2 didn't fill the viewport
  // either): the observer's initial notification fires the next load
  const observer = FakeIntersectionObserver.latest();
  assert.deepEqual([...observer.observed], [newLast]);
  observer.intersect(newLast);

  assert.deepEqual(hook.pushes.map(([, payload]) => payload), [{ page: 1 }, { page: 2 }]);
});

test("becomes eligible again after a no-op reply, even without a patch", () => {
  const el = streamEl();
  const hook = mountHook(el);
  const observer = FakeIntersectionObserver.latest();

  observer.intersect(el.lastElementChild);
  serverReplies(hook); // server dropped the event: no patch, no updated()

  observer.intersect(el.lastElementChild);
  assert.equal(hook.pushes.length, 2);
});

test("omits the page payload when data-page is absent or malformed", () => {
  const el = streamEl();
  const hook = mountHook(el);
  FakeIntersectionObserver.latest().intersect(el.lastElementChild);

  el.dataset.page = "not-a-number";
  serverReplies(hook);
  hook.updated();
  FakeIntersectionObserver.latest().intersect(el.lastElementChild);

  assert.deepEqual(hook.pushes.map(([, payload]) => payload), [{}, {}]);
});

test("data-end='true' suppresses loading", () => {
  const el = streamEl({ end: "true" });
  const hook = mountHook(el);

  FakeIntersectionObserver.latest().intersect(el.lastElementChild);

  assert.equal(hook.pushes.length, 0);
});

test("an empty stream observes nothing until items arrive", () => {
  const el = streamEl();
  el.lastElementChild = null;
  const hook = mountHook(el);

  assert.equal(FakeIntersectionObserver.latest().observed.size, 0);

  el.lastElementChild = { id: "items-1" };
  hook.updated();

  FakeIntersectionObserver.latest().intersect(el.lastElementChild);
  assert.equal(hook.pushes.length, 1);
});

test("uses the nearest scrollable ancestor as the observer root", () => {
  const container = scrollableContainer();
  const el = streamEl({ parent: container });
  mountHook(el);

  const observer = FakeIntersectionObserver.latest();
  assert.equal(observer.root, container);
  assert.equal(observer.rootMargin, "0px 0px 200px 0px");
});

test("defaults to the viewport root when nothing scrollable is found", () => {
  const el = streamEl();
  mountHook(el);

  assert.equal(FakeIntersectionObserver.latest().root, null);
});

test("rebuilds the observer when the scroll container changes", () => {
  // Fixes review bug 6: the old implementation kept stale scroll state across
  // container swaps; now the observer is simply recreated with the new root.
  const containerA = scrollableContainer();
  const el = streamEl({ parent: containerA });
  const hook = mountHook(el);
  const observerA = FakeIntersectionObserver.latest();
  assert.equal(observerA.root, containerA);

  const containerB = scrollableContainer();
  el.parentElement = containerB;
  hook.updated();

  const observerB = FakeIntersectionObserver.latest();
  assert.notEqual(observerB, observerA);
  assert.equal(observerB.root, containerB);
  assert.equal(observerA.observed.size, 0); // old observer disconnected

  observerB.intersect(el.lastElementChild);
  assert.equal(hook.pushes.length, 1); // first interaction after swap works
});

test("destroyed disconnects the observer", () => {
  const el = streamEl();
  const hook = mountHook(el);
  const observer = FakeIntersectionObserver.latest();

  hook.destroyed();

  assert.equal(observer.observed.size, 0);
});
