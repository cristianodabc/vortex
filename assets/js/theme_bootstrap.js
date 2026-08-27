(() => {
  const themes = new Set(["system", "light", "dark"])
  const storageKey = "phx:theme"
  const media = window.matchMedia("(prefers-color-scheme: dark)")

  const storedPreference = () => {
    try {
      const stored = window.localStorage.getItem(storageKey)
      return themes.has(stored) ? stored : "system"
    } catch (_error) {
      return "system"
    }
  }

  const resolvedTheme = preference => {
    if (preference === "system") return media.matches ? "dark" : "light"
    return preference
  }

  const persist = preference => {
    try {
      if (preference === "system") {
        window.localStorage.removeItem(storageKey)
      } else {
        window.localStorage.setItem(storageKey, preference)
      }
    } catch (_error) {
      // Theme persistence is optional when storage is unavailable.
    }
  }

  const apply = (preference, options = {}) => {
    const normalized = themes.has(preference) ? preference : "system"

    if (options.persist !== false) persist(normalized)

    document.documentElement.dataset.theme = resolvedTheme(normalized)
    document.documentElement.dataset.themeSource = normalized === "system" ? "system" : "user"
    document.documentElement.dataset.themePreference = normalized

    if (options.broadcast !== false) {
      window.dispatchEvent(new CustomEvent("vortex:theme-changed", {
        detail: {theme: normalized},
      }))
    }

    return normalized
  }

  window.VortexTheme = {
    preference: () => document.documentElement.dataset.themePreference || storedPreference(),
    set: preference => apply(preference),
  }

  apply(storedPreference(), {persist: false, broadcast: false})

  window.addEventListener("phx:set-theme", event => {
    apply(event.target?.dataset?.phxTheme)
  })

  window.addEventListener("storage", event => {
    if (event.key === storageKey) apply(event.newValue || "system", {persist: false})
  })

  media.addEventListener("change", () => {
    if (window.VortexTheme.preference() === "system") {
      apply("system", {persist: false})
    }
  })
})()
