"""Collect license text for the actual Go packages linked into the native host."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
raw = subprocess.check_output(
    ["go", "list", "-deps", "-json", "-tags", "nativebridge", "./ios/bridge"], cwd=root, text=True
)
decoder = json.JSONDecoder()
modules = {}
while raw.strip():
    package, end = decoder.raw_decode(raw.lstrip())
    raw = raw.lstrip()[end:]
    module = package.get("Module", {})
    if module.get("Dir") and not module.get("Main"):
        modules[module["Path"]] = module

goroot = pathlib.Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
parts = ["MusicDL iOS — third-party license notices\n", "Go runtime\n", (goroot / "LICENSE").read_text()]
for name, module in sorted(modules.items()):
    directory = pathlib.Path(module["Dir"])
    licenses = sorted(p for p in directory.iterdir() if p.is_file() and
                      p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")))
    parts.append(f"\n{'=' * 72}\n{name} {module.get('Version', '')}\n")
    if not licenses:
        raise SystemExit(f"Missing license text for linked module: {name}")
    for license_file in licenses:
        parts.extend([f"\n--- {license_file.name} ---\n", license_file.read_text(encoding="utf-8", errors="replace")])
target = root / "ios/MusicDL/ThirdPartyNotices.txt"
target.write_text("\n".join(parts), encoding="utf-8")
print(f"Collected license text for {len(modules)} linked modules")
