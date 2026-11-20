#!/usr/bin/python3
# Checks Tab Scout's Firefox extension in a real browser, which test.sh never touches:
#   /usr/bin/python3 Tests/FirefoxLive/run.py                                  (Firefox)
#   /usr/bin/python3 Tests/FirefoxLive/run.py "/Applications/Zen Browser.app"
# It starts a second, hidden copy of the browser on a throwaway profile, loads the extension from
# Resources/FirefoxExtension into it as a temporary add-on over the browser's remote debugging protocol, and lets
# host.py, standing in for Tab Scout, run every command against pages served from this Mac. Zen gets its own
# package, put together as build.sh does, with the setting on that lets it make folders; there the folders are
# checked too, and that a folder made by hand outlasts `ungroup. Your own profile is not opened. While it runs,
# the file that tells the browser where Tab Scout's helper is points at host.py; it is put back afterwards.
import http.server, json, os, re, shutil, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.normpath(os.path.join(HERE, "../../Resources/FirefoxExtension"))
ZEN_EXTENSION = os.path.normpath(os.path.join(HERE, "../../Resources/ZenExtension"))
APP = sys.argv[1] if len(sys.argv) > 1 else "/Applications/Firefox.app"
ZEN = "zen" in os.path.basename(APP).lower()
MANIFEST = os.path.expanduser("~/Library/Application Support/Mozilla/NativeMessagingHosts/local.tabscout.firefox.json")
DEBUG_PORT = 6789
# A fresh profile greets with dialogs that block tab switching, and would report to the browser's maker.
PREFERENCES = {
    "devtools.debugger.remote-enabled": True, "devtools.chrome.enabled": True, "devtools.debugger.prompt-connection": False,
    "browser.shell.checkDefaultBrowser": False, "browser.aboutwelcome.enabled": False, "browser.preonboarding.enabled": False,
    "termsofuse.bypassNotification": True, "termsofuse.acceptedVersion": 99, "termsofuse.acceptedDate": "1700000000000",
    "datareporting.policy.dataSubmissionEnabled": False, "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
    "datareporting.healthreport.uploadEnabled": False, "toolkit.telemetry.reportingpolicy.firstRun": False,
    "browser.startup.homepage_override.mstone": "ignore", "startup.homepage_welcome_url": "about:blank",
    "startup.homepage_welcome_url.additional": "", "app.update.auto": False, "browser.tabs.warnOnClose": False,
    "browser.sessionstore.resume_from_crash": False, "zen.welcome-screen.seen": True,
    # Containers, with the four a fresh profile starts with.
    "privacy.userContext.enabled": True,
}
# What lets Zen load the piece of the extension that makes folders. Firefox pays it no attention.
if ZEN: PREFERENCES["extensions.experiments.enabled"] = True

if not os.path.isdir(APP): sys.exit("No browser at " + APP)
work = tempfile.mkdtemp(prefix="TabScout-FirefoxLive-")
profile = os.path.join(work, "profile")
os.makedirs(profile)
os.makedirs(os.path.join(work, "site"))
with open(os.path.join(profile, "user.js"), "w") as file:
    for name, value in PREFERENCES.items(): file.write("user_pref(%s, %s);\n" % (json.dumps(name), json.dumps(value)))
for name in "abc":
    with open(os.path.join(work, "site", name + ".html"), "w") as file: file.write("<!doctype html><title>Page %s</title><h1>%s</h1>" % (name, name))
host = shutil.copy(os.path.join(HERE, "host.py"), os.path.join(work, "host.py"))
os.chmod(host, 0o755)
if ZEN:
    # Zen's package: its own manifest and folder code around the same background script.
    package = os.path.join(work, "extension")
    os.makedirs(package)
    for name in ("manifest.json", "folders.js", "folders.json"): shutil.copy(os.path.join(ZEN_EXTENSION, name), package)
    shutil.copy(os.path.join(EXTENSION, "background.js"), package)
    EXTENSION = package

class Pages(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *arguments, **options): super().__init__(*arguments, directory=os.path.join(work, "site"), **options)
    def log_message(self, *arguments): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
with open(os.path.join(work, "config.json"), "w") as file:
    json.dump({"profile": profile, "base": "http://127.0.0.1:%d/" % server.server_address[1], "folders": ZEN}, file)

def packet(connection, message=None):
    # Firefox's remote debugging protocol: each JSON message follows its length and a colon.
    if message is not None:
        data = json.dumps(message).encode()
        connection.sendall(str(len(data)).encode() + b":" + data)
    size = b""
    while not size.endswith(b":"):
        byte = connection.recv(1)
        if not byte: raise EOFError("the browser closed the debugging connection")
        size += byte
    body = b""
    while len(body) < int(size[:-1]): body += connection.recv(int(size[:-1]) - len(body))
    return json.loads(body)

def inside(connection, code):
    # Runs `code` in the browser's own window, as its developer tools do, and answers what it returns as JSON.
    def ask(message, wanted):
        reply = packet(connection, message)
        while not wanted(reply): reply = packet(connection)
        return reply
    process = ask({"to": "root", "type": "getProcess", "id": 0}, lambda r: "processDescriptor" in r or "error" in r)
    target = ask({"to": process["processDescriptor"]["actor"], "type": "getTarget"}, lambda r: "process" in r or "error" in r)
    text = "(async () => JSON.stringify(await (async () => {" + code + "})()))()"
    started = ask({"to": target["process"]["consoleActor"], "type": "evaluateJSAsync", "text": text, "mapped": {"await": True}},
                  lambda r: "resultID" in r or "error" in r)
    done = ask(None, lambda r: r.get("type") == "evaluationResult" and r.get("resultID") == started.get("resultID")) if "resultID" in started else {}
    if done.get("hasException") or not isinstance(done.get("result"), str): raise RuntimeError("the browser could not run: " + code[:80])
    return json.loads(done["result"])

