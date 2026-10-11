import {Socket} from "/vendor/phoenix/phoenix.mjs"
import {LiveSocket} from "/vendor/live_view/phoenix_live_view.esm.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").content
const Hooks = {
  CopyAddress: {
    mounted() {
      this.el.addEventListener("click", () => this.el.select())
    }
  }
}
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks})
liveSocket.connect()
