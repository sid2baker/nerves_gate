import {Socket} from "/vendor/phoenix/phoenix.mjs";
import {LiveSocket} from "/vendor/live_view/phoenix_live_view.esm.js";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const syncInternetFields = select => {
  const fields = document.getElementById(select.getAttribute("aria-controls"));
  if (!fields) return;

  const staticAddressing = select.value === "static";
  fields.hidden = !staticAddressing;
  select.setAttribute("aria-expanded", String(staticAddressing));
  fields.querySelectorAll("input").forEach(input => input.disabled = !staticAddressing);
};

const hooks = {
  InternetMethod: {
    mounted() { syncInternetFields(this.el); },
    updated() { syncInternetFields(this.el); }
  }
};

const liveSocket = new LiveSocket("/live", Socket, {
  hooks,
  params: {_csrf_token: csrfToken}
});
liveSocket.connect();

document.querySelectorAll("[data-internet-method]").forEach(syncInternetFields);
document.addEventListener("change", event => {
  if (event.target.matches("[data-internet-method]")) syncInternetFields(event.target);
});
