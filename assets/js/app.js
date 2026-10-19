import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").content
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    ScrollToBottom: {
      mounted() {
        this.el.scrollTop = this.el.scrollHeight
      },
      updated() {
        this.el.scrollTop = this.el.scrollHeight
      }
    }
  }
})
liveSocket.connect()

// The server renders the saved theme from this cookie on the next page load.
function toggleTheme() {
  const root = document.documentElement
  const dark = root.dataset.theme
    ? root.dataset.theme === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches
  const theme = dark ? "light" : "dark"
  root.dataset.theme = theme
  document.cookie = `theme=${theme}; path=/; max-age=31536000; SameSite=Lax`
}

document.addEventListener("click", (event) => {
  if (event.target.closest("[data-theme-toggle]")) toggleTheme()
})
