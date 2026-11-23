"""Run the bundled bridge using an explicit Godot executable and an isolated project."""

from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

from document import MapDocument
from objects import DocumentError, MapObject
from region_design import RegionDesign
from source_region import GodotSource, NodeBinding, relative_path
from strings import tr

if not getattr(sys, "frozen", False):
    # The shared Windows Job Object helper also serves the traversal worker.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from traversal_process import ProcessScope

PROTOCOL = 1
VERSION = "4.7.2.stable.official.ed1daf0bf"
RESULT_VERSION = "4.7.2-stable (official)"
MAX_RESULT = 128 * 1024 * 1024
ENGINE_ERROR = re.compile(r"(?m)^(?:SCRIPT ERROR:|ERROR:)|CowData was modified during destruction|ObjectDB instances leaked|resources still in use at exit")
SKIP_DIRECTORIES = {"build", "docs", "validation", "venv", "__pycache__", "node_modules"}
SKIP_ROOT_FILES = {"export_presets.cfg", "AGENTS.md"}


class BridgeError(DocumentError):
    def __init__(self, code, message, evidence=None):
        super().__init__(f"{code} · {message}")
        self.code = code
        self.evidence = evidence


def check_cancelled(cancel):
    if cancel.is_set():
        raise BridgeError("CANCELLED", "Godot 작업이 취소되었습니다.")


