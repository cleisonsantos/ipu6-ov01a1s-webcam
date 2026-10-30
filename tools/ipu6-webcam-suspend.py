#!/usr/bin/env python3
#
# Pausa o pipeline da camera IPU6 antes do suspend e religa no resume.
#
# O driver ipu6-isys recusa o suspend com um stream aberto:
#     isys_suspend(): if (!ida_is_empty(&isys->streams)) return -EBUSY;
# e o -EBUSY aborta o suspend do sistema inteiro. Como o servico
# ipu6-webcam.service mantem o stream aberto, escutamos o sinal
# PrepareForSleep do logind: paramos a camera antes de dormir e religamos
# depois, apenas se ela estava ativa.
#
# Para nao haver corrida, mantemos um delay-inhibitor de "sleep" enquanto
# acordados; ele e liberado somente depois que a camera fecha. Assim o
# logind espera o pipeline parar antes de suspender.
#
# Uso (servico de usuario): systemctl --user enable --now ipu6-webcam-suspend
import subprocess
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

CAMERA = "ipu6-webcam.service"
RESTART_DELAY_SECONDS = 2

was_active = False
inhibitor = None


def systemctl(*args: str) -> None:
    subprocess.run(["systemctl", "--user", *args], check=False)


def is_active() -> bool:
    result = subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", CAMERA]
    )
    return result.returncode == 0


def acquire_inhibitor() -> None:
    global inhibitor
    if inhibitor is not None:
        return
    inhibitor = subprocess.Popen(
        [
            "systemd-inhibit",
            "--what=sleep",
            "--who=ipu6-webcam",
            "--why=Pausar a camera IPU6 antes do suspend",
            "--mode=delay",
            "sleep",
            "infinity",
        ]
    )
    print("inhibitor de sleep adquirido", flush=True)


def release_inhibitor() -> None:
    global inhibitor
    if inhibitor is None:
        return
    inhibitor.terminate()
    try:
        inhibitor.wait(timeout=2)
    except subprocess.TimeoutExpired:
        inhibitor.kill()
        inhibitor.wait()
    inhibitor = None
    print("inhibitor de sleep liberado", flush=True)


def restart_camera() -> bool:
    if not is_active():
        print(f"resume: religando {CAMERA}", flush=True)
        systemctl("start", CAMERA)
    acquire_inhibitor()
    return False  # nao repetir o timeout


def on_prepare_for_sleep(conn, sender, path, iface, signal, params) -> None:
    global was_active
    sleeping = params.unpack()[0]

    if sleeping:
        was_active = is_active()
        if was_active:
            print(f"sleep: parando {CAMERA} para liberar o IPU6", flush=True)
            systemctl("stop", CAMERA)
        else:
            print("sleep: camera ja estava parada", flush=True)
        release_inhibitor()
    else:
        if was_active:
            print(
                f"resume: aguardando {RESTART_DELAY_SECONDS}s para religar",
                flush=True,
            )
            GLib.timeout_add_seconds(RESTART_DELAY_SECONDS, restart_camera)
        else:
            print("resume: camera estava parada; nao religar", flush=True)
            acquire_inhibitor()


def main() -> int:
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    if bus is None:
        print("erro: nao consegui conectar no barramento do sistema", file=sys.stderr)
        return 1

    bus.signal_subscribe(
        "org.freedesktop.login1",
        "org.freedesktop.login1.Manager",
        "PrepareForSleep",
        "/org/freedesktop/login1",
        None,
        Gio.DBusSignalFlags.NONE,
        on_prepare_for_sleep,
    )

    acquire_inhibitor()
    print("aguardando PrepareForSleep do logind...", flush=True)
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
