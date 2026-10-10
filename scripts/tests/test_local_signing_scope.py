import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local_signing_scope", Path(__file__).parents[1] / "with-local-signing.py")
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class LocalSigningScopeTests(unittest.TestCase):
    def test_failed_build_restores_original_search_list(self):
        with patch.object(scope, "keychains", side_effect=[["login"], ["login", "dev"]]), \
             patch.object(scope, "set_keychains") as write, \
             patch.object(scope.subprocess, "call", return_value=1):
            self.assertEqual(scope.with_keychain("dev", ["build"]), 1)
            self.assertEqual([call.args[0] for call in write.call_args_list], [["login", "dev"], ["login"]])

    def test_concurrent_search_list_change_is_preserved(self):
        with patch.object(scope, "keychains", side_effect=[["login"], ["new", "login", "dev"]]), \
             patch.object(scope, "set_keychains") as write, \
             patch.object(scope.subprocess, "call", return_value=0):
            scope.with_keychain("dev", ["build"])
            self.assertEqual(write.call_args.args[0], ["new", "login"])

    def test_preexisting_keychain_is_not_removed(self):
        with patch.object(scope, "keychains", return_value=["login", "dev"]), \
             patch.object(scope, "set_keychains") as write, \
             patch.object(scope.subprocess, "call", return_value=0):
            scope.with_keychain("dev", ["build"])
            write.assert_not_called()

    def test_spawn_failure_restores_search_list(self):
        with patch.object(scope, "keychains", side_effect=[["login"], ["login", "dev"]]), \
             patch.object(scope, "set_keychains") as write, \
             patch.object(scope.subprocess, "call", side_effect=OSError("cannot start")):
            with self.assertRaises(OSError):
                scope.with_keychain("dev", ["build"])
            self.assertEqual(write.call_args.args[0], ["login"])


if __name__ == "__main__":
    unittest.main()
