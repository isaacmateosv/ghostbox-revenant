import rumps
import subprocess
import os
import webbrowser
import json
import urllib.request

class MboxMenuApp(rumps.App):
    def __init__(self):
        super(MboxMenuApp, self).__init__("Mbox 3", title="🎛️")
        self.menu = [
            "Open Control Panel",
            None,
            "Initialize Defaults",
            "Toggle Tuner",
            "Toggle Mono",
            "Toggle Dim",
            None
        ]

    @rumps.clicked("Open Control Panel")
    def open_web(self, _):
        webbrowser.open("http://localhost:8080")

    @rumps.clicked("Initialize Defaults")
    def do_init(self, _):
        # Go through the server so the panel state and its saved session reset too
        req = urllib.request.Request("http://localhost:8080/api/state", method="POST",
                                     data=json.dumps({"action": "reset_defaults"}).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=5)
        except OSError:
            subprocess.run(["./mbox3-ctl", "init"])
        rumps.notification("Mbox 3", "Hardware Reset", "Default routing applied successfully.")

    @rumps.clicked("Toggle Tuner")
    def do_tuner(self, sender):
        sender.state = not sender.state
        val = "1" if sender.state else "0"
        subprocess.run(["./mbox3-ctl", "tuner", val])

    @rumps.clicked("Toggle Mono")
    def do_mono(self, sender):
        sender.state = not sender.state
        val = "1" if sender.state else "0"
        subprocess.run(["./mbox3-ctl", "mono", val])

    @rumps.clicked("Toggle Dim")
    def do_dim(self, sender):
        sender.state = not sender.state
        val = "1" if sender.state else "0"
        subprocess.run(["./mbox3-ctl", "dim", val])

if __name__ == "__main__":
    MboxMenuApp().run()
