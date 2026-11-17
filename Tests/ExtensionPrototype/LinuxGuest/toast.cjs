const { randomUUID } = require("node:crypto");
const { macOSShortcut } = require("./presentation-values.cjs");

const ToastStyle = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });
const styles = new Set(Object.values(ToastStyle));
const maximumTextBytes = 2048;
const nativeActions = new WeakMap();

function registerNativeToastAction(action, effect) {
  nativeActions.set(action, Object.freeze(effect));
  return action;
}

function validatedOptions({ style, title, message, primaryAction, secondaryAction }) {
  if (typeof title !== "string" || (message !== undefined && typeof message !== "string") || !styles.has(style)) {
    throw new TypeError("Invalid toast options");
  }
  if (Buffer.byteLength(title) + Buffer.byteLength(message ?? "") > maximumTextBytes) {
    throw new RangeError("Toast text exceeds the feedback limit");
  }
  for (const action of [primaryAction, secondaryAction]) {
    if (action !== undefined && (typeof action?.title !== "string" || typeof action.onAction !== "function")) {
      throw new TypeError("Invalid toast action");
    }
  }
  return Object.freeze({ style, title, message, primaryAction, secondaryAction });
}

function validCallbackTitle(title) {
  return typeof title === "string" && title.trim().length > 0 && Buffer.byteLength(title) <= 80 && !/[\p{Cc}\p{Cf}]/u.test(title);
}

function presentationOptions({ style, title, message, primaryAction, secondaryAction }) {
  const feedbackAction = nativeActions.get(primaryAction);
  const secondaryFeedbackAction = nativeActions.get(secondaryAction);
  return Object.freeze({
    style, title, message,
    ...(feedbackAction && { feedbackAction }),
    ...(secondaryFeedbackAction && { secondaryFeedbackAction }),
    ...(!feedbackAction && validCallbackTitle(primaryAction?.title) && {
      primaryCallbackTitle: primaryAction.title,
      primaryShortcut: macOSShortcut(primaryAction.shortcut),
    }),
    ...(!secondaryFeedbackAction && validCallbackTitle(secondaryAction?.title) && {
      secondaryCallbackTitle: secondaryAction.title,
      secondaryShortcut: macOSShortcut(secondaryAction.shortcut),
    }),
  });
}

function callbacksFor({ primaryAction, secondaryAction }) {
  return {
    primary: primaryAction?.onAction.bind(primaryAction),
    secondary: secondaryAction?.onAction.bind(secondaryAction),
  };
}

function makeToastAdapter({ show, hide, update }) {
  const pendingUpdates = new Set();
  class Toast {
    #options;
    #visible = false;
    #pending = Promise.resolve();

    static get Style() { return ToastStyle; }

    constructor(options) {
      const { style = ToastStyle.Success, title, message, primaryAction, secondaryAction } = options ?? {};
      this.#options = validatedOptions({ style, title, message, primaryAction, secondaryAction });
    }

    get style() { return this.#options.style; }
    set style(value) { this.#setOption("style", value); }

    get title() { return this.#options.title; }
    set title(value) { this.#setOption("title", value); }

    get message() { return this.#options.message; }
    set message(value) { this.#setOption("message", value); }

    get primaryAction() { return this.#options.primaryAction; }
    set primaryAction(value) { this.#setOption("primaryAction", value); }

    get secondaryAction() { return this.#options.secondaryAction; }
    set secondaryAction(value) { this.#setOption("secondaryAction", value); }

    #setOption(key, value) {
      if (this.#options[key] === value) return;
      const options = validatedOptions({ ...this.#options, [key]: value });
      this.#options = options;
      if (!update) return;
      const presentation = presentationOptions(options);
      const callbacks = callbacksFor(options);
      this.#enqueue(() => this.#visible ? update(this, presentation, callbacks) : undefined);
      // Property setters cannot be awaited. Give the view adapter a barrier before
      // it ends the selected callback, and settle rejected updates without leaking promises.
      const pending = this.#pending;
      pendingUpdates.add(pending);
      pending.then(() => pendingUpdates.delete(pending));
    }

    show() {
      const presentation = presentationOptions(this.#options);
      const callbacks = callbacksFor(this.#options);
      return this.#enqueue(async () => {
        await show(this, presentation, callbacks);
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

function toastInteraction(options) {
  const primary = options.feedbackAction ? undefined : options.primaryCallbackTitle;
  const secondary = options.secondaryFeedbackAction ? undefined : options.secondaryCallbackTitle;
  if (!primary && !secondary) return undefined;
  return {
    token: randomUUID(), primary, secondary,
    primaryShortcut: primary ? options.primaryShortcut : undefined,
    secondaryShortcut: secondary ? options.secondaryShortcut : undefined,
  };
}

async function runWithToastActions(run, { currentToast, hasResult, select, redisplay, flush }) {
  async function receive(polling) {
    const current = currentToast();
    if (!current?.interaction) return false;
    if (polling && hasResult()) return false;
    const choice = hasResult() ? undefined : await select(current.interaction.token, polling);
    if (polling && !choice) return false;
    const latest = currentToast();
    // An update may have replaced the selected presentation while the broker replied.
    if (current !== latest) return !!latest?.interaction;
    await redisplay(current);
    if (choice !== "primary" && choice !== "secondary") return false;
    const withdrawn = currentToast();
    await current.callbacks?.[choice]?.(current.toast);
    await flush();
    if (currentToast() === withdrawn && !hasResult()) await redisplay(current, current.callbacks);
    return true;
  }
  let pending;
  let pollingFailure;
  const timer = setInterval(() => {
    if (pending || pollingFailure) return;
    pending = receive(true).catch((error) => { pollingFailure = error; })
      .finally(() => { pending = undefined; });
  }, 250);
  try {
    await run();
  } finally {
    clearInterval(timer);
    await pending;
  }
  if (pollingFailure) throw pollingFailure;
  while (await receive(false)) {
    // A callback may have created or updated a toast with a new action.
  }
}

module.exports = { makeToastAdapter, registerNativeToastAction, toastInteraction, runWithToastActions };
