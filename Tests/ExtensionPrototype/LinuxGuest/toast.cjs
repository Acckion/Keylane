const ToastStyle = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });
const styles = new Set(Object.values(ToastStyle));
const maximumTextBytes = 2048;

function validatedOptions({ style, title, message }) {
  if (typeof title !== "string" || (message !== undefined && typeof message !== "string") || !styles.has(style)) {
    throw new TypeError("Invalid toast options");
  }
  if (Buffer.byteLength(title) + Buffer.byteLength(message ?? "") > maximumTextBytes) {
    throw new RangeError("Toast text exceeds the feedback limit");
  }
  return Object.freeze({ style, title, message });
}

function makeToastAdapter({ show, hide, update }) {
  const pendingUpdates = new Set();
  class Toast {
    #options;
    #visible = false;
    #pending = Promise.resolve();

    static get Style() { return ToastStyle; }

    constructor(options) {
      const { title, message, style = ToastStyle.Success } = options ?? {};
      this.#options = validatedOptions({ style, title, message });
    }

    get style() { return this.#options.style; }
    set style(value) { this.#setOption("style", value); }

    get title() { return this.#options.title; }
    set title(value) { this.#setOption("title", value); }

    get message() { return this.#options.message; }
    set message(value) { this.#setOption("message", value); }

    #setOption(key, value) {
      if (this.#options[key] === value) return;
      const options = validatedOptions({ ...this.#options, [key]: value });
      this.#options = options;
      if (!update) return;
      this.#enqueue(() => this.#visible ? update(this, options) : undefined);
      // Property setters cannot be awaited. Give the view adapter a barrier before
      // it ends the selected callback, and settle rejected updates without leaking promises.
      const pending = this.#pending;
      pendingUpdates.add(pending);
      pending.then(() => pendingUpdates.delete(pending));
    }

    show() {
      const options = this.#options;
      return this.#enqueue(async () => {
        await show(this, options);
        this.#visible = true;
      });
    }

    hide() {
      return this.#enqueue(async () => {
        if (!this.#visible) return;
        await hide(this);
        this.#visible = false;
      });
    }

    #enqueue(operation) {
      const result = this.#pending.then(operation);
      // A failed request must not disable later lifecycle calls on the instance.
      this.#pending = result.catch(() => {});
      return result;
    }
  }

  async function showToast(options, title, message) {
    const toast = new Toast(typeof options === "string" ? { style: options, title, message } : options);
    await toast.show();
    return toast;
  }

  async function flushToastUpdates() {
    await Promise.all(pendingUpdates);
  }

  return { Toast, ToastStyle, showToast, flushToastUpdates };
}

module.exports = { makeToastAdapter };
