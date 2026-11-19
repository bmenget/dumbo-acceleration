#!/usr/bin/env bash
# Load the EDA tools for this project (NCSU machines). Source it, don't run it:
#     source scripts/setup_env.sh          # Questa
#     source scripts/setup_env.sh vivado   # Questa + Vivado
# Override versions with QUESTA_MODULE / VIVADO_MODULE.

QUESTA_MODULE=${QUESTA_MODULE:-questa/2026.1}
VIVADO_MODULE=${VIVADO_MODULE:-xilinx/2026.1}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: source this script (source scripts/setup_env.sh); running it has no effect" >&2
  exit 1
fi

# Non-login shells (e.g. VS Code tasks) may not define `module`.
if ! type module >/dev/null 2>&1; then
  for f in /etc/profile.d/modules.sh /usr/share/Modules/init/bash /etc/profile.d/lmod.sh; do
    [ -r "$f" ] && . "$f" && break
  done
fi
if ! type module >/dev/null 2>&1; then
  echo "error: 'module' command not found; are you on an NCSU machine?" >&2
  return 1
fi

module load "$QUESTA_MODULE" || return 1
[ "$1" = "vivado" ] && { module load "$VIVADO_MODULE" || return 1; }

command -v vsim >/dev/null && echo "questa: $(command -v vsim)"
[ "$1" = "vivado" ] && command -v vivado >/dev/null && echo "vivado: $(command -v vivado)"
return 0
