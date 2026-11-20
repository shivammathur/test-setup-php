"""Run official PHP TS archives as Apache modules in isolated Windows processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import time
import traceback
import urllib.error
import urllib.request
import zipfile

from ldap_fixture import Fixture

REPO = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(package, destination):
    source = package.get("file")
    if source:
        shutil.copyfile(REPO / source, destination)
    else:
        subprocess.run(["curl.exe", "--fail", "--location", "--retry", "3", "--max-time", "120", "--user-agent", "Mozilla/5.0", "--output", str(destination), package["url"]], check=True)
    if sha(destination) != package["sha256"]:
        raise RuntimeError(f"SHA256 mismatch: {destination.name}")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def modules(pid):
    command = f"@(Get-Process -Id {pid} -ErrorAction Stop | ForEach-Object {{ $_.Modules }} | ForEach-Object {{ [pscustomobject]@{{ name=$_.ModuleName; path=$_.FileName; file_version=$_.FileVersionInfo.FileVersion }} }}) | ConvertTo-Json -Depth 3"
    output = subprocess.check_output(["pwsh", "-NoProfile", "-Command", command], text=True)
    return json.loads(output)


def request(url, ca):
    with urllib.request.urlopen(url, timeout=12, context=ssl.create_default_context(cafile=ca)) as response:
        return json.loads(response.read())


def good(response):
    return (response.get("connect") is True and response.get("bind") is True
            and response.get("search") is True and response.get("bad_password_rejected") is True
            and (response.get("mode") != "starttls" or response.get("starttls") is True))


def run_case(root, templates, package, fixture, version, name, ssl_enabled=True, mutation="clean"):
    case = root / name
    case.mkdir()
    php = case / "php"
    apache = case / "apache"
    shutil.copytree(templates / version, php)
    shutil.copytree(templates / "apache", apache)
    httpd = apache / "bin/httpd.exe"
    old_sasl = templates / "8.4.13/libsasl.dll"
    if mutation in ("stale-php", "rollback"):
        shutil.copyfile(old_sasl, php / "libsasl.dll")
    if mutation in ("stale-apache", "preload-old", "preload-new", "rollback-preloaded", "rollback-apache"):
        shutil.copyfile(old_sasl, apache / "bin/libsasl.dll")
    if mutation in ("rollback", "rollback-preloaded", "rollback-apache"):
        shutil.copyfile(templates / "8.4.13/ext/php_ldap.dll", php / "ext/php_ldap.dll")
    web = case / "www"
    web.mkdir()
    shutil.copyfile(REPO / "scripts/probe.php", web / "index.php")
    ca = root / "ca.pem"
    (web / "fixture.json").write_text(json.dumps({"ca": str(root / "missing-ca.pem" if mutation == "missing-ca" else ca), "ports": fixture.ports}))
    (web / "ready.txt").write_text("ready")
    (php / "php.ini").write_text(f'extension_dir="{php.as_posix()}/ext"\nextension=ldap\nerror_reporting=E_ALL\ndisplay_errors=Off\nlog_errors=On\nerror_log="{case.as_posix()}/php-error.log"\n')
    port, tls_port = free_port(), free_port()
    while tls_port == port:
        tls_port = free_port()
    preloads = ""
    if mutation in ("preload-old", "rollback-preloaded"):
        preloads = f'LoadFile "{apache.as_posix()}/bin/libsasl.dll"\n'
    elif mutation == "preload-new":
        preloads = f'LoadFile "{php.as_posix()}/libsasl.dll"\n'
    ssl_config = ""
    if ssl_enabled:
        ssl_config = f'''LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
LoadModule ssl_module modules/mod_ssl.so
Listen 127.0.0.1:{tls_port}
<VirtualHost 127.0.0.1:{tls_port}>
    SSLEngine on
    SSLCertificateFile "{ca.as_posix()}"
    SSLCertificateKeyFile "{root.as_posix()}/ca-key.pem"
</VirtualHost>
'''
    config = f'''ServerRoot "{apache.as_posix()}"
Listen 127.0.0.1:{port}
ServerName localhost
PidFile "{case.as_posix()}/httpd.pid"
ErrorLog "{case.as_posix()}/apache-error.log"
LogLevel debug
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule mime_module modules/mod_mime.so
TypesConfig "{apache.as_posix()}/conf/mime.types"
{ssl_config}
{preloads}LoadModule php_module "{php.as_posix()}/php8apache2_4.dll"
PHPIniDir "{php.as_posix()}"
DocumentRoot "{web.as_posix()}"
<Directory "{web.as_posix()}">
    Require all granted
</Directory>
<FilesMatch "\\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
ThreadsPerChild 8
'''
    conf = case / "httpd.conf"
    conf.write_text(config)
    env = os.environ.copy()
    # Keep fixture PHP first on PATH, but retain Apache's own bin directory and DLLs.
    env["PATH"] = str(php) + os.pathsep + env["PATH"]
    env["PHP_INI_SCAN_DIR"] = str(case / "empty-ini")
    env["PHPRC"] = str(php)
    record = {"case": name, "php": version, "apache": package["version"], "arch": package["arch"], "distribution": package["distribution"], "ssl": ssl_enabled, "mutation": mutation, "requests": []}
    process = None
    try:
        cli = subprocess.run([str(php / "php.exe"), "-c", str(php / "php.ini"), str(web / "index.php"), "mode=ldaps"], env=env, capture_output=True, text=True, timeout=30)
        (case / "cli-stdout.json").write_text(cli.stdout)
        (case / "cli-stderr.log").write_text(cli.stderr)
        record["cli"] = json.loads(cli.stdout)
        record["cli_passed"] = good(record["cli"])
        info = subprocess.run([str(httpd), "-v"], env=env, capture_output=True, text=True)
        record["apache_version"] = info.stdout + info.stderr
        if f'Apache/{package["version"]}' not in record["apache_version"]:
            raise AssertionError(record["apache_version"])
        with (case / "stdout.log").open("w") as stdout, (case / "stderr.log").open("w") as stderr:
            process = subprocess.Popen([str(httpd), "-X", "-f", str(conf)], cwd=apache, env=env, stdout=stdout, stderr=stderr)
            for _ in range(60):
                if process.poll() is not None:
                    raise RuntimeError(f"Apache exited {process.returncode}")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/ready.txt", timeout=1) as response:
                        if response.read() == b"ready":
                            break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.25)
            else:
                raise RuntimeError("Apache readiness timeout")
            first = request(f"http://127.0.0.1:{port}/index.php?mode=ldaps", str(ca))
            record["requests"].append(first)
            loaded = modules(first["pid"])
            record["modules"] = [m for m in loaded if any(x in m["name"].lower() for x in ["sasl", "ssl", "crypto", "php", "ldap", "httpd"])]
            sasl = next(m for m in loaded if m["name"].lower() == "libsasl.dll")
            record["sasl_path"] = sasl["path"]
            record["sasl_sha256"] = sha(Path(sasl["path"]))
            record["sasl_version"] = "2.1.27" if record["sasl_sha256"] == sha(old_sasl) else "2.1.28" if record["sasl_sha256"] == sha(templates / version / "libsasl.dll") else "unknown"
            if first["php"] != version or first["sapi"] != "apache2handler" or not first["zts"] or first["architecture"] != package["arch"]:
                raise AssertionError(f"Unexpected runtime: {first}")
            expected_failure = (record["sasl_version"] == "2.1.27" and version != "8.4.13" and mutation not in ("rollback", "rollback-preloaded", "rollback-apache")) or mutation == "missing-ca"
            record["expected_context_failure"] = expected_failure
            if expected_failure:
                if first.get("connect") is not False or not any("Could not create new security context" in warning for warning in first["warnings"]):
                    raise AssertionError(f"Expected exact context failure: {first}")
            else:
                if not good(first):
                    raise AssertionError(f"LDAPS failed: {first}")
                for mode in ["ldaps", "starttls", "untrusted"]:
                    result = request(f"http://127.0.0.1:{port}/index.php?mode={mode}", str(ca))
                    record["requests"].append(result)
                    if mode == "untrusted":
                        if result.get("bind") is not False:
                            raise AssertionError(f"Untrusted certificate accepted: {result}")
                    elif not good(result):
                        raise AssertionError(f"{mode} failed: {result}")
                if ssl_enabled:
                    result = request(f"https://localhost:{tls_port}/index.php?mode=ldaps", str(ca))
                    record["requests"].append(result)
                    if not good(result):
                        raise AssertionError(f"HTTPS plus LDAPS failed: {result}")
            cli_should_fail = mutation in ("stale-php", "missing-ca")
            if record["cli_passed"] == cli_should_fail:
                raise AssertionError(f'Unexpected CLI result: {record["cli"]}')
            record["passed"] = True
    except Exception as error:
        record["passed"] = False
        record["failure"] = str(error)
        (case / "exception.log").write_text(traceback.format_exc())
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        logs = "\n".join(path.read_text(errors="replace") for path in case.glob("*.log"))
        record["sasl_mismatch_diagnostic"] = "expected 2.1.28, got 2.1.27" in logs
        (case / "result.json").write_text(json.dumps(record, indent=2))
        print(json.dumps({key: record.get(key) for key in ["case", "passed", "sasl_version", "sasl_path", "failure"]}), flush=True)
        for binary_dir in [php, apache]:
            shutil.rmtree(binary_dir, ignore_errors=True)
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    args = parser.parse_args()
    manifest = json.loads((REPO / "manifest.json").read_text())
    package = next(p for p in manifest["apache"] if p["id"] == args.id)
    root = Path(os.environ["RUNNER_TEMP"]) / "ldap-matrix"
    root.mkdir(exist_ok=True)
    templates = root / "templates"
    templates.mkdir(exist_ok=True)
    fixture = Fixture(root)
    archive = root / ("apache.exe" if package.get("format") == "inno" else "apache.zip")
    download(package, archive)
    if package.get("format") == "inno":
        unpacker_zip = root / "innounp.zip"
        download(manifest["innounp"], unpacker_zip)
        with zipfile.ZipFile(unpacker_zip) as zip_file:
            zip_file.extractall(root / "innounp")
        unpacker = next((root / "innounp").rglob("innounp.exe"))
        subprocess.run([str(unpacker), "-x", "-q", "-b", "-y", "-d" + str(templates / "apache-unpacked"), str(archive)], check=True)
    else:
        with zipfile.ZipFile(archive) as zip_file:
            zip_file.extractall(templates / "apache-unpacked")
    httpd = next((templates / "apache-unpacked").rglob("httpd.exe"))
    shutil.copytree(httpd.parent.parent, templates / "apache")
    for version in ["8.4.13", "8.4.27", "8.4.28"]:
        php = next(p for p in manifest["php"] if p["version"] == version and p["arch"] == package["arch"])
        archive = root / f"php-{version}.zip"
        download(php, archive)
        with zipfile.ZipFile(archive) as zip_file:
            zip_file.extractall(templates / version)
    shutil.copyfile(REPO / "manifest.json", root / "manifest.json")
    records = []
    for version in ["8.4.27", "8.4.28"]:
        for ssl_enabled in [False, True]:
            records.append(run_case(root, templates, package, fixture, version, f"php-{version}-ssl-{ssl_enabled}", ssl_enabled))
    if package["version"] == "2.4.71":
        records.append(run_case(root, templates, package, fixture, "8.4.13", "baseline-8.4.13"))
        for mutation in ["stale-php", "stale-apache", "preload-old", "rollback", "rollback-preloaded", "rollback-apache", "preload-new", "missing-ca"]:
            records.append(run_case(root, templates, package, fixture, "8.4.27", mutation, mutation=mutation))
    (root / "results.json").write_text(json.dumps(records, indent=2))
    summary = [f'| {r["case"]} | {"PASS" if r["passed"] else "FAIL"} | {r.get("sasl_version", "?")} | {r.get("failure", "")} |' for r in records]
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
        f.write(f'## {args.id}\n\n| Case | Result | SASL runtime | Failure |\n|---|---|---|---|\n' + "\n".join(summary) + "\n")
    if not all(r["passed"] for r in records):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
