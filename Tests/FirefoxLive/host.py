#!/usr/bin/python3
# Stands in for Tab Scout behind the native messaging helper during run.py: the browser starts this for the
# extension, and it drives the extension through every command, checking what comes back. What happened is written
# to result.json beside this file.
import json, os, queue, struct, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
replies, events, checks = queue.Queue(), [], []

def parent_command():
    return subprocess.run(["/bin/ps", "-o", "command=", "-p", str(os.getppid())], capture_output=True, text=True).stdout.strip()

def read():
    while True:
        head = sys.stdin.buffer.read(4)
        if len(head) < 4: break
        message = json.loads(sys.stdin.buffer.read(struct.unpack("=I", head)[0]))
        if "id" in message: replies.put(message)
        else: events.append(message)

def ask(message, wait=10):
    ask.count += 1
    message["id"] = ask.count
    data = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()
    reply = replies.get(timeout=wait)
    assert reply["id"] == ask.count, reply
    return reply
ask.count = 0

def bridge(command, *arguments):
    return ask({"type": "bridge", "command": command, "args": [str(argument) for argument in arguments]})

def rows():
    return json.loads(bridge("list")["result"])

def active():
    return json.loads(bridge("active")["result"])

def settle(done, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        now = rows()
        if done(now): return now
        time.sleep(0.3)
    return rows()

def expect(condition, message):
    if not condition: raise AssertionError(message)
    checks.append(message)

def scenario(base):
    expect(ask({"type": "version"}).get("version"), "The extension says its version")
    expect(ask({"type": "nonsense"}).get("error") == "unknown request", "An unknown request is answered as such")
    first = rows()
    expect(len(first) >= 1 and all(len(row) == 5 for row in first), "The tabs are listed as rows of five")
    window = first[0][0]
    count = len(first)

    expect(bridge("url", window, base + "a.html").get("result") == "ok", "An address opens")
    now = settle(lambda r: any(x[2] == "Page a" and x[4] for x in r))
    expect(len(now) == count + 1 and any(x[2] == "Page a" and x[3] == base + "a.html" and x[4] for x in now), "It opens in a new tab, which comes on screen")
    expect(active()[2:] == ["Page a", base + "a.html"], "The tab on screen is that tab")

    expect(bridge("reopen", window, base + "b.html", 99999, base + "c.html").get("result") == "2", "Two addresses reopen")
    now = settle(lambda r: sum(1 for x in r if x[2] in ("Page b", "Page c")) == 2)
    expect(len(now) == count + 3 and active()[2] == "Page a", "They open in background tabs, also when their window is gone, and the tab on screen stays")
    b = next(x for x in now if x[2] == "Page b")
    c = next(x for x in now if x[2] == "Page c")

    expect(bridge("switch", b[0], b[1], b[3], b[2]).get("result") == "ok" and active()[2] == "Page b", "A listed tab is switched to")
    expect(bridge("switch", c[0], 1, c[3], c[2]).get("result") == "ok" and active()[2] == "Page c", "A tab that moved is found by its address and title")
    expect(bridge("switch", window, 2, "http://gone.invalid/", "Gone").get("error") == "TAB_SCOUT_STALE", "A tab that is gone is reported as stale")
    expect(bridge("switch", 99999, 1, c[3], c[2]).get("error") == "TAB_SCOUT_STALE", "So is a tab of a window that is gone")
    expect(active()[2] == "Page c", "A failed switch changes nothing")

    expect(bridge("search", window, "tab scout live check").get("result") == "ok", "A search opens")
    now = settle(lambda r: any(x[4] and "scout" in x[3] for x in r), 8)
    expect(len(now) == count + 4 and any(x[4] and "tab" in x[3] and "scout" in x[3] for x in now), "It opens in one new tab, with the browser's own search engine")

    expect(bridge("new-tab", window).get("result") == "ok", "A new tab opens")
    now = settle(lambda r: len(r) == count + 5 and any(x[4] and x[3].startswith("about:") for x in r), 6)
    blank = next((x for x in now if x[4]), None)
    expect(len(now) == count + 5 and blank is not None and blank[3].startswith("about:"), "It shows the browser's new-tab page and is on screen")

    expect(bridge("url", window, base + "a.html", blank[1], blank[3]).get("result") == "ok", "An address opens while an empty tab is on screen")
    now = settle(lambda r: sum(1 for x in r if x[2] == "Page a") == 2)
    expect(len(now) == count + 5 and sum(1 for x in now if x[2] == "Page a") == 2 and active()[2] == "Page a", "It opens in the empty tab instead of another")

    doomed = [x for x in now if x[2] in ("Page a", "Page b")]
    arguments = [value for x in doomed for value in (x[0], x[1], x[3])] + [window, 1, "http://not-this.invalid/"]
    expect(json.loads(bridge("close", *arguments)["result"]) == [0, 1, 2], "The tabs still in place are closed, and the answer names them")
    now = settle(lambda r: not any(x[2] in ("Page a", "Page b") for x in r), 6)
    expect(len(now) == count + 2 and not any(x[2] in ("Page a", "Page b") for x in now) and any(x[2] == "Page c" for x in now), "Only they are gone")

    expect(bridge("text", window, 1, "x").get("error") == "unknown request", "Page text is not read")
    reply = ask({"type": "mute"})
    expect(reply.get("muted") == 0 and reply.get("unmuted") == 0, "With nothing playing, nothing is muted")
    time.sleep(0.6)
    kinds = {event.get("event") for event in events if event.get("type") == "event"}
    expect(kinds == {"focus", "tabs"}, "The extension says when the tab on screen and the tabs change")

def main():
    config = json.load(open(os.path.join(HERE, "config.json")))
    # Another browser of the person's may start this too, while the helper's file points here. It gets no answer
    # and tries again later, once the file is back as it was.
    if config["profile"] not in parent_command(): return
    out = {"parent": parent_command().split(" --")[0], "arguments": sys.argv[1:]}
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        scenario(config["base"])
        out["passed"] = len(checks)
    except Exception as error:
        out["failure"] = repr(error)
        out["after"] = checks[-1] if checks else None
    out["events"] = len(events)
    with open(os.path.join(HERE, "result.json"), "w") as file: json.dump(out, file, indent=1)
    # Stay connected, as the real helper does, until the browser closes the pipe.
    reader.join()

main()
