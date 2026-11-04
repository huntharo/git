"""Exercise the packaged config chain without modifying host/user config."""
import os
from pathlib import Path
import subprocess
import tempfile


def verify_configuration(git, config, environment):
    git, config = Path(git).resolve(), Path(config).resolve()
    env = {k: v for k, v in environment.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_SYSTEM=str(config), GIT_CONFIG_GLOBAL=os.devnull)

    def command(*args, cwd=None, extra=None, missing=False):
        result = subprocess.run([str(git), *args], cwd=cwd,
                                env=dict(env, **(extra or {})),
                                capture_output=True, text=True, check=False)
        if missing:
            assert result.returncode == 1 and not result.stdout, result.stderr
            return None
        result.check_returncode()
        return result.stdout.strip()

    assert command('config', '--system', '--no-includes', '--get-all',
                   'include.path') == '/etc/gitconfig'
    command('config', '--system', '--no-includes', '--get',
            'checkout.reflink', missing=True)
    assert command('config', '--system', '--no-includes', '--bool', '--get',
                   'credential.https://dev.azure.com.useHttpPath') == 'true'

    with tempfile.TemporaryDirectory(prefix='pwrgit-config-') as tmp:
        root = Path(tmp)
        system, global_file = root / 'system config', root / 'global config'
        included, overlay = root / 'included global config', root / 'runtime config'
        system.write_text('[pwrgitRuntimeTest]\n\tsystem = visible\n\tpriority = system\n'
                          '[checkout]\n\treflink = true\n')
        included.write_text('[pwrgitRuntimeTest]\n\tglobal = visible\n\tpriority = global\n')
        global_file.touch()
        overlay.write_bytes(config.read_bytes())
        # Redirect only the fixture's include: never write the real /etc/gitconfig.
        command('config', '--file', overlay, '--replace-all', 'include.path', system)
        command('config', '--file', global_file, 'include.path', included)
        overrides = dict(GIT_CONFIG_SYSTEM=str(overlay), GIT_CONFIG_GLOBAL=str(global_file))
        repo = root / 'repository'
        command('init', '-q', repo, extra=overrides)
        command('config', 'pwrgitRuntimeTest.repository', 'visible', cwd=repo, extra=overrides)
        command('config', 'pwrgitRuntimeTest.priority', 'repository', cwd=repo, extra=overrides)
        for scope in ('system', 'global', 'repository'):
            assert command('config', '--get', 'pwrgitRuntimeTest.' + scope,
                           cwd=repo, extra=overrides) == 'visible'
        assert command('config', '--get-all', 'pwrgitRuntimeTest.priority',
                       cwd=repo, extra=overrides).splitlines() == ['system', 'global', 'repository']
        assert command('-c', 'pwrgitRuntimeTest.priority=command', 'config', '--get',
                       'pwrgitRuntimeTest.priority', cwd=repo, extra=overrides) == 'command'
        assert command('config', '--bool', '--get', 'checkout.reflink',
                       cwd=repo, extra=overrides) == 'true'
        command('config', '--file', global_file, 'checkout.reflink', 'false')
        assert command('config', '--bool', '--get', 'checkout.reflink',
                       cwd=repo, extra=overrides) == 'false'
        assert command('-c', 'checkout.reflink=true', 'config', '--bool', '--get',
                       'checkout.reflink', cwd=repo, extra=overrides) == 'true'
        command('config', '--get', 'pwrgitRuntimeTest.system', cwd=repo,
                extra=dict(overrides, GIT_CONFIG_NOSYSTEM='1'), missing=True)
        alternate = root / 'explicit system config'
        alternate.write_text('[pwrgitRuntimeTest]\n\tsystem = explicit\n')
        assert command('config', '--get', 'pwrgitRuntimeTest.system', cwd=repo,
                       extra=dict(overrides, GIT_CONFIG_SYSTEM=str(alternate))) == 'explicit'
    return dict(system_include='/etc/gitconfig', azure_use_http_path=True,
                runtime_reflink_default=False, system_global_repository_visible=True,
                includes_and_precedence=True, explicit_system_override=True,
                nosystem_honored=True)
