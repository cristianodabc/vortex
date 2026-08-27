const allowedThemes = new Set(["system", "light", "dark"])

const ThemeSync = {
  mounted() {
    this.syncTheme = event => {
      const theme = event?.detail?.theme
      if (allowedThemes.has(theme)) this.pushEvent("theme_changed", {theme})
    }

    window.addEventListener("vortex:theme-changed", this.syncTheme)

    const theme = window.VortexTheme?.preference()
    if (allowedThemes.has(theme)) this.pushEvent("theme_changed", {theme})
  },

  destroyed() {
    window.removeEventListener("vortex:theme-changed", this.syncTheme)
  },
}

export default ThemeSync
