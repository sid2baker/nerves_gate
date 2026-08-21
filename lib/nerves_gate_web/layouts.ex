defmodule NervesGateWeb.Layouts do
  @moduledoc false
  use NervesGateWeb, :html

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>NervesGate</title>
        <style>
          :root {
            color-scheme: dark;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #0a0d12;
            color: #f3f5f7;
            font-synthesis: none;
          }
          * { box-sizing: border-box; }
          body { margin: 0; min-width: 320px; background: radial-gradient(circle at 50% -20%, #1a2731 0, #0a0d12 42rem); }
          button, input, select { font: inherit; }
          a { color: inherit; }
          code { font-family: "SFMono-Regular", Consolas, monospace; }
          .dashboard, .setup-shell { width: min(1220px, calc(100% - 2rem)); margin: 0 auto; padding: 1.5rem 0 4rem; }
          .topbar { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 1rem; min-height: 4.5rem; }
          .brand h1, .setup-header h1 { margin: .1rem 0 0; font-size: clamp(1.4rem, 3vw, 2rem); letter-spacing: -.04em; }
          .eyebrow { color: #80909e; font-size: .68rem; font-weight: 800; letter-spacing: .16em; text-transform: uppercase; }
          .node-menu { position: relative; z-index: 20; }
          .node-menu summary { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border: 1px solid #303b45; border-radius: .75rem; background: #131920; cursor: pointer; list-style: none; }
          .node-menu summary::-webkit-details-marker { display: none; }
          .hamburger { font-size: 1.35rem; line-height: 1; }
          .node-menu nav { position: absolute; top: 3.25rem; left: 0; width: min(22rem, calc(100vw - 2rem)); padding: .6rem; border: 1px solid #303b45; border-radius: .85rem; background: #11171e; box-shadow: 0 20px 60px #000b; }
          .menu-title { padding: .65rem .7rem; color: #80909e; font-size: .72rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
          .node-menu nav a { display: flex; align-items: center; gap: .7rem; padding: .7rem; border-radius: .55rem; text-decoration: none; }
          .node-menu nav a:hover, .node-menu nav a.current { background: #1b242d; }
          .node-menu nav a span:nth-child(2) { display: grid; gap: .12rem; }
          .node-menu nav small { color: #80909e; }
          .node-dot { width: .55rem; height: .55rem; border-radius: 50%; background: #64717d; }
          .node-dot.online { background: #42d392; box-shadow: 0 0 0 .22rem #42d39218; }
          .tailnet-summary { display: flex; align-items: center; gap: 1rem; text-align: right; }
          .tailnet-summary > div:first-child { display: grid; gap: .15rem; }
          .tailnet-summary small { color: #80909e; font-family: "SFMono-Regular", Consolas, monospace; }
          .people { display: flex !important; grid-auto-flow: column; align-items: center; gap: .4rem !important; padding: .58rem .72rem; border: 1px solid #30463d; border-radius: 2rem; background: #15251f; color: #73e5b4; }
          .hero { display: flex; justify-content: space-between; align-items: end; gap: 1rem; min-height: 13rem; padding: 3rem 0 2rem; border-top: 1px solid #222a32; }
          .hero h2 { margin: .7rem 0 .35rem; font-size: clamp(2rem, 7vw, 4.6rem); line-height: .95; letter-spacing: -.065em; }
          .hero p, .setup-header p, .card p { color: #96a3ae; line-height: 1.6; }
          .state { display: inline-flex; align-items: center; width: max-content; padding: .32rem .58rem; border-radius: 2rem; font-size: .72rem; font-weight: 800; text-transform: uppercase; letter-spacing: .08em; }
          .state.good { background: #15392d; color: #7be2b7; }
          .state.bad { background: #402122; color: #ff9b9b; }
          .button-link, button { border: 0; border-radius: .58rem; background: #e8edf0; color: #11161b; padding: .72rem 1rem; font-weight: 800; text-decoration: none; cursor: pointer; }
          button:hover, .button-link:hover { background: #fff; }
          button:disabled { cursor: not-allowed; opacity: .35; }
          .metric-row { display: grid; grid-template-columns: repeat(4, 1fr); border: 1px solid #27313a; border-radius: .85rem; background: #11161c; overflow: hidden; }
          .metric { display: grid; gap: .4rem; padding: 1.15rem 1.25rem; border-right: 1px solid #27313a; }
          .metric:last-child { border-right: 0; }
          .metric span { color: #80909e; font-size: .76rem; font-weight: 700; }
          .metric strong { font-size: 1.25rem; }
          .good-text { color: #6de0af !important; }
          .bad-text { color: #ff8f8f !important; }
          .muted { color: #80909e !important; }
          .content-grid, .setup-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1rem; margin-top: 1rem; }
          .card { min-width: 0; padding: 1.3rem; border: 1px solid #27313a; border-radius: .85rem; background: linear-gradient(145deg, #131920, #10151b); }
          .card h2 { margin: .25rem 0 1.1rem; font-size: 1.12rem; letter-spacing: -.02em; }
          .span-two { grid-column: span 2; }
          .inline-form { display: grid; grid-template-columns: 1fr auto; align-items: end; gap: .7rem; margin-bottom: 1.2rem; }
          label { display: grid; gap: .4rem; color: #9eabb5; font-size: .78rem; font-weight: 700; }
          input, select { width: 100%; min-height: 2.7rem; padding: .65rem .75rem; border: 1px solid #35414c; border-radius: .52rem; outline: none; background: #0a0f14; color: #f4f6f8; }
          input:focus, select:focus { border-color: #5eae8d; box-shadow: 0 0 0 3px #4bc28f1c; }
          .details { display: grid; grid-template-columns: minmax(8rem, .7fr) 1.3fr; gap: .55rem 1rem; margin: 0; }
          .details.compact { grid-template-columns: minmax(6rem, .8fr) 1.2fr; }
          dt { color: #80909e; } dd { margin: 0; overflow-wrap: anywhere; }
          .hint { margin: 1.2rem 0 0; padding-top: 1rem; border-top: 1px solid #27313a; font-size: .78rem; }
          .hint code, .endpoint { color: #72d9ac; }
          .subtle-link { display: inline-block; margin-top: 1.2rem; color: #78dbb1; font-weight: 700; text-decoration: none; }
          .checks, .alarm-list { margin: 0; padding: 0; list-style: none; }
          .checks li { display: flex; justify-content: space-between; gap: 1rem; padding: .56rem 0; border-bottom: 1px solid #222b34; }
          .checks li:last-child { border-bottom: 0; }
          .checks strong { font-size: .82rem; text-align: right; }
          table { width: 100%; border-collapse: collapse; }
          th, td { padding: .68rem .5rem; border-bottom: 1px solid #27313a; text-align: left; }
          th { color: #80909e; font-size: .72rem; text-transform: uppercase; letter-spacing: .08em; }
          td a { color: #76dcb2; text-decoration: none; font-weight: 700; }
          .alarm-list li { display: grid; gap: .25rem; padding: .7rem 0; border-bottom: 1px solid #38292b; }
          .alarm-list span { color: #bd9a9d; }
          .empty-state { color: #6de0af !important; }
          .danger-zone { border-color: #493034; }
          button.danger { width: 100%; margin-top: .5rem; background: #49282b; color: #ffb3b3; }
          .flash { padding: .8rem 1rem; border: 1px solid #315e4d; border-radius: .6rem; background: #13271f; }
          .flash.bad { border-color: #60383c; background: #2b191b; color: #ffb0b0; }
          .setup-shell { width: min(1100px, calc(100% - 2rem)); }
          .setup-header { display: flex; justify-content: space-between; align-items: end; gap: 2rem; padding: 4rem 0 2rem; }
          .setup-header h1 { font-size: clamp(2rem, 6vw, 4rem); }
          .phase-pill { padding: .55rem .8rem; border: 1px solid #345446; border-radius: 2rem; color: #72d9ac; text-transform: capitalize; }
          .steps { display: grid; grid-template-columns: repeat(4, 1fr); margin: 1rem 0 2rem; padding: 0; list-style: none; }
          .steps li { display: flex; align-items: center; gap: .55rem; padding: .8rem; border-bottom: 2px solid #26313a; color: #65727e; font-size: .8rem; font-weight: 800; text-transform: uppercase; letter-spacing: .08em; }
          .steps li span { display: grid; place-items: center; width: 1.55rem; height: 1.55rem; border: 1px solid currentColor; border-radius: 50%; }
          .steps li.complete { border-color: #57c99a; color: #74dfb2; }
          .setup-card { position: relative; }
          .setup-card form { display: grid; gap: .15rem; }
          .setup-card button { width: 100%; margin-top: .4rem; }
          .step-number { position: absolute; top: 1rem; right: 1rem; color: #34414c; font-size: 2rem; font-weight: 900; }
          .endpoint { display: block; margin-top: 1rem; font-size: .72rem; }
          .ready-banner { display: flex; justify-content: space-between; gap: 1rem; margin-top: 1rem; padding: 1rem 1.2rem; border: 1px solid #3f7d64; border-radius: .8rem; background: #163326; color: #9ce9c8; }
          .ready-banner a { font-weight: 800; }
          @media (max-width: 820px) {
            .metric-row { grid-template-columns: 1fr 1fr; }
            .metric:nth-child(2) { border-right: 0; }
            .metric:nth-child(-n+2) { border-bottom: 1px solid #27313a; }
            .content-grid, .setup-grid { grid-template-columns: 1fr; }
            .span-two { grid-column: span 1; }
            .setup-header { align-items: start; flex-direction: column; }
          }
          @media (max-width: 560px) {
            .dashboard, .setup-shell { width: min(100% - 1rem, 1220px); padding-top: .5rem; }
            .topbar { grid-template-columns: auto 1fr; }
            .tailnet-summary { grid-column: 1 / -1; justify-content: space-between; padding: .65rem 0; border-top: 1px solid #222a32; text-align: left; }
            .hero { align-items: start; flex-direction: column; min-height: 11rem; }
            .metric-row { grid-template-columns: 1fr; }
            .metric { border-right: 0; border-bottom: 1px solid #27313a; }
            .metric:last-child { border-bottom: 0; }
            .inline-form { grid-template-columns: 1fr; }
            .steps li { justify-content: center; padding: .65rem .2rem; font-size: 0; }
            .steps li span { font-size: .75rem; }
            .ready-banner { flex-direction: column; }
          }
        </style>
        <script type="module" src="/assets/app.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
