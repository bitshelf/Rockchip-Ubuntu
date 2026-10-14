#!/usr/bin/env python3
"""Verify Fcitx/Rime commits into a focused native Xserver GTK4 widget."""
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
    raise SystemExit("run as desktop user with QA_INPUT_INJECT=1")
if not os.environ.get("DISPLAY") or os.environ.get("GTK_IM_MODULE") != "fcitx":
    raise SystemExit("native Xserver session and GTK_IM_MODULE=fcitx are required")
if os.environ.get("GDK_BACKEND") != "x11":
    raise SystemExit("GDK_BACKEND=x11 is required")
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
work = Path(os.environ.get("QA_ARTIFACT_DIR", str(Path.home()/".local/share/ubuntu-hardware-qa"))) / ("xfce-rime-"+stamp)
work.mkdir(parents=True)
result = {"passed": False, "expected": "你好", "x11_display": os.environ["DISPLAY"]}
panel = subprocess.check_output([
    "gdbus", "call", "--session", "--dest", "org.fcitx.Fcitx5",
    "--object-path", "/controller", "--method", "org.fcitx.Fcitx.Controller1.CurrentUI",
], text=True, timeout=5).strip()
if panel != "('classicui',)":
    raise SystemExit("XFCE Fcitx5 panel is not active: " + panel)
result["input_panel"] = "classicui"
app = Gtk.Application(application_id="org.rockchip.UbuntuRimeQA")
started = time.monotonic()
injected = False
activated_at = None
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
    global injected, keyboard, activated_at
    try:
        if time.monotonic()-started > 35:
            return finish("input did not commit within 35 seconds")
        if not injected:
            if not window.is_active():
                return True
            entry.grab_focus()
            # GTK focus and Fcitx input-context registration complete asynchronously.
            # State 0 means no input context exists yet, so selecting an IM then
            # can be ignored and its later registration resets to keyboard-us.
            state = subprocess.check_output(["fcitx5-remote"], text=True, timeout=5).strip()
            if activated_at is None and state == "0":
                return True
            if activated_at is None:
                result["input_context_state_before_activation"] = state
                # Activating after the GTK input context exists avoids its
                # initial focus resetting Fcitx to the inactive keyboard state.
                subprocess.run(["fcitx5-remote", "-o"], check=True, timeout=5)
                subprocess.run(["fcitx5-remote", "-s", "rime"], check=True, timeout=5)
                activated_at = time.monotonic()
                return True
            state = subprocess.check_output(["fcitx5-remote"], text=True, timeout=5).strip()
            method = subprocess.check_output(["fcitx5-remote", "-n"], text=True, timeout=5).strip()
            if state != "2" or method != "rime":
                return True
            result["input_context_state_before_injection"] = state
            result["input_method_before_injection"] = method
            # Keep GTK's main loop running while the compositor delivers input.
            keyboard = subprocess.Popen(["xdotool", "key", "--clearmodifiers", "--delay", "150", "n", "i", "h", "a", "o", "space"])
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
    window = Gtk.ApplicationWindow(application=application, title="XFCE Rime acceptance")
    window.set_default_size(640, 240)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
    box.set_margin_top(30)
    box.set_margin_start(30)
    box.set_margin_end(30)
    box.append(Gtk.Label(label="Fcitx5 / Rime Ice: native Xserver input acceptance"))
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
print("XFCE_XSERVER_RIME_INPUT_OK commit=你好")
