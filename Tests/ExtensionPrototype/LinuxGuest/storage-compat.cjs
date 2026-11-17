// The deprecated exports use the same extension-scoped storage and authorization.
function localStorageAliases(LocalStorage) {
  return {
    allLocalStorageItems: LocalStorage.allItems,
    clearLocalStorage: LocalStorage.clear,
    getLocalStorageItem: LocalStorage.getItem,
    removeLocalStorageItem: LocalStorage.removeItem,
    setLocalStorageItem: LocalStorage.setItem,
  };
}

function clipboardAliases(Clipboard) {
  return {
    copyTextToClipboard: Clipboard.copy,
    pasteText: Clipboard.paste,
    clearClipboard: Clipboard.clear,
  };
}

module.exports = { localStorageAliases, clipboardAliases };
