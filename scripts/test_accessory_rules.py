#!/usr/bin/env python3
"""Behavior checks for AccessoryPowerRules.

The Swift implementation lives in AirBattery/BatteryInfo/AccessoryPowerMonitor.swift.
These cases encode the same rules. scripts/check-accessory-power.sh also checks
that the Swift source still contains the category and notify-name strings.
"""

def normalize_id(raw: str) -> str:
    return raw.strip().upper().replace("-", ":")


ALLOWED = {"Mouse", "Keyboard", "Trackpad"}


def resolved_category(category: str, name: str, transport: str):
    if category == "Watch":
        return None
    if category in ALLOWED:
        return category
    if category and category != "Unknown":
        return None
    if transport not in {"Bluetooth", "Bluetooth LE", "USB"}:
        return None
    lower = name.lower()
    if "watch" in lower:
        return None
    if "mouse" in lower:
        return "Mouse"
    if "trackpad" in lower:
        return "Trackpad"
    if "keyboard" in lower:
        return "Keyboard"
    return None


def percent(current: int, max_capacity: int):
    if max_capacity > 0 and max_capacity != 100:
        value = int(round(current / max_capacity * 100.0))
    else:
        value = current
    return value if 0 <= value <= 100 else None


def device_type(category: str) -> str:
    return "MMouse" if category == "Mouse" else category


def main() -> None:
    assert normalize_id(" bc-89:a7 ") == "BC:89:A7"
    assert normalize_id("BC:89:A7:E9:61:14") == "BC:89:A7:E9:61:14"
    assert resolved_category("Watch", "Apple Watch", "Bluetooth") is None
    assert resolved_category("Mouse", "Magic Mouse", "Bluetooth") == "Mouse"
    assert resolved_category("Keyboard", "Magic Keyboard", "USB") == "Keyboard"
    assert resolved_category("Trackpad", "Magic Trackpad", "Bluetooth") == "Trackpad"
    assert resolved_category("Headphone", "AirPods Pro", "Bluetooth") is None
    assert resolved_category("Pencil", "Apple Pencil", "Bluetooth") is None
    assert resolved_category("Game Controller", "Controller", "Bluetooth") is None
    assert resolved_category("", "Magic Mouse", "Bluetooth") == "Mouse"
    assert resolved_category("Unknown", "Magic Keyboard", "Bluetooth LE") == "Keyboard"
    assert resolved_category("Unknown", "AirPods", "Bluetooth") is None
    assert resolved_category("", "Magic Mouse", "Internal") is None
    assert resolved_category("", "Some Watch", "Bluetooth") is None
    assert percent(70, 100) == 70
    assert percent(50, 0) == 50
    assert percent(50, 200) == 25
    assert percent(150, 0) is None
    assert percent(-1, 100) is None
    assert device_type("Mouse") == "MMouse"
    assert device_type("Keyboard") == "Keyboard"
    assert device_type("Trackpad") == "Trackpad"
    print("accessory rule checks ok")


if __name__ == "__main__":
    main()
