import json
import os
from pathlib import Path
import subprocess
import sys


output = Path("results")
output.mkdir(exist_ok=True)
formula = os.environ["FORMULA"]
package = os.environ["EXPECTED_PACKAGE"]
tag = os.environ["EXPECTED_TAG"]
report = {"formula": formula, "expected_package": package, "expected_tag": tag, "checks": {}}


def run(name, arguments, timeout=120):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    (output / (name + ".log")).write_text(result.stdout)
    print(result.stdout, end="", flush=True)
    report["checks"][name] = {"exit_code": result.returncode, "command": arguments}
    (output / "installation.json").write_text(json.dumps(report, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(name + " failed")
    return result.stdout.strip()


try:
    prefix = Path(run("prefix", ["brew", "--prefix", "shivammathur/php/" + formula]))
    info = json.loads(run("brew-info", ["brew", "info", "--json=v2", "shivammathur/php/" + formula]))["formulae"][0]
    installed = [i for i in info["installed"] if i["version"] == package]
    assert len(installed) == 1 and installed[0]["poured_from_bottle"], installed
    receipt = json.loads((prefix / "INSTALL_RECEIPT.json").read_text())
    assert receipt["source"]["tap"] == "shivammathur/php", receipt["source"]
    assert receipt["poured_from_bottle"] is True
    assert prefix.resolve().name == package, str(prefix.resolve())
    actual_tag = run("bottle-tag", ["brew", "ruby", "-e", 'require "utils/bottles"; puts Utils::Bottles.tag'])
    assert actual_tag == tag, (actual_tag, tag)
    report["receipt"] = receipt
    report["resolved_prefix"] = str(prefix.resolve())
    php = str(prefix / "bin/php")
    debug = int(os.environ["EXPECTED_DEBUG"] == "true")
    zts = int(os.environ["EXPECTED_PHPTS"] == "ts")
    code = (
        'if (PHP_VERSION !== "5.6.40" || (int)PHP_DEBUG !== ' + str(debug) +
        ' || (int)PHP_ZTS !== ' + str(zts) + ') { fwrite(STDERR, "wrong build"); exit(1); } '
        '$ldap = ldap_connect(); if (!is_resource($ldap)) { exit(2); } '
        'foreach (array("ldap", "openssl", "curl", "mbstring", "mysqli", "pdo_mysql", "xml", "zip") as $module) '
        '{ if (!extension_loaded($module)) { fwrite(STDERR, $module); exit(3); } } '
        'echo json_encode(array("version"=>PHP_VERSION,"debug"=>PHP_DEBUG,"zts"=>PHP_ZTS,"ldap"=>get_resource_type($ldap))), PHP_EOL;'
    )
    run("runtime-clean", [php, "-n", "-r", code])
    run("runtime-default", [php, "-r", code])
    run("modules", [php, "-m"])
    run("cgi", [str(prefix / "bin/php-cgi"), "-n", "-v"])
    run("fpm", [str(prefix / "sbin/php-fpm"), "-n", "-t"])
    run("linkage", ["brew", "linkage", "--test", "shivammathur/php/" + formula])
    report["result"] = "passed"
except Exception as error:
    report["result"] = "failed"
    report["error"] = str(error)
    raise
finally:
    (output / "installation.json").write_text(json.dumps(report, indent=2) + "\n")
