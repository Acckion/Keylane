const { isDeepStrictEqual } = require("node:util");
const { makeShowFailureToast } = require("./utilities-visual-feedback.cjs");

const operationDeadlineMs = 1500;
const storedDatePrefix = "__raycast_cached_date__";
const storedBufferPrefix = "__raycast_cached_buffer__";

function waitForOperation(operation, abort) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      abort?.();
      reject(new Error("The extension operation timed out."));
    }, operationDeadlineMs);
  });
  return Promise.race([Promise.resolve().then(operation), deadline]).finally(() => clearTimeout(timer));
}

function storageEncode(value) {
  return JSON.stringify(value, function (key, encoded) {
    const original = this[key];
    if (original instanceof Date) return storedDatePrefix + original.toISOString();
    if (Buffer.isBuffer(original)) return storedBufferPrefix + original.toString("base64");
    return encoded;
  });
}

function storageDecode(value) {
  return JSON.parse(value, (_key, entry) => {
    if (typeof entry !== "string") return entry;
    if (entry.startsWith(storedDatePrefix)) return new Date(entry.slice(storedDatePrefix.length));
    if (entry.startsWith(storedBufferPrefix)) return Buffer.from(entry.slice(storedBufferPrefix.length), "base64");
    return entry;
  });
}

function utilitiesHooksFor(apiProvider, FormValidation) {
  const failure = makeShowFailureToast(apiProvider);

  function useForm({ onSubmit, initialValues = {}, validation = {} }) {
    const { useState } = apiProvider();
    const [initial] = useState(() => ({ ...initialValues }));
    const [values, updateValues] = useState(() => ({ ...initial }));
    const [errors, updateErrors] = useState({});
    const [focused, updateFocus] = useState(null);

    function validate(id, value) {
      const rule = Object.hasOwn(validation, id) ? validation[id] : undefined;
      if (typeof rule === "function") return rule(value);
      if (rule !== FormValidation.Required) return undefined;
      const missing = value == null || value === "" || (Array.isArray(value) && value.length === 0) ||
        (value instanceof Date && !(value.getTime() > 0));
      return missing ? "The item is required" : undefined;
    }

    function setValue(id, value) {
      updateValues((previous) => ({
        ...previous, [id]: typeof value === "function" ? value(previous[id]) : value,
      }));
    }

    function setValidationError(id, error) {
      updateErrors((previous) => ({ ...previous, [id]: error }));
    }

    async function handleSubmit(submitted) {
      const failures = Object.entries(validation).flatMap(([id]) => {
        const message = validate(id, Object.hasOwn(submitted, id) ? submitted[id] : undefined);
        return typeof message === "string" && message ? [[id, message]] : [];
      });
      if (failures.length > 0) {
        updateErrors(Object.fromEntries(failures));
        updateFocus(failures[0][0]);
        // The reviewed form displays action errors inline; the form itself stays open.
        await failure(failures[0][1], { title: "Form validation failed" });
        return false;
      }
      return (await onSubmit(submitted)) !== false;
    }

    const itemProps = new Proxy(Object.create(null), {
      get(_target, id) {
        if (typeof id !== "string") return undefined;
        return {
          id, value: Object.hasOwn(values, id) ? values[id] ?? null : null,
          error: Object.hasOwn(errors, id) ? errors[id] : undefined,
          autoFocus: focused === id ? true : undefined,
          onChange(value) {
            if (Object.hasOwn(errors, id) && errors[id] && !validate(id, value)) setValidationError(id, undefined);
            setValue(id, value);
          },
          onBlur(event) {
            setValidationError(id, validate(id, event?.target?.value));
          },
        };
      },
    });

    return {
      values, itemProps, handleSubmit, setValue, setValidationError, focus: updateFocus,
      reset(next = initial) {
        updateValues({ ...next });
        updateErrors({});
        updateFocus(null);
      },
    };
  }

  function usePromise(fn, args = [], options = {}, cachedData) {
    const { useState, useEffect } = apiProvider();
    const [slot] = useState(() => ({ generation: 0, started: false, isLoading: false }));
    const execute = options.execute !== false;
    const inputsChanged = !slot.started || !isDeepStrictEqual(slot.args, args);
    const willRun = execute && inputsChanged;
    if (cachedData && !isDeepStrictEqual(slot.seededArgs, args)) {
      slot.seededArgs = [...args];
      const cached = cachedData();
      if (cached !== undefined || !options.keepPreviousData || slot.data === undefined) {
        slot.data = cached === undefined ? options.initialData : cached;
      }
    }

    async function revalidate() {
      const generation = ++slot.generation;
      const abortable = options.abortable;
      slot.controller?.abort();
      slot.controller = abortable ? new AbortController() : undefined;
      const controller = slot.controller;
      if (abortable) abortable.current = controller;
      slot.started = true;
      slot.args = [...args];
      slot.isLoading = true;
      slot.error = undefined;
      try {
        options.onWillExecute?.(args);
        const data = await waitForOperation(() => fn(...args), controller && (() => controller.abort()));
        if (generation !== slot.generation) return;
        slot.data = data;
        options.onData?.(data);
      } catch (cause) {
        if (generation !== slot.generation) return;
        const error = cause instanceof Error ? cause : new Error(String(cause));
        slot.error = error;
        if (options.onError) options.onError(error);
        else await failure(error, options.failureToastOptions);
      } finally {
        if (generation === slot.generation) slot.isLoading = false;
      }
    }

    useEffect(() => willRun ? revalidate() : undefined);

    async function mutate(update, mutationOptions = {}) {
      const { optimisticUpdate, rollbackOnError, shouldRevalidateAfter } = mutationOptions;
      const automaticRollback = optimisticUpdate && rollbackOnError !== false && typeof rollbackOnError !== "function";
      let before;
      try {
        if (optimisticUpdate) {
          ++slot.generation;
          slot.controller?.abort();
          slot.isLoading = false;
          if (automaticRollback) before = structuredClone(slot.data);
          slot.data = optimisticUpdate(slot.data);
        }
        return update === undefined ? undefined : await waitForOperation(() => update);
      } catch (error) {
        if (typeof rollbackOnError === "function") slot.data = rollbackOnError(slot.data);
        else if (automaticRollback) slot.data = before;
        throw error;
      } finally {
        if (shouldRevalidateAfter !== false) await revalidate();
      }
    }

    return { data: slot.data, error: slot.error, isLoading: willRun || slot.isLoading, revalidate, mutate };
  }

  function useLocalStorage(key, initialValue) {
    const { LocalStorage } = apiProvider();
    const read = async (storageKey) => {
      const saved = await LocalStorage.getItem(storageKey);
      return saved === undefined ? initialValue : storageDecode(saved);
    };
    const { data: value, isLoading, mutate } = usePromise(read, [key]);
    return {
      value,
      isLoading,
      async setValue(next) {
        try {
          const text = storageEncode(next);
          if (text === undefined) throw new Error("LocalStorage value must be JSON serializable.");
          await mutate(LocalStorage.setItem(key, text), { optimisticUpdate: () => next });
        } catch (error) {
          await failure(error, { title: "Failed to set value in local storage" });
        }
      },
      async removeValue() {
        try {
          await mutate(LocalStorage.removeItem(key), { optimisticUpdate: () => initialValue });
        } catch (error) {
          await failure(error, { title: "Failed to remove value from local storage" });
        }
      },
    };
  }

  return { useForm, usePromise, useLocalStorage };
}

module.exports = { utilitiesHooksFor };
