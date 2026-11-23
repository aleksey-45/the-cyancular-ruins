"""解压发行 ZIP 并启动其中的游戏，检查退出状态和 Godot 日志。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from build_game import GAME, PACKAGE


def check_package(archive: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cyr-package-check-") as temporary:
        work = Path(temporary)
        package = work / PACKAGE
        if sys.platform == "darwin":
            subprocess.run(["ditto", "-x", "-k", str(archive), str(work)], check=True)
            executable = package / f"{GAME}.app" / "Contents" / "MacOS" / GAME
        else:
            shutil.unpack_archive(archive, work)
            executable = package / f"{GAME}.exe"

        log_path = work / "godot.log"
        command = [str(executable), "--headless", "--quit-after", "90", "--log-file", str(log_path), "--", "--no-perf"]
        with tempfile.TemporaryFile() as output:
            try:
                result = subprocess.run(command, cwd=package, stdout=output, stderr=subprocess.STDOUT, timeout=60)
            finally:
                output.seek(0)
                console_log = output.read().decode("utf-8", errors="replace")
                engine_log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
                if console_log and console_log not in engine_log:
                    print(console_log, end="")
                print(engine_log, end="")

        if result.returncode != 0:
            raise SystemExit(f"Packaged game exited with status {result.returncode}.")
        if not (engine_log or console_log).strip():
            raise SystemExit("Packaged game produced no startup log.")
        if re.search(r"SCRIPT ERROR|Parse Error|Compile Error|ERROR:", engine_log + "\n" + console_log):
            raise SystemExit("Packaged game reported a startup error.")
        print(f"Packaged game started and exited successfully from {archive.name}.")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    check_package(parser.parse_args().archive)
