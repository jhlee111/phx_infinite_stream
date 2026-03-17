const findScrollContainer = (el) => {
  if (["HTML", "BODY"].indexOf(el.nodeName.toUpperCase()) >= 0) return null;
  if (["scroll", "auto"].indexOf(getComputedStyle(el).overflowY) >= 0)
    return el;
  return findScrollContainer(el.parentElement);
};

const InfiniteScroll = {
  mounted() {
    this.scrollContainer = findScrollContainer(this.el);
    let scrollBefore = this.scrollContainer
      ? this.scrollContainer.scrollTop
      : document.documentElement.scrollTop || document.body.scrollTop;

    this.onScroll = () => {
      const loadEvent = this.el.dataset.loadEvent;
      const isEnd = this.el.dataset.end === "true";
      if (!loadEvent || isEnd) return;

      const sc = this.scrollContainer;
      const scrollNow = sc
        ? sc.scrollTop
        : document.documentElement.scrollTop || document.body.scrollTop;

      const isScrollingDown = scrollNow > scrollBefore;
      scrollBefore = scrollNow;
      if (!isScrollingDown) return;

      const lastChild = this.el.lastElementChild;
      if (!lastChild) return;

      const scBottom = sc
        ? sc.getBoundingClientRect().bottom
        : window.innerHeight || document.documentElement.clientHeight;
      const scTop = sc ? sc.getBoundingClientRect().top : 0;

      const rect = lastChild.getBoundingClientRect();
      const atBottom =
        Math.ceil(rect.bottom) >= scTop &&
        Math.ceil(rect.left) >= 0 &&
        Math.floor(rect.bottom) <= scBottom;

      if (atBottom) {
        this.pushEvent(loadEvent, {});
      }
    };

    if (this.scrollContainer) {
      this.scrollContainer.addEventListener("scroll", this.onScroll);
    } else {
      window.addEventListener("scroll", this.onScroll);
    }
  },

  updated() {
    // re-detect scroll container in case DOM changed
    const newContainer = findScrollContainer(this.el);
    if (newContainer !== this.scrollContainer) {
      if (this.scrollContainer) {
        this.scrollContainer.removeEventListener("scroll", this.onScroll);
      } else {
        window.removeEventListener("scroll", this.onScroll);
      }
      this.scrollContainer = newContainer;
      if (this.scrollContainer) {
        this.scrollContainer.addEventListener("scroll", this.onScroll);
      } else {
        window.addEventListener("scroll", this.onScroll);
      }
    }
  },

  destroyed() {
    if (this.scrollContainer) {
      this.scrollContainer.removeEventListener("scroll", this.onScroll);
    } else {
      window.removeEventListener("scroll", this.onScroll);
    }
  },
};

export default InfiniteScroll;
