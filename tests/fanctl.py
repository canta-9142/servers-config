"""Run fanctl against fake sysfs and systemctl, without touching real fans."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


source = Path(sys.argv[1]).read_text()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    platform = root / "platform"
    devices = {
        "board": ("pwm-fan", "rock3b-fan-controller.service"),
        "poe": ("radxa-poe-fan", "rock3b-poe-fan-controller.service"),
    }
    paths = {}
    for target, (device, _) in devices.items():
        path = platform / device / "hwmon/hwmon7/pwm1"
        path.parent.mkdir(parents=True)
        paths[target] = path

    script = root / "fanctl.sh"
    script.write_text(source.replace("/sys/devices/platform/", str(platform) + "/"))
    log = root / "calls"
    systemctl = root / "systemctl"
    systemctl.write_text(f"#!{shutil.which('bash')}\n" + """set -euo pipefail
printf '%s %s\\n' "$1" "$2" >> "$CALL_LOG"
[[ "${FAIL_SYSTEMCTL:-0}" == 0 ]] || exit 1
# Model the automatic controller's full-speed exit handler.
if [[ "$1" == stop ]]; then
  printf '255\\n' > "$SELECTED_PWM"
fi
""")
    systemctl.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], CALL_LOG=str(log))

    def run(*args, fail_systemctl=False):
        log.write_text("")
        for path in paths.values():
            path.write_text("17\n")
        selected = args[0] if args and args[0] in paths else "board"
        return subprocess.run(
            ["bash", str(script), *args],
            env=dict(env, SELECTED_PWM=str(paths[selected]), FAIL_SYSTEMCTL=str(int(fail_systemctl))),
            capture_output=True, text=True,
        )

    for target, (_, service) in devices.items():
        other = "poe" if target == "board" else "board"
        for percent, expected in (("0", 0), ("1", 3), ("40", 102), ("50", 128), ("60", 153), ("100", 255)):
            result = run(target, percent)
            assert result.returncode == 0, result.stderr
            assert paths[target].read_text() == f"{expected}\n"
            assert paths[other].read_text() == "17\n"
            assert log.read_text() == f"stop {service}\n"

        result = run(target, "auto")
        assert result.returncode == 0, result.stderr
        assert log.read_text() == f"start {service}\n"
        assert all(path.read_text() == "17\n" for path in paths.values())

        result = run(target, "40", fail_systemctl=True)
        assert result.returncode != 0
        assert paths[target].read_text() == "17\n"

    for args in ((), ("board",), ("other", "50"), ("poe", "50", "extra"),
                 *(("board", value) for value in ("-1", "101", "01", "1.5", "", "1+2", "AUTO"))):
        result = run(*args)
        assert result.returncode == 2, (args, result.stderr)
        assert log.read_text() == ""
        assert all(path.read_text() == "17\n" for path in paths.values())

    missing = paths["poe"].parent
    missing.rename(missing.with_name("unavailable"))
    log.write_text("")
    result = subprocess.run(["bash", str(script), "poe", "60"], env=env, capture_output=True, text=True)
    assert result.returncode != 0
    assert log.read_text() == ""

print("fanctl: manual PWM, independent targets, auto, validation and failure checks passed")
