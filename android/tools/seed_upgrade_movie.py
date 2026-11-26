"""Create one authentic 1.2.0 DownloadManager job on the disposable upgrade-test emulator."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.parse import unquote
import uuid
import xml.etree.ElementTree as ET


PACKAGE = "com.anxiong.nicevideos.vr.preview"
NAME = "Upgrade test.mp4"
LIBRARY = "shared_prefs/video_library.xml"
WINDOW = "/data/local/tmp/nice-upgrade-window.xml"


def adb(*args, data=None):
    return subprocess.run(["adb", *args], input=data, stdout=subprocess.PIPE, check=True).stdout


def preferences(filename, data=None):
    if data is None:
        return adb("shell", "-T", f"run-as {PACKAGE} cat {filename}")
    adb("shell", "-T", f"run-as {PACKAGE} sh -c 'cat > {filename}'", data=data)


def tap(label):
    deadline = time.monotonic() + 75
    labels = []
    while time.monotonic() < deadline:
        adb("shell", "uiautomator", "dump", WINDOW)
        root = ET.fromstring(adb("shell", "cat", WINDOW))
        labels = [node.get("text") for node in root.iter("node") if node.get("text")]
        for node in root.iter("node"):
            if node.get("text") == label and node.get("enabled") == "true":
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
                adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
                return
        time.sleep(0.5)
    raise RuntimeError(f"Cannot find {label} in old app: {labels}")


def download(port):
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "-T", f"run-as {PACKAGE} mkdir -p shared_prefs")
    root = ET.Element("map")
    ET.SubElement(root, "string", name="server").text = f"http://127.0.0.1:{port}"
    preferences(LIBRARY, ET.tostring(root))
    adb("shell", "input", "keyevent", "WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("shell", "am", "start", "-W", "-n", PACKAGE + "/com.anxiong.nicevideos.MainActivity")
    tap("服务器")
    tap("下载")
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        catalog = ET.fromstring(preferences(LIBRARY))
        for item in catalog.findall("string"):
            if item.get("name", "").startswith("movie."):
                movie = json.loads(item.text)
                if movie["state"] == "failed":
                    raise RuntimeError(f"Old app download failed: {movie}")
                if movie["state"] == "ready" and movie["name"] == NAME and movie["job"] >= 0:
                    adb("shell", "am", "force-stop", PACKAGE)
                    movie["favorite"] = True
                    item.text = json.dumps(movie)
                    preferences(LIBRARY, ET.tostring(catalog))
                    uri = f"content://{PACKAGE}.offline/{movie['id']}"
                    bookmark = str(uuid.UUID(bytes=hashlib.md5(uri.encode()).digest(), version=3))
                    positions = ET.Element("map")
                    ET.SubElement(positions, "long", name=bookmark, value="12500")
                    preferences("shared_prefs/video_positions.xml", ET.tostring(positions))
                    return movie
        time.sleep(0.5)
    raise RuntimeError("Old app did not complete the download")


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or adb("shell", "getprop", "ro.kernel.qemu").strip() != b"1":
        raise RuntimeError("This fixture requires the disposable CI emulator")
    media = Path(sys.argv[1]).read_bytes()
    index = json.dumps({"videos": [{"name": NAME, "size": len(media)}]}).encode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.respond(True)

        def do_HEAD(self):
            self.respond(False)

        def respond(self, body):
            path = unquote(self.path)
            if path == "/api/videos":
                payload, mime = index, "application/json"
            elif path == "/api/download/" + NAME:
                payload, mime = media, "video/mp4"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", mime)
            self.end_headers()
            if body:
                self.wfile.write(payload)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        tcp = f"tcp:{server.server_port}"
        adb("reverse", tcp, tcp)
        try:
            movie = download(server.server_port)
            if movie["bytes"] != len(media):
                raise RuntimeError(f"Old job reported a different size: {movie}")
            # Print the generated identifiers only so the upgrade smoke can verify the same record.
            print(movie["id"], movie["disk"], movie["job"])
        finally:
            adb("reverse", "--remove", tcp)
            adb("shell", "rm", "-f", WINDOW)
            server.shutdown()


if __name__ == "__main__":
    main()
