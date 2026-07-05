"""RED-phase tests for scripts.canary.run.generate_scratch_config.

Contract (to be implemented in run.py):
    generate_scratch_config(
        base_config_dict: dict,
        scratch_home: str,
        scratch_ws: str,
    ) -> tuple[dict, str]
        Returns (scratch_config_dict, config_path_written).
        Writes config only under scratch_home; never touches ~/.nullclaw.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from scripts.canary import run

# Built-in providers known to be non-streaming per design spec correction #7.
KNOWN_NON_STREAMING_BUILTINS = frozenset({"glm", "zai"})


def _sample_base_config() -> dict:
    """Minimal realistic base config shape for scratch derivation."""
    return {
        "memory": {
            "backend": "redis",
            "response_cache": {"enabled": True},
        },
        "models": {
            "default_provider": "openai",
            "providers": {
                "openai": {
                    "api_mode": "chat",
                    "models": ["gpt-4o"],
                },
                "glm": {
                    "api_mode": "chat",
                    "models": ["glm-4"],
                },
            },
        },
    }


def _provider_is_non_streaming(provider_cfg: dict, provider_name: str) -> bool:
    """Harness contract: route is non-streaming if api_mode is responses or builtin."""
    if provider_cfg.get("api_mode") == "responses":
        return True
    return provider_name in KNOWN_NON_STREAMING_BUILTINS


class TestGenerateScratchConfig(unittest.TestCase):
    """Scratch config generation forces sqlite, cache off, non-streaming route."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="nullclaw-canary-cfg-")
        self.scratch_home = os.path.join(self.tmp.name, "home")
        self.scratch_ws = os.path.join(self.tmp.name, "workspace")
        os.makedirs(self.scratch_home, exist_ok=True)
        os.makedirs(self.scratch_ws, exist_ok=True)
        self.base_config = _sample_base_config()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_scratch_config_forces_sqlite(self) -> None:
        """generate_scratch_config must override memory.backend to sqlite."""
        config_dict, _config_path = run.generate_scratch_config(
            self.base_config,
            self.scratch_home,
            self.scratch_ws,
        )
        self.assertEqual(config_dict["memory"]["backend"], "sqlite")

    def test_scratch_config_disables_response_cache(self) -> None:
        """generate_scratch_config must disable response cache for fair baseline."""
        config_dict, _config_path = run.generate_scratch_config(
            self.base_config,
            self.scratch_home,
            self.scratch_ws,
        )
        self.assertFalse(config_dict["memory"]["response_cache"]["enabled"])

    def test_scratch_config_selects_non_streaming_route(self) -> None:
        """Harness must pick/force a non-streaming provider route from base config."""
        config_dict, _config_path = run.generate_scratch_config(
            self.base_config,
            self.scratch_home,
            self.scratch_ws,
        )

        # Contract: returned config exposes which provider/model the harness selected.
        selected_provider = config_dict.get("canary_selected_provider")
        self.assertIsNotNone(
            selected_provider,
            "scratch config must record canary_selected_provider for audit",
        )

        providers = config_dict["models"]["providers"]
        self.assertIn(selected_provider, providers)
        provider_cfg = providers[selected_provider]

        self.assertTrue(
            _provider_is_non_streaming(provider_cfg, selected_provider),
            f"selected provider {selected_provider!r} must be non-streaming "
            f"(api_mode=='responses' or builtin in {KNOWN_NON_STREAMING_BUILTINS})",
        )

    def test_scratch_config_does_not_touch_real_home(self) -> None:
        """All writes stay under scratch_home; config path never under ~/.nullclaw."""
        real_home = os.path.expanduser("~/.nullclaw")

        _config_dict, config_path = run.generate_scratch_config(
            self.base_config,
            self.scratch_home,
            self.scratch_ws,
        )

        scratch_home_real = os.path.realpath(self.scratch_home)
        config_path_real = os.path.realpath(config_path)

        self.assertTrue(
            config_path_real.startswith(scratch_home_real + os.sep)
            or config_path_real == scratch_home_real,
            f"config_path {config_path!r} must live under scratch_home {self.scratch_home!r}",
        )
        self.assertFalse(
            config_path_real.startswith(os.path.realpath(real_home)),
            f"config_path must not be under real home {real_home!r}",
        )

        # Every file created under scratch_home only.
        for dirpath, _dirnames, filenames in os.walk(self.scratch_home):
            for filename in filenames:
                full = os.path.realpath(os.path.join(dirpath, filename))
                self.assertTrue(
                    full.startswith(scratch_home_real),
                    f"unexpected file outside scratch_home: {full}",
                )


if __name__ == "__main__":
    unittest.main()