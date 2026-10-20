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