def file_hash(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISREG(info.st_mode) and not (getattr(info, "st_file_attributes", 0)
                                               & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def safe_child(root, relative, suffix):
    name = relative_path(relative, suffix)
    path = root / name
    if any(parent.is_symlink() or parent.is_junction() for parent in path.parents if parent != root):
        raise BridgeError("INVALID_PROJECT", f"linked project path: {name}")
    if not path.resolve().is_relative_to(root) or not regular(path):
        raise BridgeError("RESOURCE_MISSING", f"not a regular project file: {name}")
    return path


def excluded(relative):
    return (any(part.startswith(".") or part in SKIP_DIRECTORIES for part in relative.parts)
            or relative.as_posix() in SKIP_ROOT_FILES
            or relative.parts[:2] in (("tools", "python_map_editor"), ("tools", "map_bridge")))


def project_manifest(project, cancel, copy_to=None):
    """Fingerprint the whole eligible res:// tree, including new or deleted files."""
    manifest = {}
    for directory, dirs, files in os.walk(project, onerror=_raise_walk_error):
        check_cancelled(cancel)
        base = Path(directory)
        for name in dirs[:]:
            path = base / name
            relative = path.relative_to(project)
            if excluded(relative):
                dirs.remove(name)
            elif path.is_symlink() or path.is_junction():
                raise BridgeError("INVALID_PROJECT", f"linked project directory: {relative}")
        for name in files:
            check_cancelled(cancel)
            path = base / name
            relative = path.relative_to(project)
            if excluded(relative):
                continue
            if not regular(path):
                raise BridgeError("INVALID_PROJECT", f"linked or irregular project file: {relative}")
            if copy_to is None:
                manifest[relative.as_posix()] = file_hash(path)
                continue
            target = copy_to / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            manifest[relative.as_posix()] = file_hash(target)
    return manifest


def _raise_walk_error(error):
    raise error


def fingerprint(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False), encoding="utf-8")


def read_json(path):
    with path.open("rb") as stream:
        payload = stream.read(MAX_RESULT + 1)
    if len(payload) > MAX_RESULT:
        raise BridgeError("INVALID_RESPONSE", f"JSON exceeds size limit: {path.name}")
    try:
        return json.loads(payload.decode("utf-8"), parse_constant=_bad_json_constant, object_pairs_hook=_unique_fields)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise BridgeError("INVALID_RESPONSE", f"invalid JSON: {path.name}") from error


def _bad_json_constant(value):
    raise ValueError(value)


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field {key}")
        result[key] = value
    return result


@dataclass(frozen=True, slots=True)
class ProjectSettings:
    project: Path
    godot: Path
    work: Path

    def checked(self):
        try:
            project = self.project.resolve(strict=True)
        except OSError as error:
            raise BridgeError("INVALID_PROJECT", str(error)) from error
        for name in ("project.godot", "autoload/content_registry.gd", "data/definitions/region_definition.gd"):
            if not regular(project / name):
                raise BridgeError("INVALID_PROJECT", f"missing ReturnToCage project file: {name}")
            safe_child(project, name, Path(name).suffix)
        try:
            godot = self.godot.resolve(strict=True)
        except OSError as error:
            raise BridgeError("INVALID_GODOT_PATH", str(error)) from error
        if not regular(godot):
            raise BridgeError("INVALID_GODOT_PATH", str(godot))
        # The official console launcher can create another process before the
        # job takes ownership. Use its corresponding engine binary directly.
        if os.name == "nt" and godot.name.lower().endswith("_console.exe"):
            companion = godot.with_name(godot.name[:-12] + ".exe")
            if not regular(companion):
                raise BridgeError("INVALID_GODOT_PATH", f"Godot engine binary missing: {companion}")
            godot = companion
        work = self.work.resolve()
        if work.is_relative_to(project):
            raise BridgeError("INVALID_PROJECT", "작업 폴더를 프로젝트 외부에 지정하세요.")
        work.mkdir(parents=True, exist_ok=True)
        return ProjectSettings(project, godot, work)


@contextmanager
def staged_import_settings(project):
    # The editor itself may rewrite project.godot when it loads plugins. These
    # files belong to the disposable copy and their original bytes are restored
    # before any runtime validation, fingerprint, or Export As can consume them.
    setting = b'\n[editor_plugins]\nenabled=PackedStringArray("res://tools/map_bridge/import_guard/plugin.cfg")\n'
    paths = [project / "project.godot", project / "override.cfg"]
    originals = {path: path.read_bytes() for path in paths if path.exists()}
    try:
        for path, content in originals.items():
            path.write_bytes(content + setting)
        yield
    finally:
        for path, content in originals.items():
            path.write_bytes(content)


def run_child(command, cwd, env, evidence, label, cancel, timeout):
    check_cancelled(cancel)
    logs = [evidence / f"{label}.{stream}.log" for stream in ("stdout", "stderr")]
    scope = ProcessScope()
    process = None
    remaining = None
    started = datetime.now(timezone.utc).isoformat()
    kwargs = ({"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt"
              else {"start_new_session": True})
    try:
        with logs[0].open("wb") as stdout, logs[1].open("wb") as stderr:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, **kwargs)
            try:
                scope.attach(process)
            except OSError as error:
                # The official GUI binary may finish --version before Windows
                # can assign it. An active or non-version child must be owned.
                if label != "version" or getattr(error, "winerror", None) != 5:
                    raise
                try:
                    process.wait(timeout=0.1)
                except subprocess.TimeoutExpired:
                    raise error from None
            write_json(evidence / f"{label}.process.json", {"argv": command, "pid": process.pid, "cwd": str(cwd),
                                                           "started_utc": started})
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if cancel.wait(min(0.05, max(0, deadline - time.monotonic()))):
                    raise BridgeError("CANCELLED", label)
                if time.monotonic() >= deadline:
                    raise BridgeError("TIMEOUT", label)
            remaining = scope.active_processes()
            if remaining:
                raise BridgeError("PROCESS_CRASH", f"{label}: {remaining} owned processes left running")
        return process.returncode, "\n".join(log.read_text(encoding="utf-8", errors="replace") for log in logs)
    finally:
        if process is not None:
            if os.name != "nt":
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            elif process.poll() is None:
                process.kill()
        scope.close()
        if process is not None:
            process.wait(timeout=10)
            write_json(evidence / f"{label}.exit.json", {
                "exit_code": process.returncode, "pid": process.pid,
                "started_utc": started, "exited_utc": datetime.now(timezone.utc).isoformat(),
                "job_active_at_exit": remaining})


def response(path, operation, request_id, exit_code, output):
    if exit_code < 0 or exit_code > 255:
        raise BridgeError("PROCESS_CRASH", f"{operation}: {exit_code} (0x{exit_code & 0xffffffff:08X})")
    if not regular(path):
        raise BridgeError("INVALID_RESPONSE", f"{operation}: result missing (exit {exit_code})")
    result = read_json(path)
    if (not isinstance(result, dict) or type(result.get("protocol")) is not int or result["protocol"] != PROTOCOL
            or result.get("request_id") != request_id or result.get("operation") != operation
            or result.get("godot_version") != RESULT_VERSION or not isinstance(result.get("warnings"), list)):
        raise BridgeError("INVALID_RESPONSE", f"{operation}: result identity/version mismatch")
    if exit_code != 0 or result.get("status") != "PASS":
        code = result.get("error_code") or "EXPORT_FAILED"
        message = result.get("message") or f"{operation}: exit {exit_code}"
        raise BridgeError(code, message.removeprefix(code + ": "))
    if not isinstance(result.get("data"), dict) or ENGINE_ERROR.search(output):
        raise BridgeError("PROCESS_CRASH", f"{operation}: Godot logged errors or leaked resources")
    return result


class GodotSession:
    def __init__(self, settings, cancel, progress=lambda _message: None):
        self.settings = settings.checked()
        self.cancel = cancel
        self.progress = progress
        self.evidence = Path(tempfile.mkdtemp(prefix="rtc-map-", dir=self.settings.work))
        self.version = None
        self.stage = None
        self.manifest = None
        self.env = os.environ.copy()

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="snapshot-", dir=self.evidence)
        try:
            local = Path(self.temp.name)
            for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "HOME"):
                folder = local / key
                folder.mkdir()
                self.env[key] = str(folder)
            code, output = run_child([str(self.settings.godot), "--version"], local, self.env,
                                     self.evidence, "version", self.cancel, 15)
            versions = [line.strip() for line in output.splitlines() if line.strip()]
            if code != 0 or versions != [VERSION]:
                raise BridgeError("GODOT_VERSION_MISMATCH", f"expected {VERSION}; seen {versions}, exit {code}")
            self.version = versions[0]
            self.progress("Godot 4.7.2 · 프로젝트 스냅샷 생성")
            self.stage = local / "project"
            self.stage.mkdir()
            self.manifest = project_manifest(self.settings.project, self.cancel, self.stage)
            self.assert_source_unchanged()
            source = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1])) / "map_bridge"
            shutil.copytree(source, self.stage / "tools/map_bridge", ignore=shutil.ignore_patterns("__pycache__", ".git"))
            self.progress("Godot 리소스 읽기")
            self._prepare_resources()
            return self
        except BaseException:
            self.temp.cleanup()
            raise

    def _prepare_resources(self, label="prepare"):
        if os.name != "nt":
            self._run(label, ["--editor", "--recovery-mode", "--import"], timeout=180)
            return
        with staged_import_settings(self.stage):
            _, logs = self._run(label, ["--editor", "--import", "--scene",
                                            "res://tools/map_bridge/import_only.tscn"], timeout=180)
        if "RTC_BRIDGE EDITOR_IMPORT_CLEANUP" not in logs:
            raise BridgeError("INVALID_RESPONSE", "Isolated Godot import did not run the shutdown guard")

    def __exit__(self, *_):
        self.temp.cleanup()

    def _run(self, name, arguments, timeout=60, allow_response=False):
        log = self.evidence / f"{name}.godot.log"
        command = [str(self.settings.godot), "--headless", "--path", str(self.stage),
                   "--log-file", str(log), *arguments]
        code, output = run_child(command, self.stage, self.env, self.evidence, name, self.cancel, timeout)
        if log.is_file():
            output += "\n" + log.read_text(encoding="utf-8", errors="replace")
        if not allow_response and (code != 0 or ENGINE_ERROR.search(output)):
            raise BridgeError("PROCESS_CRASH", f"{name}: exit {code} (0x{code & 0xffffffff:08X}); see Godot logs")
        return code, output

    def call(self, operation, **arguments):
        self.progress(operation)
        request_id = uuid4().hex
        request = self.evidence / f"{operation}-{request_id}.request.json"
        reply = self.evidence / f"{operation}-{request_id}.result.json"
        write_json(request, {"protocol": PROTOCOL, "request_id": request_id, "operation": operation,
                             "result": str(reply), **arguments})
        label = f"{operation}-{request_id}"
        code, output = self._run(label, ["--scene", "res://tools/map_bridge/bridge.tscn", "--",
                                        "--request", str(request)], allow_response=True)
        return response(reply, operation, request_id, code, output)["data"]

    def assert_source_unchanged(self):
        check_cancelled(self.cancel)
        if project_manifest(self.settings.project, self.cancel) != self.manifest:
            raise BridgeError("SOURCE_MODIFIED", "프로젝트 원본 또는 리소스가 작업 중 변경되었습니다.")

    def import_region(self, definition, *, design=False):
        relative_path(definition, ".tres")
        data = self.call("import_v4_region" if design else "import_region", region_path="res://" + definition)
        self.assert_source_unchanged()
        source = self._source(data, self.manifest)
        document = MapDocument(data["region_id"], data["display_name"], *data["extent"],
                               objects=tuple(MapObject.from_data(item) for item in data["objects"]), source=source,
                               design=RegionDesign.from_data(data["design"]) if design else None)
        return document, data

    def _source(self, data, manifest):
        region = data["region_path"]
        scene = data["scene_path"]
        if manifest.get(region) != data["region_hash"] or manifest.get(scene) != data["scene_hash"]:
            raise BridgeError("SOURCE_MODIFIED", "Scene/RegionDefinition fingerprint mismatch")
        bindings = tuple(NodeBinding(
            key, binding["path"], binding["parent"], binding["local_transform"], binding["world_transform"],
            binding["collision"].get("layer"), binding["collision"].get("mask"),
        ) for key, binding in sorted(data["bindings"].items()))
        return GodotSource(manifest["project.godot"], fingerprint(manifest), scene, region, data["scene_hash"],
                           data["region_hash"], data["scene_uid"], data["region_uid"], bindings)

    def stage_export(self, document):
        if document.design is not None:
            raise BridgeError("UNSUPPORTED_NODE", "Region design requires a supported Scene/Resource conversion.")
        source = document.source
        if source is None:
            raise BridgeError("INVALID_DOCUMENT", "원본 지역에 연결된 V3 문서를 먼저 여세요.")
        if self.manifest.get("project.godot") != source.project_id or fingerprint(self.manifest) != source.fingerprint:
            raise BridgeError("SOURCE_MODIFIED", f"프로젝트 또는 리소스가 Import 이후 변경되었습니다. {source.scene_path}")
        region_path = "res://" + source.region_path
        expected = self.call("export_region", region_path=region_path, region_id=document.region_id,
                             display_name=document.display_name, objects=[asdict(item) for item in document.objects],
                             source={key: getattr(source, key) for key in ("scene_hash", "region_hash", "scene_path",
                                                                          "scene_uid", "region_uid")},
                             bindings={item.id: item.as_bridge_data() for item in source.bindings})
        if expected["source_hash"] != source.scene_hash or expected["scene_path"] != source.scene_path:
            raise BridgeError("INVALID_RESPONSE", "Bridge staged an unexpected scene")
        output = safe_child(self.stage, source.scene_path, ".tscn")
        if file_hash(output) != expected["output_hash"]:
            raise BridgeError("SOURCE_MODIFIED", "staged output hash mismatch")
        verified = self.call("validate_export", region_path=region_path, expected=expected)
        _verify_objects(document.objects, verified["objects"], verified["bindings"])
        self.progress(tr("runtime_running"))
        _, logs = self._run("runtime", ["--scene", "res://tools/map_bridge/runtime_validation.tscn",
                                       "--", "--region", document.region_id], timeout=60)
        runtime = {line.removeprefix("REGION_PLAYTEST_JSON ") for line in logs.splitlines()
                   if line.startswith("REGION_PLAYTEST_JSON ")}
        if ("AUTHORED FIELD RUNTIME PASS" not in logs or len(runtime) != 1
                or json.loads(next(iter(runtime))).get("overall") not in ("PASS", "PASS_WITH_WARNINGS")):
            raise BridgeError("RUNTIME_LOAD_FAILED", "기존 지역 런타임 검사에 실패했습니다.")
        self.progress(tr("runtime_validated"))
        self.assert_source_unchanged()
        manifest = {**self.manifest, source.scene_path: expected["output_hash"]}
        fresh = replace(document, source=self._source(verified, manifest))
        receipt = {key: expected[key] for key in ("source_hash", "output_hash", "region_hash", "scene_uid",
                                                  "region_uid", "before_count", "node_count", "scene_path")}
        receipt["runtime"] = json.loads(next(iter(runtime)))
        receipt["scene_state"] = verified["scene_state"]
        receipt["warnings"] = verified["warnings"]
        write_json(self.evidence / "verified-export.json", receipt)
        return fresh, receipt

    def stage_design(self, document):
        source = document.source
        design = document.design
        if design is None:
            raise BridgeError("INVALID_DOCUMENT", "Choose a V4 design to stage.")
        if design.connections:
            raise BridgeError("UNSUPPORTED_NODE", "Remove the unsupported ESCAPE routes before converting this document.")
        fields = {"region_id": document.region_id, "display_name": document.display_name,
                  "objects": [asdict(item) for item in document.objects], "design": asdict(design)}
        if source is None:
            scene_path = f"world/adventure/{document.region_id}.tscn"
            region_path = f"data/content/regions/{document.region_id}.tres"
            expected = self.call("stage_new_region", **fields)
            # A fresh editor scan registers the new text resource UIDs in the isolated cache.
            self._prepare_resources(f"prepare-v4-{uuid4().hex}")
            return self._verify_staged_design(document, expected, scene_path, region_path)
        if self.manifest.get("project.godot") != source.project_id or fingerprint(self.manifest) != source.fingerprint:
            raise BridgeError("SOURCE_MODIFIED", "Project, Scene or RegionDefinition changed after import.")
        region_path = "res://" + source.region_path
        expected = self.call("stage_v4_export", region_path=region_path, **fields,
                             source={key: getattr(source, key) for key in ("scene_path", "region_path", "scene_hash",
                                                                          "region_hash", "scene_uid", "region_uid")},
                             bindings={item.id: item.as_bridge_data() for item in source.bindings})
        return self._verify_staged_design(document, expected, source.scene_path, source.region_path)

    def preview_design(self, document):
        """Verify convertible fields without certifying or discarding draft-only routes."""
        if document.design is None or not document.design.connections:
            return self.stage_design(document)
        connections = document.design.connections
        convertible = replace(document, design=replace(document.design, connections=()))
        converted, receipt = self.stage_design(convertible)
        result = replace(converted, design=replace(converted.design, connections=connections))
        preview = {**receipt, "unmapped_connections": [asdict(item) for item in connections]}
        return result, preview

    def _verify_staged_design(self, document, expected, scene_path, region_path):
        if expected["scene_path"] != scene_path or expected["region_path"] != region_path:
            raise BridgeError("INVALID_RESPONSE", "Bridge staged unexpected destinations.")
        if document.source and (expected["scene_uid"], expected["region_uid"]) != (
                document.source.scene_uid, document.source.region_uid):
            raise BridgeError("UID_CONFLICT", "Staged pair changed an original UID.")
        manifest = dict(self.manifest)
        for path, hash_key in ((scene_path, "scene_hash"), (region_path, "region_hash")):
            output = safe_child(self.stage, path, Path(path).suffix)
            digest = file_hash(output)
            if digest != expected[hash_key]:
                raise BridgeError("SOURCE_MODIFIED", f"staged file hash mismatch: {path}")
            manifest[path] = digest
        contract_keys = ("scene_hash", "region_hash", "scene_uid", "region_uid", "scene_state", "definition_state")
        verified = self.call("validate_v4_export", region_path="res://" + region_path,
                             expected={key: expected[key] for key in contract_keys})
        marker_ids = {item.id for item in (*document.design.region_points, *document.design.spawn_points)}
        object_bindings = {key: value for key, value in verified["bindings"].items() if key not in marker_ids}
        _verify_objects(document.objects, verified["objects"], object_bindings)
        resulting_design = RegionDesign.from_data(verified["design"])
        _verify_design(document.design, resulting_design)
        self.progress(tr("runtime_running"))
        serial = uuid4().hex
        code, logs = self._run(f"design-runtime-{serial}", ["--scene", "res://tools/map_bridge/runtime_validation.tscn",
                                     "--", "--region", document.region_id], timeout=60, allow_response=True)
        if code < 0 or code > 255 or ENGINE_ERROR.search(logs):
            raise BridgeError("PROCESS_CRASH", f"V4 runtime: {code} (0x{code & 0xffffffff:08X}); see Godot logs")
        results = {line.removeprefix("REGION_PLAYTEST_JSON ") for line in logs.splitlines()
                   if line.startswith("REGION_PLAYTEST_JSON ")}
        if len(results) != 1:
            raise BridgeError("RUNTIME_LOAD_FAILED", "Godot did not complete the authored region runtime probe.")
        runtime = json.loads(next(iter(results)))
        if code != 0 or "AUTHORED FIELD RUNTIME PASS" not in logs or runtime.get("overall") not in ("PASS", "PASS_WITH_WARNINGS"):
            failures = ", ".join(row["stage"] for row in runtime.get("results", ()) if row.get("status") == "FAIL")
            raise BridgeError("RUNTIME_LOAD_FAILED", f"Region runtime or live spawn safety failed: {failures}")
        self.progress(tr("runtime_validated"))
        self.assert_source_unchanged()
        fresh = replace(document, source=self._source(verified, manifest), design=resulting_design)
        receipt = {key: verified[key] for key in (*contract_keys, "scene_path", "region_path", "node_count", "warnings")}
        receipt["runtime"] = runtime
        write_json(self.evidence / f"verified-v4-export-{serial}.json", receipt)
        return fresh, receipt


