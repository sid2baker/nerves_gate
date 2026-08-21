import {Socket} from "/vendor/phoenix/phoenix.mjs";
import {LiveSocket} from "/vendor/live_view/phoenix_live_view.esm.js";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}});
liveSocket.connect();
