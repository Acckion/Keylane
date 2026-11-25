import Foundation

/// Converts a reviewed React command into the entry points understood by the
/// signed view runner. Ordinary extensions cannot opt themselves into this route.
package enum MacOSReviewedRaycastViewAdapter {
    package static let modulePath = MacOSExtensionBuild.reactViewRuntimeModule

    package static let files: [RaycastStoreBuildProject.File] = [
        .init(path: modulePath, body: Data(source.utf8)),
        .init(path: "node_modules/@keylane/reviewed-view/package.json",
              body: Data(#"{"name":"@keylane/reviewed-view","main":"index.cjs"}"#.utf8)),
        .init(path: "node_modules/@raycast/api/index.js", body: Data((MacOSReviewedRaycastValues.pureSource + "\n" + api).utf8)),
        .init(path: "node_modules/@raycast/api/package.json",
              body: Data(#"{"name":"@raycast/api","type":"module","main":"index.js"}"#.utf8)),
        .init(path: "node_modules/@raycast/utils/index.js", body: Data(utils.utf8)),
        .init(path: "node_modules/@raycast/utils/package.json",
              body: Data(#"{"name":"@raycast/utils","type":"module","main":"index.js"}"#.utf8)),
    ]

    package static let dependencies: [RaycastStoreDependencyPlan.Node] = [
        node("react", "19.0.0", "V8AVnmPIICiWpGfm6GLzCR/W5FXLchHop40W4nXBmdlEceh16rCN8O8LNWm5bh5XUX91fh7KpA+W0TgMKmgTpQ=="),
        node("react-reconciler", "0.31.0", "7Ob7Z+URmesIsIVRjnLoDGwBEG/tVitidU0nMsqX/eeJaLY89RISO/10ERe0MqmzuKUUB1rmY+h1itMbUHg9BQ=="),
        node("scheduler", "0.25.0", "xFVuu11jh+xcO7JOAGJNOXld8/TcEHK/4CituBUeUb5hqxJLj9YuemAEuvm9gQ/+pgXYfbQuqAkiYu+u7YEsNA==")
    ]

    package static func files(retainingLicense license: Data) throws -> [RaycastStoreBuildProject.File] {
        guard license.count <= 4_096, let notice = String(data: license, encoding: .utf8), !notice.contains("*/") else {
            throw RaycastStoreDependencyArchive.Failure.integrity
        }
        let header = Data(("/*!\n" + notice + "\n*/\n").utf8)
        return files.map { $0.path == modulePath ? .init(path: $0.path, body: header + $0.body) : $0 }
    }

    private static func node(_ name: String, _ version: String, _ digest: String) -> RaycastStoreDependencyPlan.Node {
        .init(path: "node_modules/" + name, name: name, version: version, dev: false, optional: false, devOptional: false,
            os: nil, cpu: nil, hasNativeBuild: false, edges: [], blockers: [],
            registryTarball: URL(string: "https://registry.npmjs.org/\(name)/-/\(name)-\(version).tgz"), integrity: "sha512-" + digest)
    }

    static func dependencies(for source: RaycastStoreSource, target: RaycastStoreBuildDependencies.Target,
                             version: String?) -> [RaycastStoreDependencyPlan.Node] {
        guard target == .macOSArm64, let version,
              let entries = try? MacOSReviewedRaycastCommand.buildEntries(for: source, apiVersion: version),
              !entries.isEmpty, entries.allSatisfy({ $0.mode == .view && MacOSReviewedViewSession.canRun($0.capabilities) })
        else { return [] }
        return dependencies
    }

    static func stagingDependencies(for source: RaycastStoreSource, target: RaycastStoreBuildDependencies.Target,
                                    selection: RaycastStoreBuildDependencies) throws -> (archives: [RaycastStoreDependencyPlan.Node], usesRenderer: Bool) {
        let runtime = dependencies(for: source, target: target, version: selection.runtimeAPIVersion)
        let byPath = Dictionary(uniqueKeysWithValues: runtime.map { ($0.path, $0) })
        var ordinary: [RaycastStoreDependencyPlan.Node] = []
        for node in selection.packages {
            if let pinned = byPath[node.path] {
                guard pinned.integrity == node.integrity else { throw RaycastStoreDependencyArchive.Failure.integrity }
            } else {
                ordinary.append(node)
            }
        }
        return (ordinary + runtime, !runtime.isEmpty)
    }

    package static func plan(files: [MacOSExtensionBuild.File], entries: [String]) throws -> MacOSExtensionBuild.Plan {
        let reviewed = Set(entries)
        var staged: [MacOSExtensionBuild.File] = []
        for file in files {
            guard reviewed.contains(file.path) else { staged.append(file); continue }
            let path = file.path as NSString
            let original = "__keylane-view-" + path.lastPathComponent
            let sibling = path.deletingLastPathComponent + "/" + original
            staged.append(.init(path: file.path, body: wrapper(command: original)))
            staged.append(.init(path: sibling, body: file.body))
        }
        return try .init(files: staged, entries: entries)
    }

    private static let api = #"""
    import runtime from "@keylane/reviewed-view";
    export const { Action, ActionPanel, Detail, ActionPanelItem, ActionPanelSection,
      ActionPanelSubmenu, PushAction, confirmAlert, Toast, ToastStyle, showToast, render,
      showHUD, closeMainWindow, clearSearchBar, popToRoot,
      useNavigation, useActionPanel, useId } = runtime;
    """#

    package static func wrapper(command module: String) -> Data {
        Data("""
        import * as command from "./\(module)";
        import runtime from "@keylane/reviewed-view";
        export default () => runtime.start(command.default);
        export const onEvent = runtime.onEvent;
        """.utf8)
    }

    // Keep the utility entry small. The wider @raycast/utils surface is
    // qualified separately, not implicitly enabled by React rendering.
    private static let utils = #"""
    import { Toast, showToast } from "@raycast/api";
    export function showFailureToast(error, options) {
      const title = options?.title ?? "Something went wrong";
      const message = options?.message ?? String(error?.message ?? error).slice(0, 512);
      return showToast({ title, message, style: Toast.Style.Failure,
        primaryAction: options?.primaryAction, secondaryAction: options?.secondaryAction });
    }
    """#

    private static let source = #"""
    // App-owned Raycast view projection. No filesystem, network, or native-effect bridge.
    const grants = new Set(globalThis.__keylaneViewCapabilities ?? []);
    delete globalThis.__keylaneViewCapabilities;
    const scheduled = new Map();
    let timer = 0;
    const schedule = callback => {
      if (scheduled.size >= 128) throw new Error("Renderer queue full");
      scheduled.set(++timer, callback);
      return timer;
    };
    const cancel = id => scheduled.delete(id);
    // React's scheduler needs a turn queue without ambient timers. Command code
    // has no wall-clock timer API. Drain only during a supervised request.
    globalThis.setTimeout = schedule;
    globalThis.clearTimeout = cancel;
    const React = require("react");
    const reconciler = require("react-reconciler");
    const { DiscreteEventPriority } = require("react-reconciler/constants");

    const noop = () => {};
    const empty = Object.freeze({});
    const create = (type, props) => ({ type, props, children: [] });
    const remove = (parent, child) => {
      const index = parent.children.indexOf(child);
      if (index !== -1) parent.children.splice(index, 1);
    };
    const append = (parent, child) => {
      remove(parent, child);
      parent.children.push(child);
    };
    const insert = (parent, child, before) => {
      remove(parent, child);
      const index = parent.children.indexOf(before);
      if (index < 0) throw new Error("Unknown renderer node");
      parent.children.splice(index, 0, child);
    };
    let priority = DiscreteEventPriority, error;
    const report = failure => { error = failure ?? new Error("React render failed"); };
    const renderer = reconciler({
      supportsMutation: true,
      supportsPersistence: false,
      supportsHydration: false,
      isPrimaryRenderer: true,
      getRootHostContext: () => empty,
      getChildHostContext: () => empty,
      getPublicInstance: () => null,
      prepareForCommit: () => null,
      resetAfterCommit: noop,
      preparePortalMount: noop,
      createInstance: create,
      createTextInstance: text => create("text", { text }),
      appendInitialChild: append,
      finalizeInitialChildren: () => false,
      shouldSetTextContent: () => false,
      scheduleTimeout: schedule,
      cancelTimeout: cancel,
      noTimeout: -1,
      appendChild: append,
      appendChildToContainer: append,
      insertBefore: insert,
      insertInContainerBefore: insert,
      removeChild: remove,
      removeChildFromContainer: remove,
      clearContainer: target => { target.children.length = 0; },
      commitUpdate: (node, _type, _previous, props) => { node.props = props; },
      commitTextUpdate: (node, _previous, text) => { node.props.text = text; },
      detachDeletedInstance: noop,
      hideInstance: node => { node.hidden = true; },
      unhideInstance: node => { node.hidden = false; },
      hideTextInstance: node => { node.hidden = true; },
      unhideTextInstance: node => { node.hidden = false; },
      setCurrentUpdatePriority: level => { priority = level; },
      getCurrentUpdatePriority: () => priority,
      resolveUpdatePriority: () => priority || DiscreteEventPriority,
      trackSchedulerEvent: noop,
      resolveEventType: () => null,
      resolveEventTimeStamp: () => Date.now(),
      shouldAttemptEagerTransition: () => false,
      maySuspendCommit: () => false,
    });
    delete globalThis.setTimeout;
    delete globalThis.clearTimeout;
    const h = React.createElement;
    const Page = React.createContext(undefined);
    const tree = create("root", {});
    const root = renderer.createContainer(tree, 1, null, false, null, "keylane-view", report, report, report, noop);
    const stack = [];
    const panels = new Map();
    let alert, toast, handlers = new Map(), fallback;
    const update = () => {
      renderer.updateContainerSync(stack.map(({ node, id }, index) =>
        h(Page.Provider, { key: id, value: id },
          h("page", { active: index === stack.length - 1 }, node, panels.get(id)))), root, null);
    };
    let nextPage = 0;
    const navigation = Object.freeze({
      push(node, onPop) {
        if (stack.length >= 16 || !React.isValidElement(node)) throw new Error("Invalid destination");
        stack.push({ node, id: ++nextPage, onPop }); update();
      },
      pop() {
        if (stack.length <= 1) return;
        const leaving = stack.pop();
        panels.delete(leaving.id);
        update();
        leaving.onPop?.();
      },
    });

    function observe(result) {
      if (result && typeof result.then === "function") Promise.resolve(result).catch(report);
    }
    function render(node) {
      if (!React.isValidElement(node)) throw new Error("Expected React element");
      if (stack.length === 0) stack.push({ node, id: ++nextPage });
      else stack[0].node = node;
      update();
    }
    const Action = props => h("action", props);
    Action.Style = Object.freeze({ Regular: "regular", Destructive: "destructive" });
    Action.Push = ({ target, onPush, onPop, ...props }) =>
      h(Action, { ...props, onAction: () => { navigation.push(target, onPop); onPush?.(); } });
    const ActionPanel = ({ children, ...props }) => h("panel", props, children);
    ActionPanel.Item = Action;
    ActionPanel.Section = ({ children }) => h("section", {}, children);
    ActionPanel.Submenu = ({ children, ...props }) => h("submenu", props, children);
    function Detail({ markdown = "", actions, navigationTitle, isLoading }) {
      return h("detail", { markdown, navigationTitle, isLoading }, actions);
    }
    function confirmAlert(options) {
      if (alert || options.rememberUserChoice) throw new Error("Unsupported confirmation");
      return new Promise(resolve => { alert = { options: { ...options }, resolve }; });
    }
    class Toast {
      static Style = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });
      constructor(options) {
        Object.assign(this, { style: Toast.Style.Success }, options);
      }
      async show() { toast = this; }
      async hide() { if (toast === this) toast = undefined; }
    }
    const PopToRootType = Object.freeze({ Default: "default", Immediate: "immediate", Suspended: "suspended" });
    const effects = [];
    function effect(capability, kind, value) {
      if (!grants.has(capability)) throw new Error("Unavailable host capability");
      if (effects.length >= 8) throw new Error("Host effect budget exceeded");
      effects.push({ kind, value });
    }
    function fields(options, keys) {
      if (options === undefined) return {};
      if (options === null || typeof options !== "object" || Array.isArray(options)
          || Object.keys(options).some(key => !keys.includes(key))) throw new TypeError("Invalid options");
      return options;
    }
    const bool = value => {
      if (typeof value !== "boolean") throw new TypeError("Expected boolean");
      return String(value);
    };
    function closeOptions(options) {
      const { clearRootSearch = false, popToRootType = "default" } = fields(options, ["clearRootSearch", "popToRootType"]);
      if (!Object.values(PopToRootType).includes(popToRootType)) throw new TypeError("Invalid return mode");
      return { clearRootSearch: bool(clearRootSearch), popToRootType };
    }
    async function closeMainWindow(options) {
      const { clearRootSearch, popToRootType } = closeOptions(options);
      effect("navigation.close", "close", popToRootType === "default" ? clearRootSearch : popToRootType + ":" + clearRootSearch);
    }
    async function clearSearchBar(options) {
      const { forceScrollToTop = true } = fields(options, ["forceScrollToTop"]);
      effect("navigation.clearSearch", "clearSearch", bool(forceScrollToTop));
    }
    async function popToRoot(options) {
      const { clearSearchBar = false } = fields(options, ["clearSearchBar"]);
      effect("navigation.popToRoot", "popToRoot", bool(clearSearchBar));
    }
    async function showHUD(title, options) {
      const { clearRootSearch, popToRootType } = closeOptions(options);
      if (typeof title !== "string" || !title || !grants.has("feedback.toast")) throw new Error("Unavailable HUD");
      if (clearRootSearch === "true" || popToRootType !== "default") {
        await closeMainWindow({ clearRootSearch: clearRootSearch === "true", popToRootType });
      }
      effect("feedback.toast", "toast", JSON.stringify({ operation: "show", id: 1, title, style: "SUCCESS" }));
    }
    async function showToast(options, legacyTitle, legacyMessage) {
      const result = new Toast(typeof options === "string"
        ? { style: options, title: legacyTitle, message: legacyMessage } : options);
      await result.show();
      return result;
    }
    const useActionPanel = () => {
      const current = React.useContext(Page);
      return React.useMemo(() => ({
        update(node) {
          if (node != null && !React.isValidElement(node)) throw new Error("Invalid ActionPanel");
          if (stack[stack.length - 1]?.id !== current) return;
          if (node == null) panels.delete(current);
          else panels.set(current, node);
          update();
        },
      }), [current]);
    };
    function bind(id, fn) {
      if (typeof fn === "function") handlers.set(id, fn);
    }

    function actions(parent, prefix, depth = 0, group = 0, registry = { next: 0 }) {
      if (depth > 3) throw new Error("Action nesting limit");
      if (parent.children.length > 32) throw new Error("Action limit");
      return parent.children.flatMap((item, index) => {
        if (item.hidden) return [];
        const id = prefix + "-" + index;
        if (item.type === "section") return actions(item, id, depth + 1, ++registry.next, registry);
        const { title, style, shortcut, onAction, onSearchTextChange } = item.props;
        const data = { id, title, style: style ?? "regular", shortcut, group };
        if (item.type === "submenu") {
          if (onSearchTextChange) bind("search:" + id, query => onSearchTextChange(query));
          return [{ ...data, children: actions(item, id, depth + 1), searchable: !!onSearchTextChange }];
        }
        if (item.type !== "action") throw new Error("Unsupported action node");
        bind(id, onAction);
        return [data];
      });
    }

    function snapshot() {
      if (error) throw error;
      const current = tree.children.find(page => page.props.active);
      const detail = current?.children[0];
      if ((!detail && !fallback && stack.length) || (detail && (detail.type !== "detail" || current.children.length > 2)))
        throw new Error("Only a single Detail is supported per page");
      const actionPanel = current?.children[1] ?? detail?.children[0];
      if (actionPanel && (actionPanel.type !== "panel" || (detail?.children.length ?? 0) > 1))
        throw new Error("Invalid ActionPanel");
      handlers = new Map();
      const toastAction = (id, action) => {
        if (!action) return undefined;
        bind(id, action.onAction);
        return { id, title: action.title, style: action.style === "destructive" ? "destructive" : "regular" };
      };
      return {
        effects: effects.length ? effects.splice(0) : undefined,
        markdown: detail?.props.markdown ?? "",
        navigationTitle: detail?.props.navigationTitle,
        isLoading: detail?.props.isLoading ?? (!detail && !!fallback),
        depth: Math.max(0, stack.length - 1),
        actions: actionPanel ? actions(actionPanel, "a") : [],
        confirmation: alert && { title: alert.options.title, message: alert.options.message,
          acceptTitle: alert.options.primaryAction?.title ?? "OK", cancelTitle: alert.options.dismissAction?.title,
          destructive: alert.options.primaryAction?.style === "destructive" },
        toast: toast && { title: toast.title, message: toast.message, style: String(toast.style).toLowerCase(),
          primary: toastAction("toast-primary", toast.primaryAction),
          secondary: toastAction("toast-secondary", toast.secondaryAction) },
      };
    }

    async function settle() {
      // Allow chained resolved promises and React commits before projecting the
      // next frame. Unresolved promises (e.g. confirmation) never block input.
      for (let turn = 0; turn < 8; turn++) {
        await Promise.resolve();
        renderer.flushSyncWork();
        renderer.flushPassiveEffects();
        const callbacks = [...scheduled.entries()];
        for (const [id, run] of callbacks) if (scheduled.delete(id)) run();
      }
      return snapshot();
    }
    function start(Command) {
      if (stack.length) return settle();
      if (typeof Command !== "function") throw new Error("Missing view default export");
      // A regular component must run inside React to support hooks. An explicit
      // render() entry can be a plain async command.
      if (Command.constructor?.name === "AsyncFunction") {
        fallback = true;
        observe(Command({}));
      } else {
        render(h(Command, {}));
      }
      return settle();
    }
    function onEvent(event) {
      renderer.flushSyncFromReconciler(() => {
        if (event.kind === "back") navigation.pop();
        else if (event.kind === "confirm" || event.kind === "dismiss") {
          if (!alert) throw new Error("No pending confirmation");
          const pending = alert;
          alert = undefined;
          const accepted = event.kind === "confirm";
          observe((accepted ? pending.options.primaryAction : pending.options.dismissAction)?.onAction?.());
          pending.resolve(accepted);
        } else if (event.kind === "search") {
          observe(handlers.get("search:" + event.actionID)?.(event.query));
        } else if (event.kind === "action" || event.kind === "toastAction") {
          observe(handlers.get(event.actionID)?.());
        } else throw new Error("Unknown view event");
      });
      return settle();
    }
    module.exports = { Action, ActionPanel, Detail, ActionPanelItem: Action, ActionPanelSection: ActionPanel.Section,
      ActionPanelSubmenu: ActionPanel.Submenu, PushAction: Action.Push, confirmAlert, Toast, ToastStyle: Toast.Style, showToast, render,
      PopToRootType, showHUD, closeMainWindow, clearSearchBar, popToRoot,
      useNavigation: () => navigation, useActionPanel, useId: React.useId, start, onEvent };
    """#
}
