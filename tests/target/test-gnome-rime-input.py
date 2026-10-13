#!/usr/bin/env python3
"""Verify Fcitx/Rime commits into a focused native Wayland GTK4 widget."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk

if os.geteuid() == 0 or os.environ.get("QA_INPUT_INJECT") != "1":
    raise SystemExit("run as desktop user with QA_INPUT_INJECT=1 and a QA ydotool socket")
if not os.environ.get("WAYLAND_DISPLAY") or os.environ.get("GTK_IM_MODULE") != "fcitx":
    raise SystemExit("native Wayland session and GTK_IM_MODULE=fcitx are required")
socket = os.environ.get("YDOTOOL_SOCKET", "")
if not socket or not Path(socket).exists():
    raise SystemExit("dedicated QA ydotool socket is required")
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
work = Path(os.environ.get("QA_ARTIFACT_DIR", str(Path.home()/".local/share/ubuntu-hardware-qa"))) / ("gnome-rime-"+stamp)
work.mkdir(parents=True)
result = {"passed": False, "expected": "你好", "wayland_display": os.environ["WAYLAND_DISPLAY"]}
panel = subprocess.check_output([
    "gdbus", "call", "--session", "--dest", "org.fcitx.Fcitx5",
    "--object-path", "/controller", "--method", "org.fcitx.Fcitx.Controller1.CurrentUI",
], text=True, timeout=5).strip()
if panel != "('kimpanel',)":
    raise SystemExit("GNOME Fcitx5 panel is not active: " + panel)
result["input_panel"] = "kimpanel"
app = Gtk.Application(application_id="org.rockchip.UbuntuRimeQA")
started = time.monotonic()
injected = False
finished = False
keyboard = None

def finish(error=None):
    global finished
    if finished:
        return False
    finished = True
    if error:
        result["error"] = str(error)
    result["elapsed_seconds"] = round(time.monotonic()-started, 3)
    (work/"result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps(result, ensure_ascii=False), flush=True)
    print("artifact="+str(work), flush=True)
    app.quit()
    return False

def poll(window, entry):
    global injected, keyboard
    try:
        if time.monotonic()-started > 35:
            return finish("input did not commit within 35 seconds")
        if not injected:
            if not window.is_active():
                return True
            entry.grab_focus()
            subprocess.run(["fcitx5-remote", "-s", "rime"], check=True, timeout=5)
            subprocess.run(["fcitx5-remote", "-o"], check=True, timeout=5)
            keys = []
            for key in (49, 23, 35, 30, 24, 57):  # n i h a o Space
                keys.extend((f"{key}:1", f"{key}:0"))
            # Keep GTK's main loop running while the compositor delivers input.
            keyboard = subprocess.Popen(["ydotool", "key", "--key-delay=150", *keys])
            injected = True
            return True
        result["committed"] = entry.get_text()
        if result["committed"] == result["expected"]:
            if keyboard.poll() is None:
                return True
            if keyboard.returncode != 0:
                return finish("keyboard injection failed")
            result["passed"] = True
            result["input_method"] = subprocess.check_output(["fcitx5-remote", "-n"], text=True, timeout=5).strip()
            if result["input_method"] != "rime":
                result["passed"] = False
                return finish("Fcitx input method is not Rime")
            return finish()
        return True
    except Exception as error:
        return finish(error)

def activate(application):
    window = Gtk.ApplicationWindow(application=application, title="Ubuntu GNOME Rime acceptance")
    window.set_default_size(640, 240)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
    box.set_margin_top(30)
    box.set_margin_start(30)
    box.set_margin_end(30)
    box.append(Gtk.Label(label="Fcitx5 / Rime Ice: native Wayland input acceptance"))
    entry = Gtk.Entry()
    box.append(entry)
    window.set_child(box)
    window.connect("close-request", lambda *_: finish("QA window closed"))
    window.present()
    entry.grab_focus()
    GLib.timeout_add(250, poll, window, entry)

app.connect("activate", activate)
try:
    app.run([])
finally:
    if keyboard is not None and keyboard.poll() is None:
        keyboard.terminate()
        keyboard.wait(timeout=5)
if not result["passed"]:
    sys.exit(1)
print("GNOME_WAYLAND_RIME_INPUT_OK commit=你好")
