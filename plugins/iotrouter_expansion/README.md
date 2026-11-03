# IOTRouter expansion cards

Experimental, explicitly started EM300 expansion-bus driver. Startup of the plugin
opens nothing and never starts the bus. The gateway owns exclusive assignment,
plugin lifecycle and I/O authority; this plugin owns discovery, UART/GPIO handles,
card protocol and channel reconciliation. No broker or vendor agent is required.

## Use

1. Build firmware selecting this plugin in `plugins/selection.exs`. It needs SDK
   `0.2.0-dev.9` firmware, including shared native `circuits_uart` 1.7.0 and
   `circuits_gpio` 2.3.1. Native libraries are not bundled in the plugin archive.
   The plugin requires `:iotrouter_expansion` hardware, so it is bundled only
   for EM300, not EC100 or QEMU. Gateway activation checks presence too.
2. Explicitly start the plugin and review the Expansion Bus assignment on Hardware.
   Exactly one present, enabled `:iotrouter_expansion` resource must belong to it.
   The path and named reset/link GPIOs come from that assignment, not constants.
3. On `/plugins/iotrouter_expansion`, choose **Reset and start bus** only with a
   safe fixture: reset changes the cards' outputs to their power-on state. The bus
   opens at 921600 8N1, no flow control. Reset is driven low for 50 ms and released
   high (the captured stock idle level), followed by a 500 ms boot wait. Reset
   polarity and timing still need physical qualification.
4. Discovered channels appear on `/io`. Output Desires need the ordinary exclusive
   I/O claim; registration itself never writes outputs. **Stop bus** closes handles.
   A bus fault does not reconnect/reset automatically; restart the whole plugin to
   verify cleanup before another Start. Unloading uses checked whole-plugin stop.

No configuration is saved: the chain is rediscovered only on explicit Start. Cards
are not hot-plugged automatically. An absent chain or unsupported card fails Start.
Up to 16 cards are supported, addressed sequentially from 1 with an explicit last
card response. Stop/restart does not import or replay output Desires.

## Initial supported layouts

Only observed descriptors are accepted: type 1 D1600 (16 DI) and type 2 D0016N
(16 NPN DO), no mixed/analog channels. Other descriptors are rejected, not guessed.
Digital slots use one byte per channel. DI encoding still needs an electrical
stimulus test; this implementation is not a qualified field driver. No support is
claimed for D0016P, D0008R, analog cards, or the main board's GPIO I/O.

IDs include chain address and type: `iotrouter_expansion.card1_d1600.di0`,
`iotrouter_expansion.card2_d0016n.do0` and its input `.do0_state`. Channel numbers
are zero-based. Position is not a serial identity: keep the chain order fixed;
replace/reorder equipment only after stopping and reviewing endpoint meaning.
Endpoint definitions remain in the gateway catalogue after stopping.

DO echo is readback evidence of card output state, not electrical feedback from
connected equipment. Setters preserve the latest known values of other channels,
send the complete 32-byte state and repeat until echo matches (300 ms deadline).
Unconfirmed results are unknown, not success. The SDK Output runtime reconciles
current repeatable Desires after one second; released Desires hold state. No
physical safe-state guarantee is provided. Missing cyclic data stops the bus;
there is no automatic reset/reconnect. The initial bench run reported an inactive
link GPIO despite successful streaming; its electrical meaning/polarity remains
unqualified and it does not gate discovery.

## Protocol and evidence

Discovery/configuration requests wait 25 ms before transmission, matching the
stock agent's observed command spacing; replies normally arrive in under 2 ms.
A reply does not imply the chain is ready for the next request. This pacing is
separate from the unchanged 100 ms response deadline; failures are not retried.
This is not a fix for warm reinitialization: on the bench, 0.1.1-dev.1 discovered
both cards after a gateway reboot, but a subsequent bus stop/start timed out on
card 2 again. Reset propagation/timing and downstream state need investigation.
Do not treat one successful discovery as restart qualification or blindly repeat
Start after failure.

The pure protocol tests use sanitized stock capture vectors. Commands are
`AA function length payload CRC16 55`; CRC-16/MODBUS covers function through
payload, little-endian. Search returns address, type, version, format byte 1 and
DI/DO/AI/AO counts; function 03 marks the last card. Zero configuration matches
stock captures, but the meaning of configuration bytes remains unknown. After
Start, cyclic data is 32 bytes per card plus CRC, without framing markers. CRC
resynchronization detects corruption but is not an authenticated protocol.

Host tests cover protocol, endpoint definitions, missing-runtime rejection and UI.
An initial physical bench run discovered D1600 v3 and D0016N v1, streamed inputs,
and confirmed DO0/DO8 on/off through card echo. DI0/DI8 stayed false throughout
operator-reported loopback wiring, so the electrical loopback test did **not** pass.
Both outputs were returned to false, manual Desires/claims released and the bus
and plugin stopped. Wiring, input electrical mode and data encoding need checking;
card echo alone is not proof that an output terminal switched electrically.

Reset timing, DI encoding, electrical output behavior, chain removal, independent
native-handle cleanup and device-side output epochs remain unqualified.
