import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys

CASES = {
    'encode-small': ('encode', 64, 64, 75, 0),
    'encode-medium': ('encode', 512, 512, 75, 0),
    'encode-large': ('encode', 1920, 1080, 95, 0),
    'encode-progressive': ('encode', 1920, 1080, 90, 1),
    'decode-medium': ('decode', 512, 512, 75, 0),
    'decode-progressive': ('decode', 1920, 1080, 90, 1),
}


def run(command, scalar=False):
    env = os.environ.copy()
    for key in list(env):
        if key.upper().startswith('JSIMD_') or key.upper() == 'JPEGMEM':
            del env[key]
    if scalar:
        env['JSIMD_FORCENONE'] = '1'
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        kernel.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        if not kernel.SetProcessAffinityMask(int(process._handle), 1):
            process.kill()
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.SetPriorityClass(int(process._handle), 0x80):
            process.kill()
            raise ctypes.WinError(ctypes.get_last_error())
    out, err = process.communicate(timeout=180)
    if process.returncode or err.strip():
        raise RuntimeError(f'Benchmark failed: {command!r}\n{out}\n{err}')
    return json.loads(out)


def confidence_interval(values):
    rng = random.Random(321)
    draws = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10000))
    return [draws[250], draws[9749]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fixtures = Path(config['fixtures']).resolve()
    fixtures.mkdir(parents=True, exist_ok=True)
    kind = config['kind']
    variants = config['variants']
    if set(variants) != {'published', 'patched', 'no_getenv'}:
        raise ValueError('Expected the three requested variants')
    rounds = config.get('rounds', 9)
    if rounds < 7:
        raise ValueError('At least seven paired rounds are required')

    def command(variant, case, iterations):
        executable = str(Path(variants[variant]).resolve())
        if kind == 'native':
            operation, width, height, quality, progressive = CASES[case]
            cmd = [executable, operation, str(width), str(height), str(quality), str(progressive), str(iterations)]
            if operation == 'decode':
                cmd.append(str(fixtures / (case + '.jpg')))
            return cmd
        return [executable, '-n', '-d', 'extension_dir=' + str(Path(executable).parent / 'ext'), '-d', 'extension=gd', str(Path('tests/gd-bench.php').resolve()), case, str(fixtures), str(iterations)]

    fixture_variant = 'published'
    if kind == 'native':
        for case, (operation, width, height, quality, progressive) in CASES.items():
            if operation == 'decode':
                subprocess.run([str(Path(variants[fixture_variant]).resolve()), 'fixture', str(width), str(height), str(quality), str(progressive), '1', str(fixtures / (case + '.jpg'))], check=True)
    else:
        cmd = command(fixture_variant, 'prepare', 1)
        run(cmd)
    report = {'kind': kind, 'platform': platform.uname()._asdict(), 'rounds': rounds, 'affinity': 1 if os.name == 'nt' else None, 'priority': 'High' if os.name == 'nt' else None, 'executables': {key: {'path': value, 'sha256': hashlib.sha256(Path(value).read_bytes()).hexdigest()} for key, value in variants.items()}, 'fixtures': {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in fixtures.iterdir() if f.is_file()}, 'cases': {}, 'regressions': [], 'passed': False}
    for case in CASES:
        calibration = run(command(fixture_variant, case, 2))
        iterations = min(100000, max(2, math.ceil(0.30 / (calibration['seconds'] / 2))))
        trials = {variant: [] for variant in variants}
        for round_number in range(rounds):
            order = list(variants)
            random.Random(321 + round_number).shuffle(order)
            for variant in order:
                result = run(command(variant, case, iterations), scalar=False)
                if result['iterations'] != iterations or result['seconds'] <= 0:
                    raise RuntimeError('Invalid timing result')
                if kind == 'native':
                    expected = '3.2.0' if variant == 'published' else '3.2.1'
                    if result['version'] != expected or result['abi'] != 80:
                        raise RuntimeError('Wrong native library version/ABI')
                trials[variant].append(result)
        comparisons = {}
        for numerator, denominator in [('no_getenv', 'published'), ('no_getenv', 'patched'), ('patched', 'published')]:
            baseline = numerator + '_vs_' + denominator
            ratios = [c['seconds'] / b['seconds'] for c, b in zip(trials[numerator], trials[denominator])]
            median = statistics.median(ratios)
            interval = confidence_interval(ratios)
            regression = median > 1.05 and interval[0] > 1.03
            comparisons[baseline] = {'time_ratio': median, 'paired_bootstrap_95pct': interval, 'regression': regression, 'ratios': ratios}
            if regression and denominator == 'published':
                report['regressions'].append({'case': case, 'comparison': baseline, 'ratio': median, 'interval': interval})
        report['cases'][case] = {'iterations': iterations, 'trials': trials, 'comparisons': comparisons, 'median_seconds': {v: statistics.median(x['seconds'] for x in rows) for v, rows in trials.items()}}
        output.write_text(json.dumps(report, indent=2) + '\n')
        print(case, json.dumps(comparisons), flush=True)
    report['passed'] = not report['regressions']
    output.write_text(json.dumps(report, indent=2) + '\n')
    if report['regressions']:
        print('Repeatable performance regressions need investigation:', json.dumps(report['regressions']), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
