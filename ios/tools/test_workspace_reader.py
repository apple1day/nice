"""Regression coverage for Homebrew pyexpat/libexpat ABI mismatch on macOS."""
import builtins
import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import project_doctor as doctor

VALID_XML = '''<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:NiceVideos.xcodeproj"></FileRef>
  <FileRef location="group:Pods/Pods.xcodeproj"></FileRef>
</Workspace>'''


class WorkspaceReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / doctor.WORKSPACE / "contents.xcworkspacedata"
        self.workspace.parent.mkdir()
        self.workspace.write_text(VALID_XML, encoding="utf-8")
        (self.root / "Pods/MobileVLCKit/MobileVLCKit.xcframework").mkdir(parents=True)
        for name in ("Podfile.lock", "Pods/Manifest.lock"):
            (self.root / name).write_text("MobileVLCKit: 3.7.3", encoding="utf-8")

    def write_workspace(self, text):
        self.workspace.write_text(text, encoding="utf-8")

    def test_complete_dependencies_still_pass(self):
        self.assertEqual(doctor.dependency_errors(self.root), [])

    def test_missing_pods_reference_still_fails(self):
        self.write_workspace('<Workspace><FileRef location="group:NiceVideos.xcodeproj"/></Workspace>')
        self.assertEqual(doctor.dependency_errors(self.root), [
            "工作区缺少工程引用：group:Pods/Pods.xcodeproj"
        ])

    def test_comment_or_text_cannot_fake_file_references(self):
        self.write_workspace('''<Workspace>
          <!-- <FileRef location="group:Pods/Pods.xcodeproj"/> -->
          <FileRef location="group:NiceVideos.xcodeproj"/>
          <Group>&lt;FileRef location="group:Pods/Pods.xcodeproj"/&gt;</Group>
        </Workspace>''')
        self.assertEqual(len(doctor.dependency_errors(self.root)), 1)

    def test_nested_refs_quoting_unicode_and_entities(self):
        self.write_workspace('''\ufeff<?xml version="1.0" encoding="UTF-8"?>
        <Workspace version='1.0'><Group name='中文 &amp; tests'>
          <FileRef location='group:NiceVideos.xcodeproj'/>
          <FileRef location='group:Pods&#47;Pods.xcodeproj'/>
        </Group></Workspace>''')
        self.assertEqual(doctor.dependency_errors(self.root), [])

    def test_malformed_xml_is_not_recovered(self):
        for text in (VALID_XML[:-12], '<Workspace><FileRef></Workspace>', ''):
            with self.subTest(text=text):
                self.write_workspace(text)
                with self.assertRaisesRegex(ValueError, "XML 解析失败"):
                    doctor.dependency_errors(self.root)

    def test_wrong_root_rejected_even_with_refs(self):
        self.write_workspace(VALID_XML.replace('Workspace', 'NotWorkspace'))
        with self.assertRaisesRegex(ValueError, "根节点"):
            doctor.dependency_errors(self.root)

    def test_dtd_entities_rejected_before_native_parser(self):
        self.write_workspace('''<!DOCTYPE Workspace [<!ENTITY x SYSTEM "file:///etc/passwd">]>
          <Workspace>&x;</Workspace>''')
        with patch.object(doctor.subprocess, "run") as native:
            with self.assertRaisesRegex(ValueError, "DTD"):
                doctor.dependency_errors(self.root)
            native.assert_not_called()

    def test_oversized_input_rejected_before_parser(self):
        self.write_workspace(' ' * (doctor.WORKSPACE_MAX_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "1 MiB"):
            doctor.dependency_errors(self.root)

    def test_bad_encoding_gets_actionable_error(self):
        self.workspace.write_bytes(b'\xff\xfe<Workspace/>')
        with self.assertRaisesRegex(ValueError, "UTF-8"):
            doctor.dependency_errors(self.root)

    def test_locks_and_framework_still_checked(self):
        (self.root / "Pods/Manifest.lock").write_text("wrong lock", encoding="utf-8")
        (self.root / "Pods/MobileVLCKit/MobileVLCKit.xcframework").rmdir()
        errors = doctor.dependency_errors(self.root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("锁文件" in error for error in errors))
        self.assertTrue(any("xcframework" in error for error in errors))

    def test_macos_uses_native_parser_even_if_all_python_xml_imports_fail(self):
        real_import = builtins.__import__

        def broken_xml(name, *args, **kwargs):
            if name == 'pyexpat' or name == '_elementtree' or name.startswith('xml'):
                raise ImportError('Symbol not found: _XML_SetAllocTrackerActivationThreshold')
            return real_import(name, *args, **kwargs)

        result = subprocess.CompletedProcess([], 0, "true|true|true\n", "")
        with patch.object(doctor.sys, "platform", "darwin"), \
             patch.object(doctor.subprocess, "run", return_value=result) as native, \
             patch("builtins.__import__", side_effect=broken_xml):
            self.assertEqual(doctor.dependency_errors(self.root), [])
        command = native.call_args.args[0]
        self.assertEqual(command[:3], ["/usr/bin/xmllint", "--nonet", "--xpath"])
        self.assertEqual(command[-1], "-")
        self.assertNotIn("--recover", command)
        self.assertNotIn("--noent", command)
        self.assertNotIn("--loaddtd", command)
        self.assertNotIn("shell", native.call_args.kwargs)
        self.assertEqual(native.call_args.kwargs["timeout"], 10)
        self.assertEqual(native.call_args.kwargs["input"], VALID_XML)

    def test_native_missing_reference_not_marked_success(self):
        result = subprocess.CompletedProcess([], 0, "true|true|false", "")
        with patch.object(doctor.sys, "platform", "darwin"), \
             patch.object(doctor.subprocess, "run", return_value=result):
            self.assertEqual(doctor.dependency_errors(self.root), [
                "工作区缺少工程引用：group:Pods/Pods.xcodeproj"
            ])

    def test_native_failure_timeout_or_missing_binary_does_not_skip_check(self):
        for error in (FileNotFoundError('xmllint'), subprocess.TimeoutExpired('xmllint', 10)):
            with self.subTest(error=error), \
                 patch.object(doctor.sys, "platform", "darwin"), \
                 patch.object(doctor.subprocess, "run", side_effect=error):
                with self.assertRaisesRegex(ValueError, "XML 检查器"):
                    doctor.dependency_errors(self.root)

    def test_native_invalid_xml_and_unexpected_output_get_clear_errors(self):
        results = (
            subprocess.CompletedProcess([], 1, "", "parser error: truncated document"),
            subprocess.CompletedProcess([], 0, "garbage", ""),
            subprocess.CompletedProcess([], 0, "false|true|true", ""),
        )
        for result in results:
            with self.subTest(result=result), \
                 patch.object(doctor.sys, "platform", "darwin"), \
                 patch.object(doctor.subprocess, "run", return_value=result):
                with self.assertRaises(ValueError):
                    doctor.dependency_errors(self.root)

    def test_cli_reports_xml_error_without_traceback(self):
        stderr = io.StringIO()
        with patch.object(sys, "argv", ["project_doctor.py", "check"]), \
             patch.object(doctor, "read_project", return_value={}), \
             patch.object(doctor, "source_errors", return_value=[]), \
             patch.object(doctor, "dependency_errors", side_effect=ValueError("工作区 XML 解析失败")), \
             contextlib.redirect_stderr(stderr):
            self.assertEqual(doctor.main(), 1)
        self.assertIn("error:", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_non_macos_broken_expat_has_clear_error(self):
        real_import = builtins.__import__

        def broken_xml(name, *args, **kwargs):
            if name.startswith('xml'):
                raise ImportError('No module named expat')
            return real_import(name, *args, **kwargs)

        with patch.object(doctor.sys, "platform", "linux"), \
             patch("builtins.__import__", side_effect=broken_xml):
            with self.assertRaisesRegex(ValueError, "Python XML 解析器不可用"):
                doctor.dependency_errors(self.root)

    def test_cold_import_and_sources_only_do_not_load_expat(self):
        # A fresh interpreter ensures import caches cannot hide an Expat dependency.
        code = '''import builtins, sys
original = builtins.__import__
def guarded(name, *args, **kwargs):
    if name == "pyexpat" or name == "_elementtree" or name.startswith("xml"):
        raise ImportError("Symbol not found: _XML_SetAllocTrackerActivationThreshold")
    return original(name, *args, **kwargs)
builtins.__import__ = guarded
import project_doctor as d
d.read_project = lambda root: {}
d.source_errors = lambda root, project: []
sys.argv = ["project_doctor.py", "check", "--sources-only"]
raise SystemExit(d.main())
'''
        result = subprocess.run([sys.executable, "-c", code], cwd=Path(doctor.__file__).parent,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native macOS xmllint; runs in CI")
    def test_real_macos_xml_parser_with_expat_disabled_in_fresh_interpreter(self):
        # Reproduce the user's ImportError while executing the REAL system binary.
        code = '''import builtins, sys
from pathlib import Path
original = builtins.__import__
def guarded(name, *args, **kwargs):
    if name == "pyexpat" or name == "_elementtree" or name.startswith("xml"):
        raise ImportError("Symbol not found: _XML_SetAllocTrackerActivationThreshold")
    return original(name, *args, **kwargs)
builtins.__import__ = guarded
import project_doctor as d
errors = d.dependency_errors(Path(sys.argv[1]))
assert errors == [], errors
print("native workspace check passed without pyexpat")
'''
        result = subprocess.run([sys.executable, "-c", code, str(self.root)],
                                cwd=Path(doctor.__file__).parent,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("without pyexpat", result.stdout)


if __name__ == "__main__":
    unittest.main()
