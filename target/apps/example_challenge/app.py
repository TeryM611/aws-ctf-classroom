"""
Example challenge -- a placeholder showing the shape the deploy kit expects.
Replace it with your own apps (one folder each under target/apps/).

Contract: the module defines a Flask object named `app`. Optional one-time
setup goes in a function named setup(), init_db() or write_flag();
deploy/run.py calls it before serving.

The puzzle: the home page hints at robots.txt, which points to a "hidden" page.
"""
from flask import Flask

app = Flask(__name__)
FLAG = "CTF{replace_me_with_a_real_flag}"


@app.route("/")
def index():
    return (
        "<h1>Welcome to the example challenge</h1>"
        "<p>Nothing to see here. Even the crawlers have been told where not to look.</p>"
    )


@app.route("/robots.txt")
def robots():
    return "User-agent: *\nDisallow: /staff-only\n", 200, {"Content-Type": "text/plain"}


@app.route("/staff-only")
def staff_only():
    return f"<p>You found it: {FLAG}</p>"


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000)
