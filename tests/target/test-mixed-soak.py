#!/usr/bin/env python3
"""Run identified-target mixed soak; never merge heartbeats from separate attempts."""
import argparse, datetime, hashlib, json, multiprocessing, os, pathlib, pwd, signal, subprocess, time


def desktop_session_environment(mode, account, user_dir, video):
    env = {'XDG_RUNTIME_DIR': f'/run/user/{account.pw_uid}',
           'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{account.pw_uid}/bus',
           'QA_ARTIFACT_DIR': str(user_dir), 'CHROMIUM_MPP_VIDEO': str(video)}
    if mode == 'desktop-xfce':
        env.update(DISPLAY=':0', XAUTHORITY=account.pw_dir+'/.Xauthority', CHROMIUM_QA_SESSION='x11')
    else:
        env['WAYLAND_DISPLAY'] = 'wayland-0'
    return env


p = argparse.ArgumentParser()
p.add_argument('--work', type=pathlib.Path, required=True)
p.add_argument('--tests', type=pathlib.Path, required=True)
p.add_argument('--serial', required=True)
p.add_argument('--mode', choices=['server', 'desktop', 'desktop-xfce'], required=True)
p.add_argument('--user')
p.add_argument('--gpu-stack', choices=['vendor', 'panfrost'], required=True)
p.add_argument('--npu-qa-mode', choices=['latency', 'functional'], default='latency')
p.add_argument('--video', type=pathlib.Path)
p.add_argument('--seconds', type=int, default=3605)
a = p.parse_args()
assert os.geteuid() == 0 and a.seconds >= 30
serial = pathlib.Path('/proc/device-tree/serial-number').read_bytes().rstrip(b'\x00').decode()
assert serial == a.serial
assert a.work.is_absolute() and (not a.work.exists())
a.work.mkdir(parents=True)
boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
kernel = hashlib.file_digest(open('/boot/Image', 'rb'), 'sha256').hexdigest()
ctx = multiprocessing.get_context('fork')
stop = ctx.Event()

def write_json(name, obj):
    out = a.work / name
    temp = out.with_name(out.name + '.' + str(os.getpid()) + '.tmp')
    temp.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
    temp.replace(out)

def worker(name, cmd, env):
    os.setsid()
    count = 0
    with (a.work / (name + '.log')).open('w') as log:
        while not stop.is_set():
            log.write(f'attempt={count + 1} monotonic={time.monotonic()}\n')
            log.flush()
            try:
                code = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150).returncode
            except Exception as e:
                log.write(str(e) + '\n')
                log.flush()
                code = 1
            if stop.is_set():
                return
            if code:
                write_json(name + '.state.json', {'completed': count, 'errors': 1, 'exit_code': code})
                return
            count += 1
            write_json(name + '.state.json', {'completed': count, 'errors': 0, 'exit_code': 0})
            stop.wait(1)

def cpu():
    os.setsid()
    payload = b'Ubuntu functional CPU soak\x00' * 65536
    while not stop.is_set():
        hashlib.sha256(payload).digest()
env = dict(os.environ, GPU_STACK=a.gpu_stack)
commands = {'gpu': (['bash', str(a.tests / 'test-gpu-headless-egl.sh')], env), 'npu': (['bash', str(a.tests / 'test-rknpu.sh')], dict(os.environ, RKNPU_QA_MODE=a.npu_qa_mode))}
if a.mode == 'server':
    commands['video'] = (['bash', str(a.tests / 'test-mpp.sh')], dict(os.environ))
else:
    assert a.user and a.video and a.video.is_file()
    account = pwd.getpwnam(a.user)
    assert account.pw_uid != 0, 'Desktop video QA must use an unprivileged account'
    user_dir = a.work / 'user'
    user_dir.mkdir()
    os.chown(user_dir, account.pw_uid, account.pw_gid)
    desktop = desktop_session_environment(a.mode, account, user_dir, a.video)
    commands['video'] = (['runuser', '-u', a.user, '--', 'env', *[f'{k}={v}' for k, v in desktop.items()], '/usr/libexec/ubuntu-chromium-mpp-qa'], dict(os.environ))
workers = {name: ctx.Process(target=worker, args=(name, *spec)) for name, spec in commands.items()}
cpus = [ctx.Process(target=cpu) for _ in range(2)]
started = time.monotonic()
ticks = []
errors = 0
unexpected = 0
success = False
try:
    for child in [*workers.values(), *cpus]:
        child.start()
    with (a.work / 'heartbeat.jsonl').open('w') as log:
        while True:
            elapsed = time.monotonic() - started
            ticks.append(elapsed)
            states = {}
            for name, child in workers.items():
                state = a.work / (name + '.state.json')
                states[name] = json.loads(state.read_text()) if state.exists() else {'completed': 0, 'errors': 0}
                if not child.is_alive() or states[name]['errors']:
                    errors += 1
            if any((not child.is_alive() for child in cpus)):
                errors += 1
            current = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            if current != boot:
                unexpected += 1
            temperatures = {d.name: (d / 'temp').read_text().strip() for d in pathlib.Path('/sys/class/thermal').glob('thermal_zone*') if (d / 'temp').exists()}
            record = {'elapsed_seconds': elapsed, 'boot_id': current, 'states': states, 'cpu_workers_alive': sum((x.is_alive() for x in cpus)), 'temperatures_millidegrees_c': temperatures}
            if a.mode != 'server':
                status = subprocess.run(['bash', str(a.tests / ('test-xfce.sh' if a.mode=='desktop-xfce' else 'test-gnome.sh'))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode
                if status:
                    errors += 1
                record['physical_desktop_check_exit_code'] = status
            log.write(json.dumps(record) + '\n')
            log.flush()
            print(json.dumps(record), flush=True)
            if errors or unexpected:
                break
            if elapsed >= a.seconds:
                success = all((v['completed'] > 0 for v in states.values()))
                break
            time.sleep(min(30, a.seconds - elapsed))
finally:
    stop.set()
    for child in [*workers.values(), *cpus]:
        if child.pid:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            child.join(timeout=5)
            if child.is_alive():
                os.killpg(child.pid, signal.SIGKILL)
                child.join(timeout=5)
    result = {'scope': 'functional' if a.npu_qa_mode == 'functional' else 'functional-and-npu-latency', 'npu_qa_mode': a.npu_qa_mode, 'loaded_rt_performance': 'not_tested', 'schema': 'ubuntu-mixed-soak-v1', 'serial': serial, 'mode': a.mode, 'boot_id': boot, 'kernel_sha256': kernel, 'status': 'passed' if success and (not errors) and (not unexpected) else 'failed', 'workloads': ['gpu', 'video', 'npu', 'cpu'], 'heartbeat_seconds': ticks, 'workload_errors': errors, 'unexpected_reboots': unexpected, 'release_duration_satisfied': bool(ticks and ticks[-1] - ticks[0] >= 3600), 'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    write_json('result.json', result)
    print(json.dumps(result), flush=True)
if result['status'] != 'passed':
    raise SystemExit(1)
