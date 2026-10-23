const key = "phx:theme"
const root = document.documentElement
const normalize = (value) => (["light", "dark"].includes(value) ? value : "system")

const applyTheme = (value) => {
  const theme = normalize(value)
  if (theme === "system") root.removeAttribute("data-theme")
  else root.dataset.theme = theme

  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme))
  })
}

// Storage can be unavailable in private/restricted browsers; switching still works.
let saved = "system"
try {
  saved = localStorage.getItem(key)
} catch {}
applyTheme(saved)

const closeMenus = () =>
  document.querySelectorAll(".ui-theme-menu[open]").forEach((menu) => {
    menu.open = false
  })

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-choice]")
  if (button) {
    const theme = normalize(button.dataset.themeChoice)
    applyTheme(theme)
    try {
      if (theme === "system") localStorage.removeItem(key)
      else localStorage.setItem(key, theme)
    } catch {}
    const menu = button.closest("details")
    menu.open = false
    menu.querySelector("summary").focus()
  } else if (!event.target.closest(".ui-theme-menu")) {
    closeMenus()
  }
})

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    const menu = document.activeElement.closest(".ui-theme-menu[open]")
    closeMenus()
    menu?.querySelector("summary").focus()
  }
})

window.addEventListener("storage", (event) => {
  if (event.key === key || event.key === null) applyTheme(event.newValue)
})
window.addEventListener("phx:page-loading-stop", () => applyTheme(root.dataset.theme))
