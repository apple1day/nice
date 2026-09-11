import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import project_doctor as doctor


class ProjectDoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.objects = {
            "root": {"isa": "PBXProject", "mainGroup": "main", "buildConfigurationList": "projectConfigs"},
            "main": {"isa": "PBXGroup", "children": ["appGroup", "testGroup"]},
            "appGroup": {"isa": "PBXGroup", "path": "NiceVideos", "children": []},
            "testGroup": {"isa": "PBXGroup", "path": "Tests", "children": []},
            "projectConfigs": {"buildConfigurations": ["projectDebug"]},
            "projectDebug": {"name": "Debug", "buildSettings": {"DEVELOPMENT_TEAM": "LOCALTEAM"}},
        }
        for name, prefix in (("NiceVideos", "app"), ("NiceVideosTests", "test")):
            self.objects[prefix] = {"isa": "PBXNativeTarget", "name": name,
                                    "buildPhases": [prefix + "Sources"], "buildConfigurationList": prefix + "Configs"}
            self.objects[prefix + "Sources"] = {"isa": "PBXSourcesBuildPhase", "files": []}
            self.objects[prefix + "Configs"] = {"buildConfigurations": [prefix + "Debug"]}
            self.objects[prefix + "Debug"] = {"name": "Debug", "buildSettings": {}}
        self.project = {"rootObject": "root", "objects": self.objects}
        for name in ("Core.swift", "OfflineMediaPolicy.swift", "VLCPlaybackEngine.swift"):
            self.add_source(name)
        self.add_source("CoreTests.swift", "test")

    def add_source(self, name, prefix="app"):
        folder = "NiceVideos" if prefix == "app" else "Tests"
        file = self.root / folder / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("// test fixture", encoding="utf-8")
        ref = prefix + name
        self.objects[ref] = {"isa": "PBXFileReference", "path": name, "sourceTree": "<group>"}
        self.objects[prefix + "Group"]["children"].append(ref)
        self.objects[ref + "Build"] = {"fileRef": ref}
        self.objects[prefix + "Sources"]["files"].append(ref + "Build")

    def test_complete_targets_pass(self):
        self.assertEqual(doctor.source_errors(self.root, self.project), [])

    def test_stale_project_detects_both_new_files_even_with_file_references(self):
        self.objects["appSources"]["files"] = ["appCore.swiftBuild"]
        errors = doctor.source_errors(self.root, self.project)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("OfflineMediaPolicy.swift" in error for error in errors))
        self.assertTrue(any("VLCPlaybackEngine.swift" in error for error in errors))

    def test_test_target_membership_does_not_satisfy_app(self):
        key = "appVLCPlaybackEngine.swiftBuild"
        self.objects["appSources"]["files"].remove(key)
        self.objects["testSources"]["files"].append(key)
        self.assertTrue(any("未加入 NiceVideos 的" in e for e in doctor.source_errors(self.root, self.project)))

    def test_new_source_requires_regeneration(self):
        (self.root / "NiceVideos/NewFeature.swift").write_text("// added later")
        self.assertTrue(any("NewFeature.swift" in e for e in doctor.source_errors(self.root, self.project)))

    def test_missing_checkout_file_reported(self):
        (self.root / "NiceVideos/OfflineMediaPolicy.swift").unlink()
        self.assertTrue(any("源码未完整拉取" in e for e in doctor.source_errors(self.root, self.project)))

    def test_source_root_reference(self):
        self.objects["appCore.swift"].update(path="NiceVideos/Core.swift", sourceTree="SOURCE_ROOT")
        self.assertEqual(doctor.source_errors(self.root, self.project), [])

    def test_signing_retains_target_bundle_id_and_project_team(self):
        self.objects["appDebug"]["buildSettings"] = {"PRODUCT_BUNDLE_IDENTIFIER": "com.example.existing",
                                                      "MARKETING_VERSION": "old", "DEVELOPMENT_TEAM": "$(inherited)"}
        values = doctor.signing_overlay(self.project)["NiceVideos"]["settings"]["configs"]["Debug"]
        self.assertEqual(values["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.existing")
        self.assertEqual(values["DEVELOPMENT_TEAM"], "LOCALTEAM")
        self.assertNotIn("MARKETING_VERSION", values)

    def test_prepare_backups_before_generating_signing_overlay(self):
        old = self.root / doctor.PROJECT
        old.mkdir()
        (old / "project.pbxproj").write_text("original project")
        self.objects["appDebug"]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.example.existing"
        output = self.root / ".project-setup-test.json"
        with patch.object(doctor, "read_project", return_value=self.project):
            doctor.prepare(self.root, output)
        spec = json.loads(output.read_text())
        self.assertEqual(spec["include"], ["project.yml"])
        self.assertEqual(spec["targets"]["NiceVideos"]["settings"]["configs"]["Debug"]["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.existing")
        self.assertEqual(len(list((self.root / ".project-backups").glob("*/NiceVideos.xcodeproj/project.pbxproj"))), 1)
        self.assertEqual((old / "project.pbxproj").read_text(), "original project")

    def test_prepare_unreadable_project_fails_without_replacing(self):
        (self.root / doctor.PROJECT).mkdir()
        output = self.root / ".project-setup-test.json"
        with patch.object(doctor, "read_project", side_effect=ValueError("invalid")):
            with self.assertRaises(ValueError):
                doctor.prepare(self.root, output)
        self.assertFalse(output.exists())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcodegen"), "Requires macOS/XcodeGen; runs in CI")
    def test_real_xcodegen_repairs_old_sources_and_preserves_signing(self):
        # Reproduce the user's old generated project, not just JSON mocks.
        old_spec = {
            "name": "NiceVideos",
            "options": {"deploymentTarget": {"iOS": "17.0"}},
            "targets": {
                "NiceVideos": {"type": "application", "platform": "iOS",
                    "sources": ["NiceVideos/Core.swift"],
                    "settings": {"configs": {
                        "Debug": {"PRODUCT_BUNDLE_IDENTIFIER": "com.example.existing.debug", "DEVELOPMENT_TEAM": "LOCALTEAM"},
                        "Release": {"PRODUCT_BUNDLE_IDENTIFIER": "com.example.existing", "DEVELOPMENT_TEAM": "RELEASETEAM"}}}},
                "NiceVideosTests": {"type": "bundle.unit-test", "platform": "iOS", "sources": ["Tests"]}
            }
        }
        old_path = self.root / "old.json"
        old_path.write_text(json.dumps(old_spec))
        subprocess.run(["xcodegen", "generate", "--spec", str(old_path)], cwd=self.root, check=True)
        stale = doctor.read_project(self.root)
        self.assertTrue(doctor.source_errors(self.root, stale))
        before = doctor.signing_overlay(stale)
        old_spec["targets"]["NiceVideos"]["sources"] = ["NiceVideos"]
        old_spec["targets"]["NiceVideos"]["settings"] = {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.anxiong.nicevideos"}}
        (self.root / "project.yml").write_text(json.dumps(old_spec))
        output = self.root / ".project-setup-test.json"
        doctor.prepare(self.root, output)
        subprocess.run(["xcodegen", "generate", "--spec", str(output)], cwd=self.root, check=True)
        repaired = doctor.read_project(self.root)
        self.assertEqual(doctor.source_errors(self.root, repaired), [])
        self.assertEqual(doctor.signing_overlay(repaired), before)

    def test_missing_dependencies_reported(self):
        self.assertEqual(len(doctor.dependency_errors(self.root)), 3)

    def test_installed_dependencies_pass(self):
        workspace = self.root / doctor.WORKSPACE
        workspace.mkdir()
        (workspace / "contents.xcworkspacedata").write_text('<Workspace><FileRef location="group:NiceVideos.xcodeproj"/><FileRef location="group:Pods/Pods.xcodeproj"/></Workspace>')
        (self.root / "Pods/MobileVLCKit/MobileVLCKit.xcframework").mkdir(parents=True)
        for name in ("Podfile.lock", "Pods/Manifest.lock"):
            (self.root / name).write_text("MobileVLCKit: 3.7.3")
        self.assertEqual(doctor.dependency_errors(self.root), [])
        (self.root / "Pods/Manifest.lock").write_text("different")
        self.assertTrue(doctor.dependency_errors(self.root))


if __name__ == "__main__":
    unittest.main()
