.pragma library

var ICON = ""           // nf-fa-bolt
var ICON_FAULT = ""     // nf-fa-warning

// The 12V-2x6 connector is rated 9.5 A per pin; the popup's pin bars use it
// as full scale and turn urgent above it.
var PIN_RATED_A = 9.5

// fault_status / fault_log bit names, in the device's bit order.
var FAULTS = [
  "chip over-temperature",
  "sensor over-temperature",
  "over-current",
  "wire over-current",
  "over-power",
  "current imbalance"
]
var FAULT_CURRENT_IMBALANCE = 1 << 5

var TEMP_LABELS = ["Onboard in", "Onboard out", "External 1", "External 2"]

// Finds the hwmon device by name (its hwmonN index is not stable across
// boots) and prints "attr:value" lines. A missing device prints nothing, and
// attributes the module reports as stale (ENODATA once wireviewd stops
// feeding it) are skipped by grep -s.
var READ_SCRIPT = [
  "for d in /sys/class/hwmon/hwmon*; do",
  "  { read -r name < \"$d/name\"; } 2>/dev/null || continue",
  "  [ \"$name\" = wireview ] || continue",
  "  cd \"$d\" || exit 0",
  "  exec /usr/bin/grep -s -H . in?_input curr?_input power?_input power1_cap temp?_input energy1_input pwm1 fault_status_raw fault_log_raw",
  "done"
].join("\n")

// "attr:value" lines into { attr: integer }.
function parse(text) {
  var out = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var sep = lines[i].indexOf(":")
    if (sep <= 0) continue
    var value = parseInt(lines[i].slice(sep + 1), 10)
    if (!isNaN(value)) out[lines[i].slice(0, sep)] = value
  }
  return out
}

function faultNames(mask) {
  var names = []
  for (var i = 0; i < FAULTS.length; i++) {
    if (mask & (1 << i)) names.push(FAULTS[i])
  }
  if (mask >> FAULTS.length) names.push("unknown fault 0x" + mask.toString(16))
  return names
}

// Raw hwmon values (mV, mA, uW, m°C, uJ) into display units, or null while
// there is no fresh frame.
function snapshot(raw) {
  if (raw.power1_input === undefined) return null

  var pins = []
  var maxA = -Infinity
  var minA = Infinity
  var maxPin = 0
  for (var i = 0; i < 6; i++) {
    var amps = (raw["curr" + (i + 1) + "_input"] || 0) / 1000
    pins.push({
      label: "Pin " + (i + 1),
      amps: amps,
      volts: (raw["in" + i + "_input"] || 0) / 1000,
      watts: (raw["power" + (i + 2) + "_input"] || 0) / 1e6
    })
    if (amps > maxA) { maxA = amps; maxPin = i }
    if (amps < minA) minA = amps
  }

  var temps = []
  for (var t = 0; t < TEMP_LABELS.length; t++) {
    var milli = raw["temp" + (t + 1) + "_input"]
    if (milli !== undefined) temps.push({ label: TEMP_LABELS[t], celsius: milli / 1000 })
  }

  return {
    watts: raw.power1_input / 1e6,
    amps: (raw.curr7_input || 0) / 1000,
    volts: (raw.in6_input || 0) / 1000,
    capW: raw.power1_cap !== undefined ? raw.power1_cap / 1e6 : 0,
    pins: pins,
    maxA: maxA,
    minA: minA,
    maxPin: maxPin,
    spreadA: maxA - minA,
    temps: temps,
    energyWh: raw.energy1_input !== undefined ? raw.energy1_input / 3.6e9 : -1,
    fanPercent: raw.pwm1 !== undefined ? Math.round(raw.pwm1 * 100 / 255) : -1,
    faultStatus: raw.fault_status_raw || 0,
    faultLog: raw.fault_log_raw || 0
  }
}

function hottest(snap) {
  var best = null
  for (var i = 0; i < snap.temps.length; i++) {
    if (!best || snap.temps[i].celsius > best.celsius) best = snap.temps[i]
  }
  return best
}

function status(snap) {
  if (!snap) return "Offline"
  if (snap.faultStatus) return faultNames(snap.faultStatus).join(", ")
  if (snap.maxA > PIN_RATED_A) return "Pin over " + PIN_RATED_A + " A"
  return "No faults"
}

function tooltip(snap) {
  if (!snap) return "WireView: no data (is wireviewd running?)"
  var text = "GPU connector " + snap.watts.toFixed(1) + " W · " + snap.amps.toFixed(2) + " A"
  text += "\nHighest: " + snap.pins[snap.maxPin].label + " at " + snap.maxA.toFixed(2) + " A"
  var hot = hottest(snap)
  if (hot) text += " · " + hot.celsius.toFixed(1) + "°C max"
  if (snap.faultStatus) text += "\nFault: " + faultNames(snap.faultStatus).join(", ")
  return text
}
