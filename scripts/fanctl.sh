set -euo pipefail

usage() {
  echo 'Usage: sudo fanctl {board|poe} {0..100|auto}'
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  board) device="pwm-fan"; service="rock3b-fan-controller.service" ;;
  poe) device="radxa-poe-fan"; service="rock3b-poe-fan-controller.service" ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$2" == auto ]]; then
  systemctl start "$service"
  echo "$1: automatic temperature control"
  exit 0
fi

if [[ ! "$2" =~ ^(100|[1-9]?[0-9])$ ]]; then
  echo 'Fan output must be an integer from 0 to 100, or auto' >&2
  exit 2
fi

pwm_paths=(/sys/devices/platform/"$device"/hwmon/hwmon*/pwm1)
if [[ ${#pwm_paths[@]} -ne 1 || ! -w "${pwm_paths[0]}" ]]; then
  echo "No writable PWM found for $1; run with sudo and check the fan device" >&2
  exit 1
fi

# Wait for the controller's exit handler to finish before setting manual PWM.
systemctl stop "$service"
percent="$2"
pwm=$(( (percent * 255 + 50) / 100 ))
printf '%s\n' "$pwm" > "${pwm_paths[0]}"
echo "$1: $percent% (PWM $pwm/255)"
