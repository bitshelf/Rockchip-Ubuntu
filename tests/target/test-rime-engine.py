#!/usr/bin/env python3
"""Headless librime deployment/conversion proof; does not certify a desktop IME."""
import ctypes as C
import ctypes.util
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess

if os.geteuid() == 0:
    raise SystemExit("run as an unprivileged user")
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
work = Path(os.environ.get("QA_ARTIFACT_DIR", str(Path.home()/".local/share/ubuntu-hardware-qa"))) / ("rime-"+stamp)
seed = Path(os.environ.get("RIME_QA_SEED", "/etc/skel/.local/share/fcitx5/rime"))
shutil.copytree(seed, work/"user")
versions = subprocess.check_output(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${db:Status-Status}\n", "fcitx5", "fcitx5-rime", "librime-bin", "librime-plugin-lua"], text=True)
assert all(line.endswith("\tinstalled") for line in versions.splitlines()), versions
(work/"packages.txt").write_text(versions)
provenance = Path("/usr/share/doc/rime-ice/SOURCE")
if provenance.is_file():
    shutil.copyfile(provenance, work/"SOURCE")
with (work/"deploy.log").open("w") as log:
    subprocess.run(["rime_deployer", "--build", str(work/"user"), "/usr/share/rime-data", str(work/"user/build")], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
assert (work/"user/build/rime_ice.schema.yaml").is_file(), "Rime Ice schema did not deploy"

# Versioned C ABI from librime's public rime_api.h. Keep the complete prefix
# through select_schema and check data_size before calling any function.
class Traits(C.Structure):
    _fields_ = [("data_size", C.c_int)] + [(n, C.c_char_p) for n in (
        "shared_data_dir", "user_data_dir", "distribution_name",
        "distribution_code_name", "distribution_version", "app_name")] + [
        ("modules", C.POINTER(C.c_char_p)), ("min_log_level", C.c_int),
        ("log_dir", C.c_char_p), ("prebuilt_data_dir", C.c_char_p), ("staging_dir", C.c_char_p)]

class Commit(C.Structure):
    _fields_ = [("data_size", C.c_int), ("text", C.c_char_p)]

names = "setup set_notification_handler initialize finalize start_maintenance is_maintenance_mode join_maintenance_thread deployer_initialize prebuild deploy deploy_schema deploy_config_file sync_user_data create_session find_session destroy_session cleanup_stale_sessions cleanup_all_sessions process_key commit_composition clear_composition get_commit free_commit get_context free_context get_status free_status set_option get_option set_property get_property get_schema_list free_schema_list get_current_schema select_schema".split()
class API(C.Structure):
    _fields_ = [("data_size", C.c_int)] + [(n, C.c_void_p) for n in names]

library = C.CDLL(ctypes.util.find_library("rime") or "librime.so.1", mode=C.RTLD_GLOBAL)
library.rime_get_api.restype = C.POINTER(API)
api = library.rime_get_api().contents
assert api.data_size+C.sizeof(C.c_int) >= C.sizeof(API), "unsupported librime C API"
def call(name, result, arguments, *values):
    return C.CFUNCTYPE(result, *arguments)(getattr(api, name))(*values)
traits = Traits()
traits.data_size = C.sizeof(Traits)-C.sizeof(C.c_int)
traits.shared_data_dir = b"/usr/share/rime-data"
traits.user_data_dir = os.fsencode(work/"user")
traits.app_name = b"rime.ubuntu_hardware_qa"
traits.log_dir = os.fsencode(work)
call("setup", None, [C.POINTER(Traits)], C.byref(traits))
call("initialize", None, [C.POINTER(Traits)], C.byref(traits))
session = call("create_session", C.c_size_t, [])
assert session, "Rime session creation failed"
try:
    assert call("select_schema", C.c_int, [C.c_size_t, C.c_char_p], session, b"rime_ice"), "Rime Ice selection failed"
    call("set_option", None, [C.c_size_t, C.c_char_p, C.c_int], session, b"ascii_mode", 0)
    for key in "nihao ":
        call("process_key", C.c_int, [C.c_size_t, C.c_int, C.c_int], session, ord(key), 0)
    commit = Commit(C.sizeof(Commit)-C.sizeof(C.c_int), None)
    assert call("get_commit", C.c_int, [C.c_size_t, C.POINTER(Commit)], session, C.byref(commit)), "no committed text"
    text = commit.text.decode()
    call("free_commit", C.c_int, [C.POINTER(Commit)], C.byref(commit))
    (work/"result.json").write_text(json.dumps({"mode":"headless-librime", "input":"nihao ", "commit":text, "desktop_input_tested":False}, ensure_ascii=False, indent=2)+"\n")
    assert text == "你好", f"unexpected conversion: {text!r}"
    print("RIME_ICE_ENGINE_OK commit=你好 evidence="+str(work))
finally:
    call("destroy_session", C.c_int, [C.c_size_t], session)
    call("finalize", None, [])
