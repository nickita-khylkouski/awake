import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func battery(_ percent: Int, onBattery: Bool = true) -> BatterySnapshot {
    BatterySnapshot(current: percent, maximum: 100, onBattery: onBattery)!
}

let protection = BatteryProtection()
var events: [String] = []
var restoreSucceeds = true
var sleepResult: Int32 = 0
func evaluate(_ value: BatterySnapshot?) {
    protection.evaluate(value, prepare: {
        events.append("release assertions and restore closed-lid sleep")
        return restoreSucceeds
    }, sleep: {
        events.append("sleep")
        return sleepResult
    })
}

evaluate(battery(6))
evaluate(battery(5, onBattery: false))
evaluate(nil)
check(events.isEmpty, "Must not sleep above 5%, on AC, or without a valid reading")
evaluate(battery(5))
check(events == ["release assertions and restore closed-lid sleep", "sleep"], "Restore must precede the sleep request at exactly 5%")
check(protection.sleepRequested, "Successful sleep must be remembered")
evaluate(battery(4))
evaluate(nil)
evaluate(battery(3))
check(events.count == 2, "Waking on a low battery must not create a sleep loop")
evaluate(battery(3, onBattery: false))
evaluate(battery(3))
check(events.count == 4, "Unplugging at a critical level must trigger again")
evaluate(battery(6))
restoreSucceeds = false
evaluate(battery(0))
check(events.last != "sleep" && protection.error != nil, "Failed restoration must surface an error without claiming sleep")
restoreSucceeds = true
sleepResult = -1
evaluate(battery(0))
check(!protection.sleepRequested && protection.error != nil, "Rejected sleep must remain retryable")
sleepResult = 0
evaluate(battery(0))
check(protection.sleepRequested && protection.error == nil, "A later retry must recover")
check(BatterySnapshot(current: -1, maximum: 100, onBattery: true) == nil, "Reject negative capacity")
check(BatterySnapshot(current: 4, maximum: 0, onBattery: true) == nil, "Reject zero maximum")
check(BatterySnapshot(current: 101, maximum: 100, onBattery: true) == nil, "Reject impossible capacity")
check(BatterySnapshot(current: 250, maximum: 5000, onBattery: true)?.isCritical == true, "Normalize capacity units")
for percent in 0...100 { check(battery(percent).percent == percent, "Preserve exact percentages") }
print("PASS: 5% threshold, AC exclusion, startup at 0%, wake-loop prevention, rearming, restoration order and retry")

func command(_ value: String) -> AwakeCommand? { URL(string: value).flatMap(AwakeCommand.init(url:)) }
check(command("awake://start?seconds=1800") == .start(seconds: 1800, display: nil), "Parse timer")
check(command("awake://start?display=0") == .start(seconds: nil, display: false), "Parse display mode")
check(command("awake://controls") == .controls, "Parse standalone controls")
check(command("awake://menu") == .menu, "Parse menu-bar popover")
check(command("awake://stop") == .stop, "Parse stop")
for invalid in ["awake://start?seconds=nan", "awake://start?seconds=inf", "awake://start?seconds=-1", "awake://start?seconds=0", "awake://start?seconds=999999999", "awake://start?seconds=1&seconds=2", "awake://start?display=no", "awake://stop?seconds=1", "awake://start/path", "https://start", "awake://user@start", "awake://start?unknown=1"] {
    check(command(invalid) == nil, "Reject malformed command: \(invalid)")
}
print("PASS: command delivery parsing rejects invalid, duplicate and overflowing timer arguments")