def _verify_design(expected, actual):
    for desired, loaded in ((expected.region_points, actual.region_points), (expected.spawn_points, actual.spawn_points)):
        rows = {item.id: item for item in loaded}
        if set(rows) != {item.id for item in desired}:
            raise BridgeError("EXPORT_FAILED", "Reloaded marker identities differ from the draft.")
        for marker in desired:
            other = rows[marker.id]
            if replace(marker, position=other.position) != other or any(
                    abs(a - b) > max(0.0002, abs(a) * 0.000001) for a, b in zip(marker.position, other.position)):
                raise BridgeError("EXPORT_FAILED", f"Reloaded marker differs: {marker.id}")
    env = expected.environment
    observed = actual.environment
    color = env.loading_color + ("ff" if len(env.loading_color) == 7 else "")
    if observed.path != env.path or (env.uid and observed.uid != env.uid) or observed.loading_color != color:
        raise BridgeError("EXPORT_FAILED", "Reloaded environment differs from the draft.")
    if expected.template_ladder != actual.template_ladder:
        raise BridgeError("EXPORT_FAILED", "Reloaded template ladder differs from the draft.")


def _verify_objects(expected, actual, bindings):
    data = {item["id"]: MapObject.from_data(item) for item in actual}
    if len(data) != len(actual) or set(data) != {item.id for item in expected} or set(data) != set(bindings):
        raise BridgeError("EXPORT_FAILED", "reloaded object IDs differ from requested draft")
    for item in expected:
        other = data[item.id]
        # Godot uses 32-bit Vector2 components. Rotation can also normalize by 360 degrees.
        numbers = zip((*item.position, *item.size), (*other.position, *other.size))
        geometry_matches = all(abs(a - b) <= max(0.0002, abs(a) * 0.000001) for a, b in numbers)
        if (not geometry_matches or abs((item.rotation - other.rotation + 180) % 360 - 180) > 0.0002
                or other.type != item.type or other.layer_id != item.layer_id or other.properties != item.properties):
            raise BridgeError("EXPORT_FAILED", f"reloaded geometry or properties differ for {item.id}")