def browser_processes():
    found = subprocess.run(["/usr/bin/pgrep", "-f", "--", "--profile " + re.escape(profile)], capture_output=True, text=True).stdout.split()
    return [int(process) for process in found]

def quit_browser():
    # As Quit in the Dock does; the hidden copy has no window to close.
    script = 'ObjC.import("AppKit"); const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(%d); app.isNil() ? "gone" : String(app.terminate)'
    for process in browser_processes():
        subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script % process], capture_output=True)
    for _ in range(20):
        if not browser_processes(): return
        time.sleep(0.5)
    for process in browser_processes():
        try: os.kill(process, 15)
        except OSError: pass

previous = open(MANIFEST, "rb").read() if os.path.exists(MANIFEST) else None
os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
with open(MANIFEST, "w") as file:
    json.dump({"name": "local.tabscout.firefox", "description": "Tab Scout live check", "path": host, "type": "stdio",
               "allowed_extensions": ["tabscout@local.tabscout"]}, file)
outcome = {"failure": "the extension never reached its helper"}
try:
    # Through Launch Services, as a second copy that stays in the background, so it runs as any app does.
    subprocess.run(["/usr/bin/open", "-n", "-g", "-a", APP, "--args", "--headless", "--no-remote", "--profile", profile,
                    "--start-debugger-server", str(DEBUG_PORT), "about:blank"], check=True)
    connection = None
    for _ in range(60):
        try:
            connection = socket.create_connection(("127.0.0.1", DEBUG_PORT), timeout=2)
            break
        except OSError:
            time.sleep(0.5)
    if connection is None: raise RuntimeError("the browser's debugging server never came up")
    connection.settimeout(30)
    packet(connection)
    root = packet(connection, {"to": "root", "type": "getRoot"})
    # A folder made by hand, as from Zen's own menu, which `ungroup must leave alone.
    if ZEN:
        inside(connection, 'for (let tries = 0; tries < 100 && !(window.gZenFolders && window.gZenWorkspaces && gZenWorkspaces.activeWorkspace); tries++) '
               'await new Promise(resolve => setTimeout(resolve, 100)); gZenFolders.createFolder([], {label: "Made by hand"}); return true;')
    # Three containers to open pages in; a fresh profile may have none.
    boxes = inside(connection, 'return ["One", "Two", "Three"].map(name => ContextualIdentityService.create("Live " + name, "fingerprint", "blue").userContextId);')
    config = json.load(open(os.path.join(work, "config.json")))
    config["containers"] = boxes
    with open(os.path.join(work, "config.json"), "w") as file: json.dump(config, file)
    installed = packet(connection, {"to": root["addonsActor"], "type": "installTemporaryAddon", "addonPath": EXTENSION, "openDevTools": False})
    # Events of the browser's window, as after running code there, may come first.
    while installed.get("from") != root["addonsActor"]: installed = packet(connection)
    if "addon" not in installed: raise RuntimeError("the browser refused the extension: " + json.dumps(installed)[:300])
    for _ in range(120):
        if os.path.exists(os.path.join(work, "result.json")):
            time.sleep(0.2)
            outcome = json.load(open(os.path.join(work, "result.json")))
            break
        time.sleep(0.5)
    if "passed" in outcome:
        # Zen's package may put pages in containers; Firefox's has no permission for it, so they open in none.
        opened = inside(connection, 'return gBrowser.tabs.map(tab => [tab.linkedBrowser.currentURI.spec, tab.userContextId]);')
        found = {key: [box for spec, box in opened if key in spec] for key in ("box=one", "box+two", "box=gone", "box=reuse")}
        found["new tab"] = [box for spec, box in opened if spec.startswith("about:") and box == boxes[2]]
        wanted = {"box=one": [boxes[0]], "box+two": [boxes[1]], "box=gone": [0], "box=reuse": [boxes[0]], "new tab": [boxes[2]]} if ZEN else \
                 {"box=one": [0], "box+two": [0], "box=gone": [0], "box=reuse": [0], "new tab": []}
        if found == wanted: outcome["passed"] += 1
        else: outcome = {"failure": "the containers are %s, not %s" % (json.dumps(found), json.dumps(wanted)), "after": "the container checks"}
    if ZEN and "passed" in outcome:
        time.sleep(1)
        left = inside(connection, 'return Array.from(document.querySelectorAll("zen-folder")).map(folder => folder.label);')
        if left == ["Made by hand"]: outcome["passed"] += 1
        else: outcome = {"failure": "after `ungroup the folders left are %s" % json.dumps(left), "after": "the folder checks"}
except Exception as error:
    outcome = {"failure": repr(error)}
finally:
    quit_browser()
    if previous is None: os.remove(MANIFEST)
    else: open(MANIFEST, "wb").write(previous)
    shutil.rmtree(work, ignore_errors=True)

if "passed" in outcome:
    print("Passed %d live checks in %s (helper started by %s)" % (outcome["passed"], os.path.basename(APP), outcome.get("parent", "?")))
else:
    sys.exit("FAILED in %s: %s (after: %s)" % (os.path.basename(APP), outcome.get("failure"), outcome.get("after")))
